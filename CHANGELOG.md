# Changelog

## 0.4.2 (2026-07-18)

### Fixed

- `:nrepl-copy-jack-in-command` copies the raw command (no outer shell quoting), includes the configured env prefix, and now supports shadow-cljs and Leiningen profile selections (persisted selections; picker defaults otherwise).
- Project config state (`.helix/nrepl-jack-in.scm`) no longer leaks across projects or duplicates middleware on repeated loads: a baseline is restored before each load.
- Errors in `.helix/nrepl-jack-in.scm` are surfaced at jack-in instead of silently ignored.
- shadow-cljs jack-in exports env vars before the `cd`, so the server command stays guarded by the `cd` succeeding.
- Doc-preview lookups that time out are negative-cached instead of re-submitted indefinitely.
- Lookup info keys that are not valid Steel keyword tokens are skipped instead of producing unparseable previews.

### Changed

- Completion/lookup polling backs off from 10ms to 50ms while waiting, cutting main-thread wakeups.
- Shared connect/finish flow for fixed-port and port-file jack-in paths; shared launch wrapper for port-file servers.

## v0.4.0 (2026-07-17)

### Added

- Jack-in dependency version configuration: `(nrepl-set-jack-in-version key version)` sets versions for `nrepl`, `cider-nrepl`, and `piggieback`. Defaults: nrepl 1.7.0, cider-nrepl 0.62.1, piggieback 0.7.0.
- Extra nREPL middleware: `(nrepl-add-jack-in-middleware "my.middleware/wrap")` adds custom middleware to jack-in commands.
- Leiningen jack-in now injects nrepl and cider-nrepl via dependency/plugin `lein update-in ... --` chains, enabling cider operations on Leiningen projects.
- Jack-in environment variables: `(nrepl-set-jack-in-env '(("K" . "v") ...))` exported before the server command.
- Per-project configuration: `.helix/nrepl-jack-in.scm` in the workspace root is auto-loaded at jack-in. Supports directives: `nrepl-configure-jack-in`, `nrepl-set-jack-in-version`, `nrepl-add-jack-in-middleware`, `nrepl-set-jack-in-env`, `nrepl-set-after-jack-in-code`.
- After-connect code: `(nrepl-set-after-jack-in-code "(require 'dev)")` evaluates code in the session after jack-in connects. Accepts a single string or list of strings.
- `:nrepl-connect` without an address now auto-connects to `.nrepl-port` in the workspace root, falling back to the address prompt.
- `:nrepl-jack-out` command kills the jack-in-spawned server and disconnects (errors if the server was not started by jack-in).
- `:nrepl-copy-jack-in-command` command resolves the jack-in command for the nearest manifest and copies it to the clipboard.
- nbb server recipe in the Clojure fallback server picker: `npx nbb nrepl-server :port <port>`.
- basilisp jack-in for Python projects: detects pyproject.toml, setup.py, Pipfile, or requirements.txt and starts `basilisp nrepl-server --port <port>`.
- Leiningen profile selection: jack-in shows a multi-select picker of profile names from project.clj's `:profiles` map. Empty selection is valid and starts without profiles. Selected profiles persist to `.helix/nrepl-lein-profiles.edn`.
- shadow-cljs jack-in: detects shadow-cljs.edn and shows a build picker (default: all builds). The server announces its nREPL port via `.shadow-cljs/nrepl.port`; plugin polls for up to 120 seconds. After connect, the session is promoted to the first watched build via `(shadow.cljs.devtools.api/nrepl-select :<build>)`.
- `:nrepl-shadow-select <build>` command switches the shadow-cljs session to a different build.
- Port-file readiness detection: jack-in can now connect to servers that announce their port via a file (not just `.nrepl-port`). Used by shadow-cljs and extensible for other self-porting servers.
- Piggieback ClojureScript support (opt-in via `(nrepl-enable-piggieback)` in init.scm or `.helix/nrepl-jack-in.scm`): adds cider/piggieback middleware to Clojure CLI jack-in. Three new commands: `:nrepl-cljs-node` and `:nrepl-cljs-browser` promote the session to a Node.js or browser ClojureScript REPL, `:nrepl-cljs-quit` returns to Clojure.

### Fixed

- Config file directives are now correctly dispatched and applied without errors.
- Project info guard prevents crashes in copy-jack-in-command when project detection has edge cases.

## 0.3.6 (2026-07-14)

### Added

- Jack-in picker toggle: Ctrl-t switches between the project-file picker and
  the buffer language's server picker, in both directions. Lets you start a
  project-independent server while inside a project. Toggling to the project
  picker with no project files shows "No project files found" in the picker
  body (needs ui-utils.hx 0.1.3).

### Changed

- Jack-in shows the project picker whenever any project files exist, including
  exactly one (it previously launched a single manifest directly).
- Janet and Erlang jack-in now go through the server picker like the other
  languages (single recipe each: `janet-nrepl`, `dialtone`), gaining the
  command preview and the Ctrl-t toggle instead of launching instantly.

## 0.3.5 (2026-07-13)

### Added

- `:nrepl-sessions`: a picker over the server's sessions (for servers that
  support `ls-sessions`). Enter attaches to the selected session (the
  previous one stays alive), Ctrl-k kills it, and a `[new session]` entry
  clones a fresh one. The `repl:N:>` eval numbering is now tracked per
  session, so switching back to a session resumes its own count.

## 0.3.3 (2026-07-12)

### Added

- Elixir and Erlang language adapters targeting the
  [nrepl-beam](https://github.com/nrepl/nrepl-beam) servers (`repartee` and
  `dialtone`).
- Jack-in for both languages: `mix.exs` is detected as a project file and
  starts `mix repartee.server` (template overridable via
  `nrepl-configure-jack-in 'elixir-mix`); Elixir buffers without a manifest
  get a server picker (standalone `repartee` escript or Mix task); Erlang
  buffers start `dialtone` directly (launcher on PATH).

## v0.2.6 (2026-06-16)

### Fixed

- Jack-in project scans no longer block for the full 10s timeout in small
  directory trees. The watchdog's output is now redirected away from `find`'s
  stdout pipe, so the scan returns as soon as `find` finishes instead of
  waiting for the timeout's `sleep` to release the pipe.

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
  advertised op set – `:nrepl-lookup` reports a clear message when the server
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
