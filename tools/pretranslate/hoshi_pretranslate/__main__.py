"""`python -m hoshi_pretranslate` launches the GUI; any argument switches to the CLI."""

import os
import sys


def _ensure_streams() -> None:
    """Give the process real stdout/stderr before anything else runs.

    `pythonw.exe` starts a GUI process with NO console, and CPython then sets both
    `sys.stdout` and `sys.stderr` to `None`. Any library that writes a progress bar or a warning
    to stderr then dies with `AttributeError: 'NoneType' object has no attribute 'write'` —
    which is exactly how the model download failed.

    Pointing them at a log file fixes every such caller at once and leaves a file to read when
    something goes wrong in a windowless process.
    """
    if sys.stdout is not None and sys.stderr is not None:
        return
    handle = None
    try:
        from .config import app_dir

        directory = app_dir()
        directory.mkdir(parents=True, exist_ok=True)
        handle = open(directory / "app.log", "a", encoding="utf-8", errors="replace", buffering=1)
    except OSError:
        try:
            handle = open(os.devnull, "w", encoding="utf-8")
        except OSError:
            return
    if sys.stdout is None:
        sys.stdout = handle
    if sys.stderr is None:
        sys.stderr = handle


_ensure_streams()

if len(sys.argv) > 1:
    from .cli import main

    raise SystemExit(main())
else:
    from .gui import main

    main()
