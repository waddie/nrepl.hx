# Changelog

## c92639fc (2026-06-11)

### Added

- `:nrepl-interrupt` command. Interrupts the running evaluation; delivered to the server while the eval is still in flight.
- `:nrepl-stdin [text]` command. Sends a line of `stdin` to the running evaluation, prompting if no text is given.
- `:nrepl-toggle-auto-load` command. When on, saving a source buffer whose language matches the connection reloads it into the REPL.
- `:nrepl-toggle-debug` command. Toggles debug logging.
- `need-input` handling: evaluations that block on input prompt for a line and feed it back to the server.
- Interrupted results are marked as such in the `*nrepl*` buffer.
- `ex` / `root-ex` exception fields surfaced from responses and shown in results.
- Default key bindings for interrupt (`space.n.i`) and `stdin` (`space.n.S`).

### Changed

- Rust worker rewritten as a single-threaded async event loop over the command channel, socket reader, and active-eval deadline. Control ops (interrupt, `stdin`, completions, lookup, clone, close) are written immediately instead of waiting behind the current eval.
- `NReplClient` split into `NReplWriter` / `NReplReader` via `into_split`; response folding moved into a shared `EvalAccumulator`.
- Per-connection atomic request id source; wire id is the pure function `req-{n}`. Removed the global request id counter.
- Status decoding via `classify` / `StatusFlags` (done, need-input, interrupted, unknown-op, error).
- Registry blocking control ops clone the command sender and mint an id under a brief lock, then await the reply without holding the global registry lock.
- Lookup and project-file pickers now use fuzzy matching.
- `:nrepl-lookup-picker` renamed to `:nrepl-lookup`.
- Bencode map keys sorted on serialize.
- No longer strips surrounding quotes from string values.
