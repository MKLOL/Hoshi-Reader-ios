"""Cloud translation backend — the fast path.

The local GPU generates one bubble at a time at ~55 tok/s. A hosted flash/mini model answers in
about a second and tolerates a dozen requests at once, so a volume that takes an hour on the 5090
finishes in minutes for roughly the price of a coffee.

Every provider here speaks the OpenAI Chat Completions wire format, including Google's Gemini
(which exposes an OpenAI-compatible endpoint) — so one client covers all of them. That mirrors the
readers' own `ChatModelCatalog`, where the provider is derived from the model id.

Interface-compatible with `llm.LocalTranslator`, so `pipeline.run` does not care which is in use.
"""

from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

import requests

from .llm import (
    BUBBLE_SCHEMA,
    MODE_FOCUSED,
    MODE_PAGE,
    PAGE_SCHEMA,
    SYSTEM_PROMPT,
    Translation,
    _collect,
    build_focused_prompt,
    build_page_prompt,
    strip_thinking,
)
from .mokuro import Bubble

_RECOVERABLE = (ValueError, KeyError, TypeError, IndexError, requests.RequestException)


@dataclass(frozen=True)
class CloudProvider:
    id: str
    display_name: str
    base_url: str
    keys_url: str
    default_model: str
    note: str


# Same providers and endpoints the readers use (features/ai/ChatModelCatalog).
PROVIDERS: list[CloudProvider] = [
    CloudProvider(
        "google", "Google (Gemini)",
        "https://generativelanguage.googleapis.com/v1beta/openai",
        "https://aistudio.google.com/apikey",
        "gemini-3.6-flash",
        "Fastest and cheapest for this job; strong Japanese. Recommended.",
    ),
    CloudProvider(
        "openai", "OpenAI",
        "https://api.openai.com/v1",
        "https://platform.openai.com/api-keys",
        "gpt-5.5-mini",
        "Use a mini/flash tier model — the big ones cost far more for no gain here.",
    ),
    CloudProvider(
        "deepseek", "DeepSeek",
        "https://api.deepseek.com/v1",
        "https://platform.deepseek.com/api_keys",
        "deepseek-chat",
        "Cheapest per token; a little slower per request.",
    ),
    CloudProvider(
        "qwen", "Qwen (Alibaba)",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://bailian.console.alibabacloud.com/",
        "qwen-turbo",
        "Native CJK tokenizer, cheap.",
    ),
    CloudProvider(
        "moonshot", "Moonshot (Kimi)",
        "https://api.moonshot.ai/v1",
        "https://platform.moonshot.ai/console/api-keys",
        "moonshot-v1-8k",
        "",
    ),
]

DEFAULT_PROVIDER_ID = "google"


def provider_by_id(provider_id: str) -> CloudProvider:
    return next((p for p in PROVIDERS if p.id == provider_id), PROVIDERS[0])


