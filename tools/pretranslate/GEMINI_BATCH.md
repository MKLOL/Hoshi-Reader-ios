# Gemini Batch translation for an EPUB

`gemini_epub_batch.py` uses Google's official `google-genai` SDK and Hoshi's existing EPUB
extractor. It creates file-backed, keyed JSONL requests for the Gemini Batch API, stores the raw
responses, validates every sentence ID and explanation, and merges accepted answers into Hoshi's
ordinary local EPUB checkpoint. It never uploads a partial translation to Hoshi sync.

The defaults are intentionally the book-two trial:

- EPUB: `~/Downloads/ふしぎ駄菓子屋銭天堂２.epub`
- sync ID: `zenitendou-02`
- model: `gemini-3.6-flash`
- selected prefix: 10% of the book
- request size: five target sentences
- context: four preceding sentences and one following sentence, within the same spine item
- thinking level: `medium`
- prompt: `GEMINI_EPUB_PROMPT.md`

The real file currently extracts to 2,390 sentences, so the initial trial contains exactly 239
sentences in 50 keyed requests. Batch jobs are asynchronous and can take up to Google's documented
turnaround target; submitting and monitoring are separate so closing the terminal loses nothing.

## Setup

From `tools/pretranslate/`:

```bash
PY=~/hoshi-work/venv-epub/bin/python
$PY -m pip install --no-user -r requirements.txt
export GEMINI_API_KEY='your-key-from-Google-AI-Studio'
```

The key is read only from `GEMINI_API_KEY` (or `GOOGLE_API_KEY`). There is no key command-line
option, and neither the request file nor job state stores it.

## Run the 10% trial

Inspect the exact local request plan without using the API:

```bash
$PY gemini_epub_batch.py prepare
```

Submit once:

```bash
$PY gemini_epub_batch.py submit
```

Check without waiting:

```bash
$PY gemini_epub_batch.py status
```

When the job has succeeded, download, validate, and merge it:

```bash
$PY gemini_epub_batch.py collect
```

Or poll every 60 seconds and collect automatically:

```bash
$PY gemini_epub_batch.py wait
```

`run` is shorthand for submit followed by wait. The submission display name is derived from the
request hash, and the script checks both local state and the remote job list before creation. This
matters because Google's batch-creation endpoint is not idempotent.

## Results and cost monitoring

Everything is under `work/zenitendou-02-gemini/`:

- `book.json`: immutable source/model/prompt identity
- `prompt.md`: exact prompt used for checkpoint invalidation
- `requests/`: immutable JSONL submitted to Google
- `plans/`: request keys and exact target IDs
- `jobs/`: durable remote job names, status, failures, and token usage
- `raw/`: byte-for-byte downloaded Batch API results
- `done/`: independently validated, import-ready translation chunks
- `checkpoint/zenitendou-02.json`: the accumulated local Hoshi blob

After collection, the script prints Batch API input, output, thinking, and total token counts. Use
those numbers and Google AI Studio billing to decide whether to continue. A malformed or incomplete
chunk is kept out of `done/`; valid chunks from the same job remain saved and a later `submit`
automatically requests only the missing sentences.

## Continue after approving cost and quality

The first 239 completed sentence IDs remain valid. To request the rest of the book without
resubmitting them:

```bash
$PY gemini_epub_batch.py submit --fraction 1.0
```

Then use `status`, `collect`, or `wait` as above. Changing the source EPUB, model, or prompt in the
same work directory is refused instead of silently overwriting completed work; use a new
`--work-dir` for a genuinely new run.
