# nrepl.hx

An nREPL client plugin for [Helix](https://github.com/helix-editor/helix/),
enabling interactive REPL-driven development directly in your editor.

The plugin uses a modular **language adapter system** that allows customization
of error formatting, prompt styling, and result presentation for different nREPL
implementations. Dedicated adapters for:

- Clojure/Babashka (via [nrepl](https://github.com/nrepl/nrepl))
- Guile (via [guile-ares-rs](https://github.com/abcdw/guile-ares-rs))
- Steel Scheme (via [nrepl-steel](https://github.com/waddie/nrepl-steel))
- Janet (via [nrepl-janet](https://github.com/waddie/nrepl-janet))
- Elixir/Erlang (via [nrepl-beam](https://github.com/nrepl/nrepl-beam))
- Python (via [nrepl-python](https://git.sr.ht/~ngraves/nrepl-python))

With a generic fallback adapter for any other language.

Currently you’ll need [Matthew Paras’s steel-event-system Helix
fork](https://github.com/mattwparas/helix/tree/steel-event-system)
to use this.

Note that Windows support is limited. Jacking-in relies on POSIX port and
process management. I think you should be able to connect to an nREPL server
with native Windows, you’ll just have to start it yourself.

## Demo

![An asciinema recording of interacting with a Clojure nREPL in
Helix](https://github.com/waddie/nrepl.hx/blob/main/images/nrepl.gif?raw=true)

## Usage

This plugin provides the following commands:

- `:nrepl-connect [host:port]` - Connect to nREPL server. Without an address,
  checks for a `.nrepl-port` file in the workspace root, then prompts
  (defaults to `localhost:7888`)
- `:nrepl-jack-in` - Start nREPL server for current project and connect
  automatically (Clojure, Babashka, Leiningen, shadow-cljs, Elixir, Erlang, Janet, Python)
- `:nrepl-jack-out` - Kill the jack-in server and disconnect (errors if the
  server was not started by jack-in)
- `:nrepl-disconnect` - Disconnect from the server. Prompts to kill server if started via jack-in
- `:nrepl-copy-jack-in-command` - Copy the resolved jack-in command for the
  current project to the clipboard
- `:nrepl-load-file` - Load and evaluate a file (default: current buffer)
- `:nrepl-set-timeout [seconds]` - Set or view evaluation timeout (default: 60 seconds)
- `:nrepl-set-orientation [vsplit|hsplit]` - Set or view REPL buffer split
  orientation (default: vsplit)
- `:nrepl-toggle-debug` - Toggle debug logging on/off
- `:nrepl-toggle-auto-load` - Toggle automatic re-loading of a source buffer into the REPL on save
- `:nrepl-stats` - Display connection and session statistics for debugging
- `:nrepl-eval-prompt` - Prompt for code to evaluate
- `:nrepl-eval-selection` - Evaluate the current selection
- `:nrepl-eval-multiple-selections` - Evaluate all selections in sequence
- `:nrepl-eval-buffer` - Evaluate the entire buffer
- `:nrepl-interrupt` - Interrupt the currently running evaluation
- `:nrepl-stdin [text]` - Send a line of stdin to the running evaluation (prompts if no text given)
- `:nrepl-lookup` - Open interactive symbol lookup picker with documentation preview
- `:nrepl-sessions` - Pick a server session to attach to. Enter attaches (the
  previous session stays alive), Ctrl-k kills the selected session, and the
  `[new session]` entry clones a fresh one. Each session keeps its own
  `repl:N:>` numbering. Requires server support for `ls-sessions`
- `:nrepl-shadow-select <build>` - Switch the current shadow-cljs session to a
  different build (shadow-cljs jack-in only)
- `:nrepl-cljs-node` - Promote the current Clojure session to a Node.js
  ClojureScript REPL via Piggieback. (Requires `(nrepl-enable-piggieback)`)
- `:nrepl-cljs-browser` - Promote the current Clojure session to a browser
  ClojureScript REPL via Piggieback. (Requires `(nrepl-enable-piggieback)`)
- `:nrepl-cljs-quit` - Return to the Clojure REPL from a Piggieback ClojureScript
  session

All evaluation results are displayed in a dedicated `*nrepl*` buffer. The `*nrepl*`
buffer will inherit the language setting from whichever buffer you initiated the
connection from, so the responses will be syntax highlighted, etc.

### Symbol Lookup Picker

The lookup picker provides an interactive interface for browsing and searching
available symbols with live documentation preview.

**Keymap:**

| Key                       | Action                                                   |
| ------------------------- | -------------------------------------------------------- |
| Type characters           | Fuzzy-filter symbols                                     |
| `Backspace`               | Remove filter character                                  |
| `Up` / `Down`             | Navigate selection (wraps around)                        |
| `Ctrl-p` / `Ctrl-n`       | Navigate selection (vim-style)                           |
| `Tab` / `Shift-Tab`       | Navigate selection                                       |
| `Ctrl-u` / `Ctrl-d`       | Page up/down in symbol list                              |
| `Home` / `End`            | Jump to first/last symbol                                |
| `PageUp` / `PageDown`     | Scroll documentation preview                             |
| `Shift-Up` / `Shift-Down` | Scroll documentation preview                             |
| `Enter`                   | Insert unqualified symbol (e.g., `map`)                  |
| `Alt-Enter`               | Insert fully-qualified symbol (e.g., `clojure.core/map`) |
| `Escape` / `Ctrl-c`       | Close picker                                             |

### Configuring Timeouts

By default, evaluations time-out after 60 seconds. You can adjust this:

**At runtime:**

```
:nrepl-set-timeout 120   # Set to 2 minutes
:nrepl-set-timeout       # View current timeout
```

**Set default in init.scm:**

```scheme
(require "nrepl.scm")
(nrepl-set-timeout 120)  # 2 minute default for all sessions
```

### Configuring Buffer Orientation

By default, the `*nrepl*` buffer opens in a vertical split (vsplit). You can change this:

**At runtime:**

```
:nrepl-set-orientation hsplit    # Switch to horizontal split
:nrepl-set-orientation vsplit    # Switch to vertical split
:nrepl-set-orientation           # View current orientation
```

Shortcuts: `v`, `vertical`, `h`, `horizontal` also work.

**Set default in init.scm:**

```scheme
(require "nrepl.scm")
(nrepl-set-orientation 'hsplit)  # Horizontal split default
```

**Note on buffer visibility:**
If you close the split window (i.e. with `:q`) but the `*nrepl*` buffer still
exists, the next evaluation will create a new `*nrepl*` buffer in a split with
your configured orientation rather than reopening the existing one. This ensures
the orientation setting is always respected. The old buffer with its history
remains accessible via the buffer picker (`Space + b`).

### Jack-in Configuration

Jack-in can be customized via `init.scm` or a per-project configuration file.

**Global customization in init.scm:**

Configure jack-in dependency versions (defaults: nrepl 1.7.0, cider-nrepl 0.62.1, piggieback 0.7.0):

```scheme
(require "nrepl.scm")
(nrepl-set-jack-in-version 'nrepl "1.8.0")
(nrepl-set-jack-in-version 'cider-nrepl "0.63.0")
(nrepl-set-jack-in-version 'piggieback "0.7.1")
```

Opt in to ClojureScript support via Piggieback (Clojure CLI only):

```scheme
(nrepl-enable-piggieback)  # Adds Piggieback middleware to jack-in
```

With Piggieback enabled, use `:nrepl-cljs-node` or `:nrepl-cljs-browser` to
promote the session to a ClojureScript REPL, and `:nrepl-cljs-quit` to return
to Clojure. Single session promotion only (no multi-REPL toggling).

Add extra nREPL middleware:

```scheme
(nrepl-add-jack-in-middleware "my.middleware/wrap")
(nrepl-add-jack-in-middleware "another.middleware/wrap")
```

Set environment variables for jack-in commands:

```scheme
(nrepl-set-jack-in-env
  '(("CLOJURE_TOOLS_EXTRA_ARGS" . "-XX:+UnlockDiagnosticVMOptions")
    ("CUSTOM_VAR" . "value")))
```

Set code to evaluate after jack-in connects (runs in the REPL session):

```scheme
(nrepl-set-after-jack-in-code "(require 'dev)")
;; or a list of expressions
(nrepl-set-after-jack-in-code
  '("(require 'dev)" "(in-ns 'user)"))
```

**Per-project configuration:**

Create `.helix/nrepl-jack-in.scm` in your workspace root to configure jack-in for that project. Only the following directive forms are supported (unknown forms are ignored):

- `(nrepl-configure-jack-in 'command-type template-fn)`
- `(nrepl-set-jack-in-version key version)`
- `(nrepl-add-jack-in-middleware middleware)`
- `(nrepl-set-jack-in-env env-pairs)`
- `(nrepl-set-after-jack-in-code code)`
- `(nrepl-enable-piggieback)` - Opt in to Piggieback ClojureScript support

The file is interpreted, not evaluated as a module, so custom procedures cannot be defined. Example:

```scheme
(nrepl-set-jack-in-env '(("CLOJURE_TOOLS_EXTRA_ARGS" . "-Xmx4g")))
(nrepl-set-after-jack-in-code "(require 'dev-setup)")
(nrepl-enable-piggieback)
```

**Jack-in behaviour:**

- **Leiningen:** The `lein` jack-in command injects nrepl and cider-nrepl as dependencies and plugin, making cider operations (lookup, completion) available. A multi-select picker shows available profiles from project.clj's `:profiles` map. Empty selection is valid and starts without profile flags. Selected profiles persist to `.helix/nrepl-lein-profiles.edn` for the next jack-in.
- **shadow-cljs:** Jack-in detects shadow-cljs.edn and shows a build picker (default: all builds). Empty selection starts a plain server without watching builds. The server announces its nREPL port via `.shadow-cljs/nrepl.port`; plugin polls for up to 120 seconds (first compile can be slow). After connect, the session is promoted to the first watched build. Selected builds persist to `.helix/nrepl-shadow-builds.edn`. Use `:nrepl-shadow-select <build>` to switch builds.
- **Clojure CLI / Babashka / nbb:** Custom middleware list is applied to the server startup. Piggieback is available via `(nrepl-enable-piggieback)` in init.scm or per-project config.
- **Python:** The basilisp jack-in detects pyproject.toml, setup.py, Pipfile, or requirements.txt and starts `basilisp nrepl-server --port <port>`.

**ClojureScript support limitations:**

Single session promotion only: `:nrepl-cljs-node`, `:nrepl-cljs-browser`, and
`:nrepl-shadow-select` promote or switch the single attached session. No multi-REPL
session toggling, no `.cljc` session cloning, no Figwheel support.

## Installation

### Install with Forge (recommended)

```sh
forge pkg install --git https://github.com/waddie/nrepl.hx
```

This copies the cog to `~/.steel/cogs/nrepl.hx/` and downloads the matching
`libsteel_nrepl` dylib to `~/.steel/native/`. Prebuilt binaries are published for
`aarch64-macos`, `x86_64-macos`, `x86_64-linux` and `x86_64-windows`; on any other
platform, use the from-source install below.

Then add to `~/.config/helix/init.scm`:

```scheme
(require "nrepl.hx/nrepl.scm")
```

Reload with `:config-reload`, or restart Helix. See the key-bindings step below
(it applies to every install method).

### Quick Install (Automated, from source)

**1. Build Helix with Steel plugin system:**

```sh
git clone https://github.com/mattwparas/helix.git -b steel-event-system
cd helix
cargo xtask steel
```

**2. Build and install nrepl.hx:**

```sh
git clone https://github.com/waddie/nrepl.hx.git
cd nrepl.hx
cargo build --release
./install.sh
```

The install script will:

- Copy the dylib/so/dll to `~/.steel/native/`
- Copy `nrepl.scm` to `~/.config/helix/`
- Copy language adapters to `~/.config/helix/cogs/nrepl/`
- Provide instructions for updating `init.scm`

**3. Enable the plugin:**

Add to `~/.config/helix/init.scm`:

```scheme
(require "nrepl.hx/nrepl.scm")
```

**4. Add key-bindings (optional but recommended):**

Add to `~/.config/helix/init.scm`, see `./keybindings-example.scm` for an example layout.

## License

AGPL-3.0-or-later

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
