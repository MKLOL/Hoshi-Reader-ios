"""Tkinter desktop UI: configure, pick a model, run, and browse the results.

Tkinter ships with Python, so the tool needs no GUI dependency and starts instantly. The heavy
work runs on a worker thread; the UI thread only drains a queue, so the window never freezes
during a multi-hour run.
"""

from __future__ import annotations

import html
import json
import queue
import threading
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from . import config as configmod
from . import models as modelsmod
from . import pipeline
from .blob import PretranslationsBlob
from .kv import KvClient, KvError


class App(ttk.Frame):
    def __init__(self, master: tk.Tk) -> None:
        super().__init__(master, padding=10)
        self.master.title("Hoshi Pre-translate")
        self.master.geometry("1000x720")
        self.grid(sticky="nsew")
        master.columnconfigure(0, weight=1)
        master.rowconfigure(0, weight=1)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(0, weight=1)

        self.config_data = configmod.load()
        self._events: queue.Queue = queue.Queue()
        self._worker: threading.Thread | None = None
        self._stop = threading.Event()
        self._server = None

        notebook = ttk.Notebook(self)
        notebook.grid(row=0, column=0, sticky="nsew")
        self._run_tab = ttk.Frame(notebook, padding=10)
        self._books_tab = ttk.Frame(notebook, padding=10)
        self._prompt_tab = ttk.Frame(notebook, padding=10)
        self._results_tab = ttk.Frame(notebook, padding=10)
        notebook.add(self._run_tab, text="Run")
        notebook.add(self._books_tab, text="Books")
        notebook.add(self._prompt_tab, text="Prompt")
        notebook.add(self._results_tab, text="Results")

        self._books: list = []
        self._build_run_tab()
        self._build_books_tab()
        self._build_prompt_tab()
        self._build_results_tab()
        self.after(100, self._drain_events)

    # -- Run tab -----------------------------------------------------------------------------

    def _build_run_tab(self) -> None:
        tab = self._run_tab
        tab.columnconfigure(1, weight=1)
        row = 0

        ttk.Label(tab, text="Sync server").grid(row=row, column=0, sticky="w", pady=3)
        self.var_url = tk.StringVar(value=self.config_data.base_url)
        ttk.Entry(tab, textvariable=self.var_url).grid(row=row, column=1, columnspan=2, sticky="ew", pady=3)
        row += 1

        ttk.Label(tab, text="Sync token").grid(row=row, column=0, sticky="w", pady=3)
        self.var_token = tk.StringVar(value=self.config_data.token)
        self.entry_token = ttk.Entry(tab, textvariable=self.var_token, show="*")
        self.entry_token.grid(row=row, column=1, sticky="ew", pady=3)
        self.var_show_token = tk.BooleanVar(value=False)
        ttk.Checkbutton(tab, text="Show", variable=self.var_show_token, command=self._toggle_token).grid(
            row=row, column=2, sticky="w", padx=6
        )
        row += 1

        ttk.Label(tab, text="Engine").grid(row=row, column=0, sticky="w", pady=3)
        self.var_engine = tk.StringVar()
        self._engine_labels = {
            "Cloud API - about 5 min per volume, a few cents (fastest)": "cloud",
            "Local GPU - about 1 hour per volume, free": "local",
        }
        reverse_engine = {v: k for k, v in self._engine_labels.items()}
        self.var_engine.set(reverse_engine.get(self.config_data.engine, next(iter(self._engine_labels))))
        engine_combo = ttk.Combobox(
            tab, textvariable=self.var_engine, values=list(self._engine_labels), state="readonly"
        )
        engine_combo.grid(row=row, column=1, columnspan=2, sticky="ew", pady=3)
        engine_combo.bind("<<ComboboxSelected>>", lambda _e: self._on_engine_changed())
        row += 1

        # -- cloud rows (hidden when the local GPU is selected) --
        self.lbl_cloud_provider = ttk.Label(tab, text="Provider")
        self.lbl_cloud_provider.grid(row=row, column=0, sticky="w", pady=3)
        self.var_cloud_provider = tk.StringVar()
        from .cloud import PROVIDERS, provider_by_id

        self._provider_labels = {p.display_name: p.id for p in PROVIDERS}
        rev_p = {v: k for k, v in self._provider_labels.items()}
        self.var_cloud_provider.set(
            rev_p.get(self.config_data.cloud_provider, next(iter(self._provider_labels)))
        )
        self.combo_provider = ttk.Combobox(
            tab, textvariable=self.var_cloud_provider,
            values=list(self._provider_labels), state="readonly",
        )
        self.combo_provider.grid(row=row, column=1, sticky="ew", pady=3)
        self.btn_cloud_test = ttk.Button(tab, text="Test key", command=self._test_cloud)
        self.btn_cloud_test.grid(row=row, column=2, sticky="ew", padx=6)
        self.combo_provider.bind("<<ComboboxSelected>>", lambda _e: self._on_provider_changed())
        row += 1

        self.lbl_cloud_key = ttk.Label(tab, text="API key")
        self.lbl_cloud_key.grid(row=row, column=0, sticky="w", pady=3)
        self.var_cloud_key = tk.StringVar(value=self.config_data.cloud_key)
        self.entry_cloud_key = ttk.Entry(tab, textvariable=self.var_cloud_key, show="*")
        self.entry_cloud_key.grid(row=row, column=1, sticky="ew", pady=3)
        self.var_show_key = tk.BooleanVar(value=False)
        self.chk_show_key = ttk.Checkbutton(
            tab, text="Show", variable=self.var_show_key,
            command=lambda: self.entry_cloud_key.configure(
                show="" if self.var_show_key.get() else "*"
            ),
        )
        self.chk_show_key.grid(row=row, column=2, sticky="w", padx=6)
        row += 1

        self.lbl_cloud_model = ttk.Label(tab, text="Cloud model")
        self.lbl_cloud_model.grid(row=row, column=0, sticky="w", pady=3)
        self.var_cloud_model = tk.StringVar(
            value=self.config_data.cloud_model or provider_by_id(self.config_data.cloud_provider).default_model
        )
        self.entry_cloud_model = ttk.Entry(tab, textvariable=self.var_cloud_model)
        self.entry_cloud_model.grid(row=row, column=1, sticky="ew", pady=3)
        self.lbl_cloud_note = ttk.Label(tab, text="", foreground="#555", wraplength=300)
        self.lbl_cloud_note.grid(row=row, column=2, sticky="w", padx=6)
        row += 1

        self.lbl_model_row = ttk.Label(tab, text="Model")
        self.lbl_model_row.grid(row=row, column=0, sticky="w", pady=3)
        self.var_model = tk.StringVar()
        self._model_labels = {m.label(): m for m in modelsmod.CATALOG}
        self.combo_model = ttk.Combobox(
            tab, textvariable=self.var_model, values=list(self._model_labels), state="readonly"
        )
        current = modelsmod.by_id(self.config_data.model_id) or modelsmod.default_model()
        self.var_model.set(current.label())
        self.combo_model.grid(row=row, column=1, sticky="ew", pady=3)
        self._local_row_widgets = [self.lbl_model_row, self.combo_model]
        self.combo_model.bind("<<ComboboxSelected>>", lambda _e: self._on_model_changed())
        self.btn_download = ttk.Button(tab, text="Download", command=self._download_model)
        self.btn_download.grid(row=row, column=2, sticky="ew", padx=6)
        row += 1

        self.lbl_model_note = ttk.Label(tab, text="", wraplength=760, foreground="#555")
        self.lbl_model_note.grid(row=row, column=1, columnspan=2, sticky="w", pady=(0, 6))
        row += 1

        ttk.Label(tab, text="Context").grid(row=row, column=0, sticky="w", pady=3)
        self.var_mode = tk.StringVar()
        self._mode_labels = {
            "Per bubble - page + previous page as context (best quality)": "focused",
            "Per page - translate a whole page at once (~25% faster)": "page",
        }
        reverse = {v: k for k, v in self._mode_labels.items()}
        self.var_mode.set(reverse.get(self.config_data.mode, next(iter(self._mode_labels))))
        ttk.Combobox(
            tab, textvariable=self.var_mode, values=list(self._mode_labels), state="readonly"
        ).grid(row=row, column=1, columnspan=2, sticky="ew", pady=3)
        row += 1

        ttk.Label(tab, text="Output folder").grid(row=row, column=0, sticky="w", pady=3)
        self.var_output = tk.StringVar(value=self.config_data.output_dir)
        ttk.Entry(tab, textvariable=self.var_output).grid(row=row, column=1, sticky="ew", pady=3)
        ttk.Button(tab, text="Browse", command=self._pick_output).grid(row=row, column=2, sticky="ew", padx=6)
        row += 1

        self.var_upload = tk.BooleanVar(value=self.config_data.upload)
        ttk.Checkbutton(
            tab, text="Upload each finished book to the sync server", variable=self.var_upload
        ).grid(row=row, column=1, sticky="w", pady=3)
        row += 1

        buttons = ttk.Frame(tab)
        buttons.grid(row=row, column=0, columnspan=3, sticky="w", pady=8)
        self.btn_start = ttk.Button(buttons, text="Start", command=self._start)
        self.btn_start.grid(row=0, column=0, padx=(0, 6))
        self.btn_stop = ttk.Button(buttons, text="Stop", command=self._request_stop, state="disabled")
        self.btn_stop.grid(row=0, column=1, padx=6)
        ttk.Button(buttons, text="Test connection", command=self._test_connection).grid(row=0, column=2, padx=6)
        row += 1

        self.lbl_status = ttk.Label(tab, text="Idle")
        self.lbl_status.grid(row=row, column=0, columnspan=3, sticky="w")
        row += 1
        self.bar_books = ttk.Progressbar(tab, mode="determinate")
        self.bar_books.grid(row=row, column=0, columnspan=3, sticky="ew", pady=2)
        row += 1
        self.bar_pages = ttk.Progressbar(tab, mode="determinate")
        self.bar_pages.grid(row=row, column=0, columnspan=3, sticky="ew", pady=2)
        row += 1

        tab.rowconfigure(row, weight=1)
        self.text_log = tk.Text(tab, height=14, wrap="word")
        self.text_log.grid(row=row, column=0, columnspan=3, sticky="nsew", pady=(8, 0))
        scroll = ttk.Scrollbar(tab, command=self.text_log.yview)
        scroll.grid(row=row, column=3, sticky="ns", pady=(8, 0))
        self.text_log.configure(yscrollcommand=scroll.set)

        self._local_row_widgets += [self.lbl_model_note, self.btn_download]
        self._cloud_row_widgets = [
            self.lbl_cloud_provider, self.combo_provider, self.btn_cloud_test,
            self.lbl_cloud_key, self.entry_cloud_key, self.chk_show_key,
            self.lbl_cloud_model, self.entry_cloud_model, self.lbl_cloud_note,
        ]
        self._on_model_changed()
        self._on_provider_changed()
        self._on_engine_changed()

    def _current_engine(self) -> str:
        return self._engine_labels.get(self.var_engine.get(), "local")

    def _on_engine_changed(self) -> None:
        """Only the rows that apply to the chosen engine stay visible."""
        cloud = self._current_engine() == "cloud"
        for widget in self._cloud_row_widgets:
            if cloud:
                widget.grid()
            else:
                widget.grid_remove()
        for widget in self._local_row_widgets:
            if cloud:
                widget.grid_remove()
            else:
                widget.grid()

    def _cloud_provider(self):
        from .cloud import provider_by_id

        return provider_by_id(self._provider_labels.get(self.var_cloud_provider.get(), "google"))

    def _on_provider_changed(self) -> None:
        provider = self._cloud_provider()
        self.lbl_cloud_note.configure(text=provider.note)
        # Swap in the provider's default model unless the user typed their own.
        current = self.var_cloud_model.get().strip()
        known = {p.default_model for p in __import__(
            "hoshi_pretranslate.cloud", fromlist=["PROVIDERS"]).PROVIDERS}
        if not current or current in known:
            self.var_cloud_model.set(provider.default_model)

    def _cloud_translator(self):
        from .cloud import CloudTranslator

        return CloudTranslator(
            self._cloud_provider(),
            self.var_cloud_key.get(),
            self.var_cloud_model.get(),
            mode=self.config_data.mode,
            concurrency=self.config_data.cloud_concurrency,
            log=self.log,
        )

    def _test_cloud(self) -> None:
        self._persist()

        def work() -> None:
            try:
                translator = self._cloud_translator()
                message = translator.check()
                translator.close()
                self._events.put(("cloud_ok", message))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Cloud test failed: {exc}"))

        self._spawn(work)

    def _toggle_token(self) -> None:
        self.entry_token.configure(show="" if self.var_show_token.get() else "*")

    def _selected_model(self) -> modelsmod.GgufModel:
        return self._model_labels.get(self.var_model.get()) or modelsmod.default_model()

    def _on_model_changed(self) -> None:
        model = self._selected_model()
        present = modelsmod.is_downloaded(model, Path(self.config_data.models_dir))
        state = "on disk" if present else "not downloaded yet"
        self.lbl_model_note.configure(text=f"{model.note}  ({state})")
        self.btn_download.configure(text="Downloaded" if present else "Download")

    def _pick_output(self) -> None:
        chosen = filedialog.askdirectory(initialdir=self.var_output.get() or ".")
        if chosen:
            self.var_output.set(chosen)

    @staticmethod
    def _tk_safe(text: str) -> str:
        """Tk 8.6 raises on characters above U+FFFF; CJK Ext-B kanji in titles would kill the UI."""
        return "".join(ch if ord(ch) <= 0xFFFF else "\uFFFD" for ch in str(text))

    def log(self, message: str) -> None:
        self._events.put(("log", self._tk_safe(message)))

    # -- actions -----------------------------------------------------------------------------

    def _persist(self) -> None:
        self.config_data.base_url = self.var_url.get().strip()
        self.config_data.token = self.var_token.get().strip()
        self.config_data.model_id = self._selected_model().id
        self.config_data.output_dir = self.var_output.get().strip()
        self.config_data.upload = bool(self.var_upload.get())
        self.config_data.mode = self._mode_labels.get(self.var_mode.get(), "focused")
        self.config_data.engine = self._current_engine()
        self.config_data.cloud_provider = self._provider_labels.get(
            self.var_cloud_provider.get(), "google"
        )
        self.config_data.cloud_key = self.var_cloud_key.get().strip()
        self.config_data.cloud_model = self.var_cloud_model.get().strip()
        if hasattr(self, "text_prompt"):
            self.config_data.prompt_override = self.text_prompt.get("1.0", "end").strip()
        if hasattr(self, "books_tree"):
            self.config_data.book_order = [b["syncId"] for b in self._books]
            self.config_data.selected_books = [
                b["syncId"] for b in self._books if b["include"]
            ]
        configmod.save(self.config_data)

    def _client(self) -> KvClient:
        return KvClient(self.var_url.get().strip(), self.var_token.get().strip())

    def _test_connection(self) -> None:
        if self._worker and self._worker.is_alive():
            messagebox.showwarning("Busy", "Wait for the current run to finish.")
            return
        self._persist()

        def work() -> None:
            # On a worker thread: discover_manga issues 1 + N gated requests, and with no network
            # the retry backoff alone sleeps ~31 s — long enough to freeze the window.
            try:
                books = pipeline.discover_manga(self._client(), log=self.log)
                self._events.put(("connected", len(books)))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Connection failed: {exc}"))

        self._spawn(work)

    def _download_model(self) -> None:
        if self._worker and self._worker.is_alive():
            messagebox.showwarning("Busy", "Wait for the current run to finish.")
            return
        self._persist()
        model = self._selected_model()

        self._stop.clear()
        self.btn_stop.configure(state="normal")

        def work() -> None:
            try:
                # Throttle: the raw callback fires per megabyte, which would be ~22,000 UI
                # events for the recommended model.
                state = {"next": 0}

                def on_progress(done: int, total: int) -> None:
                    if done >= state["next"] or done == total:
                        state["next"] = done + (1 << 26)  # ~67 MB
                        self._events.put(("download", (done, total)))

                modelsmod.download(
                    model,
                    Path(self.config_data.models_dir),
                    log=self.log,
                    progress=on_progress,
                    should_stop=self._stop.is_set,
                )
                self._events.put(("model_ready", ""))
            except Exception as exc:  # noqa: BLE001 - surface anything to the UI
                self._events.put(("error", f"Model download failed: {exc}"))

        self._spawn(work)

    def _start(self) -> None:
        if self._worker and self._worker.is_alive():
            return
        self._persist()
        if not self.config_data.token:
            messagebox.showerror("Missing token", "Paste your sync token first.")
            return
        engine = self._current_engine()
        model = self._selected_model()
        models_dir = Path(self.config_data.models_dir)
        if engine == "local" and not modelsmod.is_downloaded(model, models_dir):
            messagebox.showerror(
                "Model missing", f"Download {model.display_name} first (the Download button)."
            )
            return
        if engine == "cloud" and not self.var_cloud_key.get().strip():
            messagebox.showerror("Missing API key", "Paste your API key for the chosen provider.")
            return

        self._stop.clear()
        self.btn_start.configure(state="disabled")
        self.btn_stop.configure(state="normal")

        def work_cloud() -> None:
            try:
                translator = self._cloud_translator()
                self.log(translator.check())
                pipeline.run(
                    self._client(),
                    translator,
                    model_id=translator.model,
                    out_dir=Path(self.config_data.output_dir),
                    log=self.log,
                    should_stop=self._stop.is_set,
                    on_progress=lambda p: self._events.put(("progress", p)),
                    upload=self.config_data.upload,
                    only_sync_ids=self.config_data.selected_books or None,
                    prompt_override=self.config_data.prompt_override or None,
                )
                translator.close()
                self._events.put(("done", ""))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", str(exc)))

        if engine == "cloud":
            self._spawn(work_cloud)
            return

        def work() -> None:
            try:
                from .llm import LocalTranslator
                from .runtime import LlamaServer, install, is_installed

                runtime_base = Path(self.config_data.models_dir).parent
                if not is_installed(runtime_base):
                    install(runtime_base, log=self.log)

                client = self._client()
                server = LlamaServer(
                    runtime_base,
                    modelsmod.local_path(model, models_dir),
                    n_ctx=self.config_data.n_ctx,
                    log=self.log,
                )
                self._server = server
                server.start()
                try:
                    translator = LocalTranslator(
                        server.base_url, mode=self.config_data.mode, log=self.log
                    )
                    pipeline.run(
                        client,
                        translator,
                        model_id=model.id,
                        out_dir=Path(self.config_data.output_dir),
                        log=self.log,
                        should_stop=self._stop.is_set,
                        on_progress=lambda p: self._events.put(("progress", p)),
                        upload=self.config_data.upload,
                        only_sync_ids=self.config_data.selected_books or None,
                        prompt_override=self.config_data.prompt_override or None,
                    )
                    translator.close()
                finally:
                    server.stop()
                    self._server = None
                self._events.put(("done", ""))
            except Exception as exc:  # noqa: BLE001
                self._server = None
                self._events.put(("error", str(exc)))

        self._spawn(work)

    def _spawn(self, work) -> None:
        self._worker = threading.Thread(target=work, daemon=True)
        self._worker.start()

    def shutdown(self) -> None:
        """Stops the run and the llama.cpp server before the window closes."""
        self._stop.set()
        server = self._server
        if server is not None:
            try:
                server.stop()
            except Exception:  # noqa: BLE001
                pass
            self._server = None

    def _request_stop(self) -> None:
        self._stop.set()
        self.log("Stopping after the current page ...")

    # -- event pump --------------------------------------------------------------------------

    def _drain_events(self) -> None:
        try:
            while True:
                kind, payload = self._events.get_nowait()
                if kind == "log":
                    self.text_log.insert("end", self._tk_safe(payload) + "\n")
                    self.text_log.see("end")
                elif kind == "progress":
                    self._apply_progress(payload)
                elif kind == "download":
                    done, total = payload
                    gb = done / 1e9
                    if total:
                        self.lbl_status.configure(
                            text=f"Downloading model: {gb:.1f} / {total / 1e9:.1f} GB "
                            f"({done * 100 // total}%)"
                        )
                        self.bar_pages.configure(maximum=total, value=done)
                    else:
                        self.lbl_status.configure(text=f"Downloading model: {gb:.1f} GB")
                elif kind == "cloud_ok":
                    messagebox.showinfo("Cloud API", str(payload))
                elif kind == "books":
                    self._apply_books(payload)
                    self.log(f"Loaded {len(payload)} manga from the server.")
                elif kind == "prompt":
                    self.text_prompt.delete("1.0", "end")
                    self.text_prompt.insert("1.0", self._tk_safe(payload))
                elif kind == "connected":
                    messagebox.showinfo(
                        "Connected", f"Found {payload} manga volume(s) on the server."
                    )
                elif kind == "model_ready":
                    self._on_model_changed()
                    self.btn_stop.configure(state="disabled")
                    self.lbl_status.configure(text="Model ready")
                    self.log("Model ready.")
                elif kind == "done":
                    self.lbl_status.configure(text="Finished")
                    self.btn_start.configure(state="normal")
                    self.btn_stop.configure(state="disabled")
                    self._reload_results()
                    self.log("All done.")
                elif kind == "error":
                    self.btn_start.configure(state="normal")
                    self.btn_stop.configure(state="disabled")
                    self.log(f"ERROR: {payload}")
                    messagebox.showerror("Error", str(payload))
        except queue.Empty:
            pass
        except Exception:  # noqa: BLE001
            # Never let a rendering error kill the pump: the worker would keep translating for
            # hours behind a frozen window with no log output and a disabled Start button.
            pass
        finally:
            self.after(100, self._drain_events)

    def _apply_progress(self, progress: pipeline.Progress) -> None:
        self.lbl_status.configure(
            text=(
                f"Book {progress.book_index}/{progress.book_total}: {progress.book_title}   "
                f"page {progress.page_index}/{progress.page_total}   "
                f"bubbles {progress.bubbles_done}/{progress.bubbles_total}   "
                f"{progress.bubbles_per_minute:.0f}/min   {progress.eta_text()}"
            )
        )
        self.bar_books.configure(maximum=max(1, progress.book_total), value=progress.book_index)
        self.bar_pages.configure(maximum=max(1, progress.page_total), value=progress.page_index)

    # -- Books tab ---------------------------------------------------------------------------

    def _build_books_tab(self) -> None:
        tab = self._books_tab
        tab.columnconfigure(0, weight=1)
        tab.rowconfigure(2, weight=1)

        ttk.Label(
            tab,
            text="Order of processing, top first. Untick anything you don't want translated.\n"
                 "Stopping mid-run keeps everything already finished, so put what matters on top.",
            foreground="#555",
        ).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 8))

        bar = ttk.Frame(tab)
        bar.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(0, 6))
        ttk.Button(bar, text="Load from server", command=self._load_books).grid(row=0, column=0)
        ttk.Button(bar, text="Move up", command=lambda: self._move_book(-1)).grid(row=0, column=1, padx=6)
        ttk.Button(bar, text="Move down", command=lambda: self._move_book(1)).grid(row=0, column=2)
        ttk.Button(bar, text="Include / exclude", command=self._toggle_book).grid(row=0, column=3, padx=6)
        ttk.Button(bar, text="All", command=lambda: self._set_all(True)).grid(row=0, column=4)
        ttk.Button(bar, text="None", command=lambda: self._set_all(False)).grid(row=0, column=5, padx=6)
        self.lbl_books = ttk.Label(bar, text="")
        self.lbl_books.grid(row=0, column=6, padx=10)

        self.books_tree = ttk.Treeview(
            tab, columns=("include", "title"), show="headings", selectmode="browse"
        )
        self.books_tree.heading("include", text="Translate")
        self.books_tree.heading("title", text="Manga")
        self.books_tree.column("include", width=80, anchor="center", stretch=False)
        self.books_tree.column("title", width=600)
        self.books_tree.grid(row=2, column=0, sticky="nsew")
        scroll = ttk.Scrollbar(tab, command=self.books_tree.yview)
        scroll.grid(row=2, column=1, sticky="ns")
        self.books_tree.configure(yscrollcommand=scroll.set)
        # Double-click a row to include/exclude it.
        self.books_tree.bind("<Double-1>", lambda _e: self._toggle_book())

    def _load_books(self) -> None:
        if self._worker and self._worker.is_alive():
            messagebox.showwarning("Busy", "Wait for the current run to finish.")
            return
        self._persist()

        def work() -> None:
            try:
                found = pipeline.discover_manga(self._client(), log=self.log)
                self._events.put(("books", [(b.sync_id, b.title) for b in found]))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Could not list manga: {exc}"))

        self._spawn(work)

    def _apply_books(self, found: list) -> None:
        """Merges the server listing with the saved order and selection."""
        saved_order = list(self.config_data.book_order or [])
        selected = self.config_data.selected_books
        by_id = {sync_id: title for sync_id, title in found}
        ordered_ids = [s for s in saved_order if s in by_id]
        ordered_ids += [s for s, _ in found if s not in ordered_ids]
        self._books = [
            {
                "syncId": sync_id,
                "title": by_id[sync_id],
                # No saved selection yet means "everything", which is the sane first run.
                "include": (sync_id in selected) if selected else True,
            }
            for sync_id in ordered_ids
        ]
        self._refresh_books_tree()

    def _refresh_books_tree(self) -> None:
        self.books_tree.delete(*self.books_tree.get_children())
        for index, book in enumerate(self._books):
            self.books_tree.insert(
                "", "end", iid=str(index),
                values=("yes" if book["include"] else "-", self._tk_safe(book["title"])),
            )
        included = sum(1 for b in self._books if b["include"])
        self.lbl_books.configure(text=f"{included} of {len(self._books)} selected")

    def _selected_book_index(self) -> int | None:
        selection = self.books_tree.selection()
        if not selection:
            return None
        try:
            return int(selection[0])
        except ValueError:
            return None

    def _move_book(self, delta: int) -> None:
        index = self._selected_book_index()
        if index is None:
            return
        target = index + delta
        if not (0 <= target < len(self._books)):
            return
        self._books[index], self._books[target] = self._books[target], self._books[index]
        self._refresh_books_tree()
        self.books_tree.selection_set(str(target))
        self.books_tree.see(str(target))

    def _toggle_book(self) -> None:
        index = self._selected_book_index()
        if index is None:
            return
        self._books[index]["include"] = not self._books[index]["include"]
        self._refresh_books_tree()
        self.books_tree.selection_set(str(index))

    def _set_all(self, include: bool) -> None:
        for book in self._books:
            book["include"] = include
        self._refresh_books_tree()

    # -- Prompt tab --------------------------------------------------------------------------

    def _build_prompt_tab(self) -> None:
        tab = self._prompt_tab
        tab.columnconfigure(0, weight=1)
        tab.rowconfigure(2, weight=1)

        ttk.Label(
            tab,
            text="The instruction sent with every bubble. Leave this empty to use the prompt your "
                 "app already syncs.",
            foreground="#555",
        ).grid(row=0, column=0, sticky="w", pady=(0, 6))

        bar = ttk.Frame(tab)
        bar.grid(row=1, column=0, sticky="ew", pady=(0, 6))
        ttk.Button(bar, text="Load the app's synced prompt", command=self._load_synced_prompt).grid(row=0, column=0)
        ttk.Button(bar, text="Reset to default", command=self._reset_prompt).grid(row=0, column=1, padx=6)

        self.text_prompt = tk.Text(tab, height=12, wrap="word")
        self.text_prompt.grid(row=2, column=0, sticky="nsew")
        self.text_prompt.insert("1.0", self.config_data.prompt_override or "")

        ttk.Label(
            tab,
            text="Changing this re-translates every book: finished work is keyed to the prompt it "
                 "was made with, so a book already done with the old prompt will be redone on the "
                 "next run. Books you have not touched are unaffected.",
            foreground="#a05000",
            wraplength=900,
        ).grid(row=3, column=0, sticky="w", pady=(8, 0))

    def _load_synced_prompt(self) -> None:
        self._persist()

        def work() -> None:
            try:
                prompt = pipeline.fetch_user_prompt(self._client(), log=self.log)
                self._events.put(("prompt", prompt))
            except Exception as exc:  # noqa: BLE001
                self._events.put(("error", f"Could not read the synced prompt: {exc}"))

        self._spawn(work)

    def _reset_prompt(self) -> None:
        self.text_prompt.delete("1.0", "end")
        self.text_prompt.insert("1.0", pipeline.FALLBACK_PROMPT)

    # -- Results tab -------------------------------------------------------------------------

    def _build_results_tab(self) -> None:
        tab = self._results_tab
        tab.columnconfigure(1, weight=1)
        tab.rowconfigure(1, weight=1)

        bar = ttk.Frame(tab)
        bar.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 6))
        ttk.Button(bar, text="Refresh", command=self._reload_results).grid(row=0, column=0)
        ttk.Button(bar, text="Open as web page", command=self._export_html).grid(row=0, column=1, padx=6)
        self.lbl_results = ttk.Label(bar, text="")
        self.lbl_results.grid(row=0, column=2, padx=10)

        left = ttk.Frame(tab)
        left.grid(row=1, column=0, sticky="nsw")
        left.rowconfigure(0, weight=1)
        self.tree = ttk.Treeview(left, columns=("preview",), show="tree headings", height=25)
        self.tree.heading("#0", text="Book / bubble")
        self.tree.heading("preview", text="Japanese")
        self.tree.column("#0", width=260)
        self.tree.column("preview", width=220)
        self.tree.grid(row=0, column=0, sticky="ns")
        tree_scroll = ttk.Scrollbar(left, command=self.tree.yview)
        tree_scroll.grid(row=0, column=1, sticky="ns")
        self.tree.configure(yscrollcommand=tree_scroll.set)
        self.tree.bind("<<TreeviewSelect>>", lambda _e: self._show_selected())

        right = ttk.Frame(tab)
        right.grid(row=1, column=1, sticky="nsew", padx=(10, 0))
        right.columnconfigure(0, weight=1)
        right.rowconfigure(0, weight=1)
        self.text_detail = tk.Text(right, wrap="word")
        self.text_detail.grid(row=0, column=0, sticky="nsew")
        detail_scroll = ttk.Scrollbar(right, command=self.text_detail.yview)
        detail_scroll.grid(row=0, column=1, sticky="ns")
        self.text_detail.configure(yscrollcommand=detail_scroll.set)
        self.text_detail.tag_configure("jp", font=("Yu Gothic UI", 16))
        self.text_detail.tag_configure("head", font=("Segoe UI", 10, "bold"))
        self.text_detail.tag_configure("body", font=("Segoe UI", 11))

        self._results: dict[str, PretranslationsBlob] = {}
        self._reload_results()

    def _reload_results(self) -> None:
        out_dir = Path(self.var_output.get().strip() or self.config_data.output_dir)
        self.tree.delete(*self.tree.get_children())
        self._results.clear()
        if not out_dir.exists():
            self.lbl_results.configure(text=f"No results yet in {out_dir}")
            return
        total = 0
        for path in sorted(out_dir.glob("*.json")):
            try:
                blob = PretranslationsBlob.from_json(json.loads(path.read_text(encoding="utf-8")))
            except (ValueError, OSError):
                continue
            self._results[path.stem] = blob
            node = self.tree.insert(
                "", "end", iid=path.stem,
                text=self._tk_safe(f"{blob.title} ({len(blob.entries)})"), values=("",)
            )
            for block_id, entry in sorted(blob.entries.items(), key=_block_sort_key):
                total += 1
                preview = self._tk_safe(entry.text.replace("\n", " ")[:24])
                self.tree.insert(
                    node, "end", iid=f"{path.stem}|{block_id}", text=block_id, values=(preview,)
                )
        self.lbl_results.configure(text=f"{len(self._results)} book(s), {total} translated bubbles")

    def _show_selected(self) -> None:
        selection = self.tree.selection()
        if not selection:
            return
        item = selection[0]
        self.text_detail.delete("1.0", "end")
        if "|" not in item:
            blob = self._results.get(item)
            if blob:
                self.text_detail.insert("end", f"{blob.title}\n", "head")
                self.text_detail.insert(
                    "end",
                    f"model: {blob.model}\ngenerated: {blob.generated_at}\n"
                    f"bubbles: {len(blob.entries)}\n",
                    "body",
                )
            return
        stem, block_id = item.split("|", 1)
        blob = self._results.get(stem)
        entry = blob.entries.get(block_id) if blob else None
        if not entry:
            return
        self.text_detail.insert("end", "Japanese\n", "head")
        self.text_detail.insert("end", self._tk_safe(entry.text) + "\n\n", "jp")
        self.text_detail.insert("end", "Translation\n", "head")
        self.text_detail.insert("end", self._tk_safe(entry.translation) + "\n\n", "body")
        self.text_detail.insert("end", "Explanation\n", "head")
        self.text_detail.insert("end", self._tk_safe(entry.explanation) + "\n", "body")

    def _export_html(self) -> None:
        """Writes a self-contained review page for the selected book and opens it in the browser."""
        selection = self.tree.selection()
        stem = selection[0].split("|", 1)[0] if selection else next(iter(self._results), None)
        if not stem or stem not in self._results:
            messagebox.showinfo("Nothing to show", "Run a translation first.")
            return
        blob = self._results[stem]
        rows = []
        for block_id, entry in sorted(blob.entries.items(), key=_block_sort_key):
            rows.append(
                "<tr>"
                f"<td class='id'>{html.escape(block_id)}</td>"
                f"<td class='jp'>{html.escape(entry.text)}</td>"
                f"<td>{html.escape(entry.translation)}</td>"
                f"<td class='note'>{html.escape(entry.explanation)}</td>"
                "</tr>"
            )
        page = f"""<!doctype html><meta charset="utf-8">
<title>{html.escape(blob.title)}</title>
<style>
 body {{ font: 15px/1.6 "Segoe UI", system-ui, sans-serif; margin: 2rem auto; max-width: 1100px; }}
 h1 {{ font-size: 1.3rem; }}
 table {{ border-collapse: collapse; width: 100%; }}
 td, th {{ border-bottom: 1px solid #ddd; padding: 8px; vertical-align: top; text-align: left; }}
 .id {{ color: #888; font-family: monospace; white-space: nowrap; }}
 .jp {{ font-size: 1.15rem; white-space: pre-line; }}
 .note {{ color: #444; }}
 @media (prefers-color-scheme: dark) {{
   body {{ background: #14161a; color: #e6e6e6; }}
   td, th {{ border-color: #333; }}
   .note {{ color: #b9b9b9; }}
 }}
</style>
<h1>{html.escape(blob.title)}</h1>
<p>{len(blob.entries)} bubbles &middot; {html.escape(blob.model)} &middot; {html.escape(blob.generated_at)}</p>
<table><tr><th>Bubble</th><th>Japanese</th><th>Translation</th><th>Explanation</th></tr>
{''.join(rows)}
</table>"""
        target = Path(self.var_output.get().strip() or self.config_data.output_dir) / f"{stem}.html"
        target.write_text(page, encoding="utf-8")
        webbrowser.open(target.as_uri())


def _block_sort_key(item) -> tuple[int, int]:
    """Sorts `p12b3` numerically rather than lexically so page 2 precedes page 10."""
    block_id = item[0]
    try:
        page, block = block_id[1:].split("b", 1)
        return int(page), int(block)
    except (ValueError, IndexError):
        return (1 << 30, 0)


def main() -> None:
    root = tk.Tk()
    app = App(root)

    def on_close() -> None:
        # The worker is a daemon thread, so without this the interpreter exits without unwinding
        # it and llama-server.exe survives holding the GPU — and the next run would then silently
        # attach to that stale server.
        app.shutdown()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
