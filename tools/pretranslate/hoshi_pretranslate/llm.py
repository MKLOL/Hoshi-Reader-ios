"""Local batch translation via llama.cpp (CUDA).

Context strategy
----------------
Running locally means context is cheap, so every request carries the **previous page and the
current page** of bubbles. A manga line in isolation is frequently untranslatable ("うん", "そうか",
bare pronouns, an unmarked subject carried over from two bubbles ago); the surrounding page is what
makes it readable.

Two modes:

* ``focused`` (default) - one request per bubble. The shared page context comes first and the
  "now translate THIS bubble" instruction comes last, so llama.cpp's prefix cache re-uses the
  context across every bubble on the page and only the short tail is recomputed. Best quality.
* ``page`` - one request per page, translating every bubble at once.

The two are closer in speed than they look. Runtime is dominated by *generated* tokens, and every
bubble needs its own translation and explanation either way; with the prefix cache doing the work,
page mode saves only the repeated JSON scaffolding and a little prefill - on the order of 25%, not
a multiple.

Output is constrained by a JSON schema (compiled to a GBNF grammar) so a chatty model can never
break the mapping back to bubble ids.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Callable, Iterable

import requests

from .mokuro import Bubble

# Anything that means "this reply was not usable" — bad JSON, a missing field, or the server
# hiccupping on one request. All are per-bubble recoverable: we leave the bubble unset so the
# next run retries it rather than aborting a multi-hour job.
# IndexError included deliberately: llama-server can return an empty `choices` array on a slot
# or context error, and `["choices"][0]` would otherwise escape and abort a multi-hour run that
# this module promises is per-bubble recoverable.
_RECOVERABLE = (ValueError, KeyError, TypeError, IndexError, requests.RequestException)

# Qwen3.5 can emit a reasoning preamble; the readers strip it too (AiThinkingTextSanitizer.swift).
_THINK_BLOCK = re.compile(r"<think>.*?</think>\s*", re.DOTALL | re.IGNORECASE)

MODE_FOCUSED = "focused"
MODE_PAGE = "page"

BUBBLE_SCHEMA = {
    "type": "object",
    "properties": {
        "translation": {"type": "string"},
        "explanation": {"type": "string"},
    },
    "required": ["translation", "explanation"],
}

PAGE_SCHEMA = {
    "type": "object",
    "properties": {
        "bubbles": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "translation": {"type": "string"},
                    "explanation": {"type": "string"},
                },
                "required": ["id", "translation", "explanation"],
            },
        }
    },
    "required": ["bubbles"],
}

SYSTEM_PROMPT = (
    "You are a Japanese reading tutor helping a learner read manga. You are shown the speech "
    "bubbles around the line you are asked about so you can resolve pronouns, implied subjects "
    "and running jokes. Give a natural English translation and a short explanation of the tricky "
    "vocabulary or grammar. Reply with JSON only. Do not think out loud."
)


@dataclass
class Translation:
    translation: str
    explanation: str


def strip_thinking(text: str) -> str:
    return _THINK_BLOCK.sub("", text).strip()


def _render(bubbles: Iterable[Bubble]) -> str:
    # mokuro's in-bubble newlines are drawn line breaks, not sentence breaks; flatten them so one
    # bubble stays one line in the prompt.
    return "\n".join(f"[{b.block_id}] {b.text.replace(chr(10), ' / ')}" for b in bubbles)


def build_context(page: list[Bubble], previous_page: list[Bubble], user_prompt: str) -> str:
    """The part of the prompt shared by every bubble on a page — kept first for prefix caching."""
    parts = [
        "Style guidance from the reader (follow it for the explanations):",
        user_prompt.strip() or "Give a natural translation plus a brief grammar/vocabulary note.",
        "",
    ]
    if previous_page:
        parts += ["Previous page, for context only:", _render(previous_page), ""]
    parts += ["Current page, in reading order:", _render(page), ""]
    return "\n".join(parts)


def build_focused_prompt(
    target: Bubble, page: list[Bubble], previous_page: list[Bubble], user_prompt: str
) -> str:
    flattened = target.text.replace("\n", " / ")
    return (
        build_context(page, previous_page, user_prompt)
        + f"Now translate and explain ONLY bubble [{target.block_id}]: {flattened}\n"
        + 'Reply with JSON: {"translation":"...","explanation":"..."}'
    )


def build_page_prompt(page: list[Bubble], previous_page: list[Bubble], user_prompt: str) -> str:
    return (
        build_context(page, previous_page, user_prompt)
        + "Now translate and explain every bubble on the current page.\n"
        + 'Reply with JSON: {"bubbles":[{"id":"<id>","translation":"...","explanation":"..."}]}\n'
        + "Include every id from the current page exactly once."
    )


class LocalTranslator:
    """Talks to a running llama.cpp server (see runtime.LlamaServer) over its OpenAI-style API."""

    def __init__(
        self,
        base_url: str,
        mode: str = MODE_FOCUSED,
        log: Callable[[str], None] = print,
        session=None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._session = session or requests.Session()
        self._log = log
        self.mode = mode

    def close(self) -> None:
        self._session.close()

    # -- generation --------------------------------------------------------------------------

    def _complete(self, user_message: str, schema: dict, max_tokens: int) -> str:
        response = self._session.post(
            f"{self._base_url}/v1/chat/completions",
            json={
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_message},
                ],
                # llama.cpp compiles this schema into a GBNF grammar, so the reply cannot drift
                # off-format no matter how chatty the model wants to be.
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {"name": "translation", "schema": schema, "strict": True},
                },
                # Qwen3.5 ships with thinking ENABLED. Reasoning tokens still count against
                # max_tokens, so without this the model spends the whole budget thinking and
                # returns empty/truncated content — every bubble would fail to parse.
                "chat_template_kwargs": {"enable_thinking": False},
                # Qwen3.5 recommends >= 0.6; lower values raise the repetition-loop risk that
                # would burn the same budget.
                "temperature": 0.7,
                "top_p": 0.8,
                "max_tokens": max_tokens,
                "cache_prompt": True,
            },
            timeout=600,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"] or ""

    def translate_page(
        self,
        page: list[Bubble],
        user_prompt: str,
        previous_page: list[Bubble] | None = None,
        targets: list[Bubble] | None = None,
    ) -> dict[str, Translation]:
        """Translates `targets` (default: the whole page) using the page + previous page as context."""
        previous_page = previous_page or []
        targets = targets if targets is not None else list(page)
        if not targets:
            return {}
        if self.mode == MODE_PAGE:
            return self._translate_batched(page, previous_page, targets, user_prompt)
        return self._translate_focused(page, previous_page, targets, user_prompt)

    def _translate_focused(
        self,
        page: list[Bubble],
        previous_page: list[Bubble],
        targets: list[Bubble],
        user_prompt: str,
    ) -> dict[str, Translation]:
        out: dict[str, Translation] = {}
        for bubble in targets:
            prompt = build_focused_prompt(bubble, page, previous_page, user_prompt)
            try:
                raw = strip_thinking(self._complete(prompt, BUBBLE_SCHEMA, 800))
                parsed = json.loads(raw)
                out[bubble.block_id] = Translation(
                    translation=str(parsed.get("translation", "")).strip(),
                    explanation=str(parsed.get("explanation", "")).strip(),
                )
            except _RECOVERABLE as exc:
                # One bad bubble must not sink the volume; leaving it absent makes a later run retry.
                self._log(f"  bubble {bubble.block_id} failed ({exc}); will retry on the next run")
        return out

    def _translate_batched(
        self,
        page: list[Bubble],
        previous_page: list[Bubble],
        targets: list[Bubble],
        user_prompt: str,
    ) -> dict[str, Translation]:
        prompt = build_page_prompt(page, previous_page, user_prompt)
        budget = max(1024, 220 * len(targets))
        try:
            raw = strip_thinking(self._complete(prompt, PAGE_SCHEMA, budget))
            out = _collect(json.loads(raw), targets)
        except _RECOVERABLE as exc:
            self._log(f"  page reply unparseable ({exc}); falling back to per-bubble")
            return self._translate_focused(page, previous_page, targets, user_prompt)

        missing = [b for b in targets if b.block_id not in out]
        if missing:
            self._log(f"  page reply missed {len(missing)} bubble(s); retrying those singly")
            out.update(self._translate_focused(page, previous_page, missing, user_prompt))
        return out


def _collect(parsed: dict, bubbles: list[Bubble]) -> dict[str, Translation]:
    """Maps a model reply back onto the requested bubbles, ignoring ids it invented."""
    wanted = {b.block_id for b in bubbles}
    out: dict[str, Translation] = {}
    for item in parsed.get("bubbles") or []:
        block_id = str(item.get("id", "")).strip()
        if block_id not in wanted:
            continue
        out[block_id] = Translation(
            translation=str(item.get("translation", "")).strip(),
            explanation=str(item.get("explanation", "")).strip(),
        )
    return out
