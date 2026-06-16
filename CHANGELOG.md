# Changelog

## v0.2.5 (2026-06-16)

### Fixed

- Added more limits when trying to find project files for jack-in: maximum
  depth scanned is 7, folders like `.git`, `.cache` are pruned, 10s timeout.
  Prevents endless scanning.

## v0.2.4 (2026-06-16)

### Fixed

- Couple of issues with the lookup picker in narrow terminals.

## v0.2.3 (2026-06-14)

### Added

- Fallback to server picker for Clojure buffers with no `deps.edn`/`bb.edn`

## v0.2.1 (2026-06-14)

### Added

- Track per-session evaluation number, e.g. for use in Janet prompts to
  match CLI behaviour.

## v0.2.0 (2026-06-13)

### Changed

- Refactor to allow visible `need-input` prompt before `stdin`.

## v0.1.5 (2026-06-13)

### Fixed

- Stray process ID display corruption fixed on jack-in

## v0.1.4 (2026-06-13)

### Added

- Janet language adapter, targeting the
  [janet-lang/nrepl-janet](https://github.com/janet-lang/nrepl-janet) server.

## v0.1.3 (2026-06-12)

### Fixed

- Connections to `nrepl-steel` servers started via jack-in would eventually
  become wedged.

## v0.1.0 (2026-06-12)

### Added

- Forge packaging. `nrepl.hx` is now installable with Steel’s package manager:
  `forge pkg install --git https://github.com/waddie/nrepl.hx`, then `(require
"nrepl.hx/nrepl.scm")`. A root `cog.scm` manifest advertises prebuilt
  `libsteel_nrepl` dylibs for `aarch64-macos`, `x86_64-macos`, `x86_64-linux`
  and `x86_64-windows`.
- Release workflow (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag
  builds the `steel-nrepl` dylib for each platform and attaches the binaries
  to a GitHub release. The release job verifies the tag matches `cog.scm`’s
  `version`.

### Changed

- Internal `cogs/nrepl/*.scm` requires are now sibling-relative (`(require "core.scm")`)
  rather than rooted at the Helix config dir (`(require "cogs/nrepl/core.scm")`), so
  the cog resolves correctly whether installed via Forge (`~/.steel/cogs/nrepl.hx/`)
  or copied into `~/.config/helix/` by `install.sh`.

## 7dc51c0a (2026-06-12)

### Fixed

- Errors returned from `guile-ares-rs` no longer break the connection

## f69b0590 (2026-06-11)

### Added

- `:nrepl-describe` command. Displays the connected server's capabilities
  (supported ops, implementation versions, and aux metadata) in the `*nrepl*`
  buffer with a one-line summary echoed.
- Capability negotiation: `describe` is now run automatically on connect and
  the result stored on the connection state. Optional ops are gated against the
  advertised op set — `:nrepl-lookup` reports a clear message when the server
  lacks `completions` support instead of opening an empty picker. Servers that
  don't answer `describe` stay optimistic (ops are still attempted).
- `describe` exposed through the steel-nrepl FFI worker/registry, following the
  same demux control-op path as `lookup`.

## c92639fc (2026-06-11)

### Added

- `:nrepl-interrupt` command. Interrupts the running evaluation; delivered to
  the server while the eval is still in flight.
- `:nrepl-stdin [text]` command. Sends a line of `stdin` to the running
  evaluation, prompting if no text is given.
- `:nrepl-toggle-auto-load` command. When on, saving a source buffer whose
  language matches the connection reloads it into the REPL.
- `:nrepl-toggle-debug` command. Toggles debug logging.
- `need-input` handling: evaluations that block on input prompt for a line and
  feed it back to the server.
- Interrupted results are marked as such in the `*nrepl*` buffer.
- `ex` / `root-ex` exception fields surfaced from responses and shown in results.
- Default key bindings for interrupt (`space.n.i`) and `stdin` (`space.n.S`).

### Changed

- Rust worker rewritten as a single-threaded async event loop over the command
  channel, socket reader, and active-eval deadline. Control ops (interrupt,
  `stdin`, completions, lookup, clone, close) are written immediately instead of
  waiting behind the current eval.
- `NReplClient` split into `NReplWriter` / `NReplReader` via `into_split`;
  response folding moved into a shared `EvalAccumulator`.
- Per-connection atomic request id source; wire id is the pure function
  `req-{n}`. Removed the global request id counter.
- Status decoding via `classify` / `StatusFlags` (done, need-input, interrupted,
  unknown-op, error).
- Registry blocking control ops clone the command sender and mint an id under a
  brief lock, then await the reply without holding the global registry lock.
- Lookup and project-file pickers now use fuzzy matching.
- `:nrepl-lookup-picker` renamed to `:nrepl-lookup`.
- Bencode map keys sorted on serialize.
- No longer strips surrounding quotes from string values.
