"""Persisted settings for the tool (server, token, chosen model, folders)."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .models import DEFAULT_MODEL_ID

DEFAULT_BASE_URL = "https://dragos.games/api/book_sync"


def app_dir() -> Path:
    """Per-user data directory.

    %LOCALAPPDATA%, deliberately not %APPDATA%: this holds a 22 GB GGUF plus ~535 MB of llama.cpp
    binaries. The roaming profile would try to sync all of that to a profile server at logoff on
    any domain-joined machine.
    """
    local = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    if local:
        return Path(local) / "HoshiPretranslate"
    return Path.home() / ".hoshi-pretranslate"


@dataclass
class Config:
    base_url: str = DEFAULT_BASE_URL
    token: str = ""
    model_id: str = DEFAULT_MODEL_ID
    models_dir: str = field(default_factory=lambda: str(app_dir() / "models"))
    output_dir: str = field(default_factory=lambda: str(app_dir() / "translations"))
    n_ctx: int = 16384
    upload: bool = True
    # "focused" = one request per bubble with the page + previous page as context (best quality).
    # "page"    = one request per page, translating every bubble at once (several times faster).
    mode: str = "focused"
    # "local" = the GPU via llama.cpp; "cloud" = a hosted API (much faster, costs pennies).
    engine: str = "local"
    cloud_provider: str = "google"
    cloud_model: str = ""
    cloud_key: str = ""
    cloud_concurrency: int = 12
    # Your own prompt. Empty means "use whatever the app synced" (app/ai_chat_settings).
    prompt_override: str = ""
    # syncIds in the order you want them processed. Books not listed here run afterwards.
    book_order: list = field(default_factory=list)
    # syncIds to actually process. Empty means "all of them".
    selected_books: list = field(default_factory=list)

    @property
    def path_models(self) -> Path:
        return Path(self.models_dir)

    @property
    def path_output(self) -> Path:
        return Path(self.output_dir)


def config_path() -> Path:
    return app_dir() / "config.json"


def load() -> Config:
    path = config_path()
    if not path.exists():
        return Config()
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return Config()
    base = Config()
    for key, value in doc.items():
        if hasattr(base, key):
            setattr(base, key, value)
    return base


def save(config: Config) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(config), indent=2), encoding="utf-8")
    # The file holds a bearer token; keep it owner-only where the OS supports it.
    try:
        path.chmod(0o600)
    except OSError:
        pass
