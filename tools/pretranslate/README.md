# Hoshi Pre-translate

Batch-translates every manga in your Hoshi sync library on a local GPU, then uploads **one
translation file per book** so the readers can serve translations instantly while offline.

Built for a 32 GB RTX 5090 on Windows.

> Translating a **novel** rather than manga? See [EPUB.md](EPUB.md) — same tool, same server,
> but the unit is a sentence in a chapter instead of a speech bubble on a page.

## What it does

1. Signs in to your sync server with the same bearer token the app uses.
2. Lists every mokuro manga volume and reads just its `mokuro.json` — using HTTP range requests so
   it does **not** download the page images.
3. For every speech bubble, asks a local LLM for a translation plus a grammar/vocabulary
   explanation, giving the model the whole current page **and the previous page** as context.
4. Writes one `books/{syncId}/pretranslations` blob per book back to the server.

On the device, tapping the AI button while offline serves the stored answer for that exact bubble.
These never enter the chat history — they are a cache, not a conversation.

## Running it

**Double-click `Hoshi Pre-translate.bat`. That's the whole setup.**

You do **not** need Python, Visual Studio, or the CUDA toolkit. Nothing is installed system-wide
and nothing is added to your PATH. The first run downloads, into
`%LOCALAPPDATA%\HoshiPretranslate`:

* a private, self-contained Python (~45 MB)
* three small packages
* the llama.cpp CUDA 13.3 build, which bundles its own CUDA runtime and has Blackwell (sm_120)
  kernels, so the 5090 works out of the box

Later runs skip all of that and open straight away. If any step fails, the window stays open and
tells you what went wrong instead of vanishing.

Then, in the app:

1. Paste your **sync token** (Hoshi → Settings → Sync).
2. Pick a **model** — `Qwen3.5 27B Q6_K` is preselected and recommended.
3. Press **Download** (one time, ~22 GB), then **Start**.

Everything large lives under `%LOCALAPPDATA%`, so this folder stays small even in Dropbox — but
make sure your `C:` drive has room for the model (~23 GB for the recommended one).

> Qwen3.5 ships with "thinking" on by default. The tool disables it per request and at the server,
> because reasoning tokens count against the reply budget — left on, every bubble would come back
> empty.

Progress, a live log, and per-book results appear in the window. **Stop** finishes the current page
and exits cleanly; everything already done is kept. A volume interrupted part-way is not uploaded
and not marked finished — the next run resumes it.

Closing the window also shuts the model down. If a `llama-server.exe` is ever left running, the
tool refuses to start rather than silently translating with the previous model.

### Model choice

| Model | Size | Notes |
| --- | --- | --- |
| **Qwen3.5 27B Q6_K** | 22.4 GB | **Recommended.** Best quality that fully fits 32 GB. |
| Qwen3.5 27B Q5_K_M | 19.6 GB | Same model, more context headroom, slightly lower quality. |
| Qwen3.5 27B Q8_0 | 28.6 GB | Maximum quality, only ~3 GB spare — keep the context small. |
| Qwen3.5 35B-A3B Q4_K_M | 22.0 GB | MoE, ~2x faster; a little weaker on subtle Japanese. |
| Qwen3.5 9B Q6_K | 7.5 GB | Quick end-to-end pipeline test. |

Qwen3.5 is the family the readers already use on-device, and its native CJK tokenizer spends fewer
tokens per Japanese line than the alternatives.

### Context mode

* **Per bubble** (default) — one request per bubble, with the page and previous page as context.
  Best quality. The shared page context is sent first so llama.cpp's prefix cache is reused across
  every bubble on a page.
* **Per page** — one request per page. About 25% faster, slightly blunter per line. (Not a
  multiple: every bubble still needs its own translation and explanation, and generated tokens
  dominate the runtime.)

## Results

The **Results** tab lists every book and bubble with its Japanese, translation, and explanation.
**Open as web page** exports a self-contained HTML review of the selected book.

Raw output lives in the output folder as one JSON file per book — the same bytes uploaded to the
server.

## Command line

The `.bat` opens the GUI. For headless runs, use the bundled Python directly (run these from this
folder, after the first launch has set it up):

```
set PY=%LOCALAPPDATA%\HoshiPretranslate\python\python.exe

%PY% -m hoshi_pretranslate --list            # list manga on the server
%PY% -m hoshi_pretranslate --list-models
%PY% -m hoshi_pretranslate --token XXX       # translate everything
%PY% -m hoshi_pretranslate --book my-vol-1   # just one volume
%PY% -m hoshi_pretranslate --mode page       # faster, per-page requests
%PY% -m hoshi_pretranslate --no-upload       # translate locally only
```

## How long it takes

Runtime is dominated by generated tokens: roughly 100 per bubble, and a typical volume is ~2,000
bubbles (~180 pages). On a 5090:

| Model | ~tok/s | Per volume |
| --- | --- | --- |
| Qwen3.5 27B Q6_K | ~55 | ~1 hour |
| Qwen3.5 27B Q5_K_M | ~63 | ~55 min |
| Qwen3.5 35B-A3B Q4_K_M | ~118 | ~30 min |
| Qwen3.5 9B Q6_K | ~150 | ~22 min |

The window shows measured bubbles/min and a live ETA once the first page is done — trust that over
this table, and scale for dialogue-heavy titles (3,000+ bubbles).

## Resuming

Every page is checkpointed to disk. Re-running skips books that are already complete for the same
model and prompt; a book translated with a different model or after you edit your ChatGPT prompt is
redone. Interrupting costs at most one page.

## Where the prompt comes from

The tool reads your synced ChatGPT prompt (`app/ai_chat_settings`) so offline explanations match
the style you already get online. If none is synced it falls back to the readers' default tutor
prompt.

## Tests

```
%LOCALAPPDATA%\HoshiPretranslate\python\python.exe tests\test_pretranslate.py
```

Covers bubble addressing, blob format, prompt construction, resume logic, and key encoding — no
GPU or network needed.
