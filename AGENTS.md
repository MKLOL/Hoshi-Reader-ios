# Repository implementation rules

- Prefer a well-maintained, platform-appropriate library for standard formats, protocols, parsing,
  rendering, networking conventions, and other solved problems whenever a suitable library exists.
- Do not write or extend a custom parser or renderer when an established library can satisfy the
  requirement. In particular, all user-visible Markdown must be parsed and rendered by a Markdown
  library; do not add hand-written Markdown token, block, table, or heading parsing.
- Before adding a dependency, verify that it is maintained, compatible with the deployment target,
  and scoped to the smallest necessary surface.
- If a library cannot be used, document the concrete incompatibility before implementing custom
  behavior.
- Commit your work. Do not leave finished work sitting in the working tree waiting to be asked:
  once a coherent unit builds and its tests pass, commit it. Uncommitted work is work that can be
  lost, cannot be reviewed, and cannot be bisected. Prefer several small commits over one sweep at
  the end.
- Keep generated and third-party content out of git. Source `.epub`/`.cbz` files, batch
  request/response dumps and per-book translation checkpoints live under
  `tools/pretranslate/work/`, which is ignored — never commit a copyrighted book into this repo.