class CloudTranslator:
    """Same surface as `llm.LocalTranslator`, but fans requests out across a thread pool."""

    def __init__(
        self,
        provider: CloudProvider,
        api_key: str,
        model: str,
        mode: str = MODE_FOCUSED,
        concurrency: int = 12,
        log: Callable[[str], None] = print,
    ) -> None:
        if not api_key.strip():
            raise ValueError(f"No {provider.display_name} API key.")
        self.provider = provider
        self.model = (model or provider.default_model).strip()
        self.mode = mode
        self.concurrency = max(1, concurrency)
        self._log = log
        self._session = requests.Session()
        self._session.headers.update(
            {"Authorization": f"Bearer {api_key.strip()}", "Content-Type": "application/json"}
        )
        # Set once a provider rejects json_schema, so we stop paying for the retry every request.
        self._schema_unsupported = False

    def close(self) -> None:
        self._session.close()

    # -- one request -------------------------------------------------------------------------

    def _complete(self, user_message: str, schema: dict, max_tokens: int) -> str:
        body = {
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message},
            ],
            "temperature": 0.3,
            "max_tokens": max_tokens,
        }
        if not self._schema_unsupported:
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "translation", "schema": schema, "strict": True},
            }
        else:
            body["response_format"] = {"type": "json_object"}

        response = self._post(body)
        # Not every OpenAI-compatible provider implements strict json_schema; fall back once and
        # remember, rather than failing the run over a format quibble.
        if response.status_code == 400 and not self._schema_unsupported:
            self._schema_unsupported = True
            self._log("  provider rejected json_schema; using json_object mode")
            body["response_format"] = {"type": "json_object"}
            response = self._post(body)

        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"] or ""

    def _post(self, body: dict) -> requests.Response:
        last: Exception | None = None
        for attempt in range(4):
            try:
                response = self._session.post(
                    f"{self.provider.base_url}/chat/completions", json=body, timeout=(30, 180)
                )
            except requests.RequestException as exc:
                last = exc
                _sleep(attempt)
                continue
            # Back off on rate limits and transient server errors; everything else is returned
            # as-is so the caller can decide.
            if response.status_code in (429, 500, 502, 503, 504) and attempt < 3:
                _sleep(attempt, response.headers.get("Retry-After"))
                continue
            return response
        raise requests.RequestException(f"request failed after retries: {last}")

    # -- batch -------------------------------------------------------------------------------

    def translate_page(
        self,
        page: list[Bubble],
        user_prompt: str,
        previous_page: list[Bubble] | None = None,
        targets: list[Bubble] | None = None,
    ) -> dict[str, Translation]:
        previous_page = previous_page or []
        targets = targets if targets is not None else list(page)
        if not targets:
            return {}

        if self.mode == MODE_PAGE:
            try:
                raw = strip_thinking(
                    self._complete(
                        build_page_prompt(page, previous_page, user_prompt),
                        PAGE_SCHEMA,
                        max(1024, 220 * len(targets)),
                    )
                )
                out = _collect(json.loads(raw), targets)
                missing = [b for b in targets if b.block_id not in out]
                if not missing:
                    return out
                targets = missing
            except _RECOVERABLE as exc:
                self._log(f"  page request failed ({exc}); falling back to per-bubble")

        # The whole point of the cloud path: these are independent requests, so run them together.
        out: dict[str, Translation] = {}
        with ThreadPoolExecutor(max_workers=min(self.concurrency, len(targets))) as pool:
            futures = {
                pool.submit(self._one, bubble, page, previous_page, user_prompt): bubble
                for bubble in targets
            }
            for future, bubble in futures.items():
                try:
                    result = future.result()
                except _RECOVERABLE as exc:
                    # One bad bubble must not sink the volume; the next run retries it.
                    self._log(f"  bubble {bubble.block_id} failed ({exc})")
                    continue
                if result is not None:
                    out[bubble.block_id] = result
        return out

    def _one(
        self, bubble: Bubble, page: list[Bubble], previous_page: list[Bubble], user_prompt: str
    ) -> Translation | None:
        raw = strip_thinking(
            self._complete(
                build_focused_prompt(bubble, page, previous_page, user_prompt), BUBBLE_SCHEMA, 800
            )
        )
        parsed = json.loads(raw)
        return Translation(
            translation=str(parsed.get("translation", "")).strip(),
            explanation=str(parsed.get("explanation", "")).strip(),
        )

    def check(self) -> str:
        """One tiny request, so a bad key or model fails immediately instead of mid-library."""
        raw = self._complete('Reply with {"translation":"ok","explanation":"ok"}', BUBBLE_SCHEMA, 100)
        json.loads(strip_thinking(raw))
        return f"{self.provider.display_name} / {self.model} OK"


def _sleep(attempt: int, retry_after: str | None = None) -> None:
    import time

    delay = 2.0 * (2**attempt)
    if retry_after:
        try:
            delay = max(delay, float(retry_after))
        except ValueError:
            pass
    time.sleep(min(delay, 30.0))
