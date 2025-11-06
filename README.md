# nrepl.hx

An nREPL client plugin for [Helix](https://github.com/helix-editor/helix/), enabling interactive REPL-driven development directly in your editor.

The plugin uses a modular **language adapter system** that allows customization of error formatting, prompt styling, and result presentation for different nREPL implementations. Dedicated adapters for Clojure/Babashka and Python, with a generic fallback for other languages.

Tested at least briefly with Clojure [nrepl](https://github.com/nrepl/nrepl), [Babashka](https://github.com/babashka/babashka), and Python [nrepl-python](https://git.sr.ht/~ngraves/nrepl-python).

Currently you’ll need [Matthew Paras’s steel-event-system Helix fork](https://github.com/mattwparas/helix/tree/steel-event-system) to use this, and may want to check out his [helix-config](https://github.com/mattwparas/helix-config) repo to see how to set up keybindings, etc.

## Demo

![An asciinema recording of interacting with a Clojure nREPL in Helix](https://github.com/waddie/nrepl.hx/blob/main/images/nrepl.gif?raw=true)

## Status

This is a work in progress, experimental plugin for a work in progress, experimental plugin system. Exception handling is sparse. Testing is minimal. Edge cases have gone unconsidered. Caveat emptor.

## Usage

This plugin provides the following commands:

- `:nrepl-connect [host:port]` - Connect to nREPL server. Prompts for host if not provided, finally defaults to `localhost:7888`
- `:nrepl-jack-in` - Start nREPL server for current project and connect automatically (Clojure, Babashka, Leiningen)
- `:nrepl-disconnect` - Disconnect from the server. Prompts to kill server if started via jack-in
- `:nrepl-load-file` - Load and evaluate a file (default: current buffer)
- `:nrepl-set-timeout [seconds]` - Set or view evaluation timeout (default: 60 seconds)
- `:nrepl-set-orientation [vsplit|hsplit]` - Set or view REPL buffer split orientation (default: vsplit)
- `:nrepl-stats` - Display connection and session statistics for debugging
- `:nrepl-eval-prompt` - Prompt for code to evaluate
- `:nrepl-eval-selection` - Evaluate the current selection
- `:nrepl-eval-multiple-selections` - Evaluate all selections in sequence
- `:nrepl-eval-buffer` - Evaluate the entire buffer
- `:nrepl-lookup-picker` - Open interactive symbol lookup picker with documentation preview

All evaluation results are displayed in a dedicated `*nrepl*` buffer with a `ns=>` prompt. The `*nrepl*` buffer will inherit the language setting from whichever buffer you initiated the connection from, so the responses will be syntax highlighted, etc.

### Symbol Lookup Picker

The lookup picker provides an interactive interface for browsing and searching available symbols with live documentation preview.

**Features:**
- Real-time filtering as you type
- Displays symbol name, namespace, and type in columns
- Live documentation preview pane
- Insert symbols with or without namespace qualification

**Keymap:**

| Key | Action |
|-----|--------|
| Type characters | Filter symbols (case-insensitive) |
| `Backspace` | Remove filter character |
| `Up` / `Down` | Navigate selection (wraps around) |
| `Ctrl-p` / `Ctrl-n` | Navigate selection (vim-style) |
| `Tab` / `Shift-Tab` | Navigate selection |
| `Ctrl-u` / `Ctrl-d` | Page up/down in symbol list |
| `Home` / `End` | Jump to first/last symbol |
| `PageUp` / `PageDown` | Scroll documentation preview |
| `Shift-Up` / `Shift-Down` | Scroll documentation preview |
| `Enter` | Insert unqualified symbol (e.g., `map`) |
| `Alt-Enter` | Insert fully-qualified symbol (e.g., `clojure.core/map`) |
| `Escape` / `Ctrl-c` | Close picker |

**Requirements:**
- Requires `cider-nrepl` middleware for Clojure/ClojureScript
- Standard `nREPL 1.5.0` does not include completion/lookup operations
- Example server setup:

```sh
clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.5.0"} cider/cider-nrepl {:mvn/version "0.58.0"}}}'\
 -M -m nrepl.cmdline\
 --middleware "[cider.nrepl/cider-middleware]"\
 --port 7888
```

### Jack-In: Automatic Server Startup

The jack-in feature automatically starts an nREPL server for your project and connects to it.

**Workflow:**

```
# Open a file in your project
:nrepl-jack-in

# Plugin will:
# 1. Detect project type (deps.edn, bb.edn, or project.clj)
# 2. Find a free port (7888-7988 range)
# 3. Start appropriate nREPL server
# 4. Write .nrepl-port file
# 5. Connect automatically

# When done:
:nrepl-disconnect
# Prompts: "Kill nREPL server? [y/n]:"
# Choose 'y' to kill server, 'n' to leave it running
```

**Supported Project Types:**

- **Clojure CLI (deps.edn)**: Uses `clojure` with `-Sdeps` for nREPL + cider-nrepl
- **Babashka (bb.edn)**: Uses `bb nrepl-server`
- **Leiningen (project.clj)**: Uses `lein trampoline repl :headless`

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
If you close the split window (i.e. with `:q`) but the `*nrepl*` buffer still exists, the next evaluation will create a new `*nrepl*` buffer in a split with your configured orientation rather than reopening the existing one. This ensures the orientation setting is always respected. The old buffer with its history remains accessible via the buffer picker (`Space + b`).

## Installation

### Prerequisites

You’ll need:
- [Matthew Paras’s steel-event-system Helix fork](https://github.com/mattwparas/helix/tree/steel-event-system)
- Rust toolchain (for building)
- An nREPL server (e.g., Clojure, Babashka, ClojureScript)

### Quick Install (Automated)

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
(require "nrepl.scm")
```

**4. Add key-bindings (optional but recommended):**

Add to `~/.config/helix/init.scm`:

```scheme
(require "cogs/keymaps.scm")

(keymap (global)
        (normal (space (n (C ":nrepl-connect")
                          (D ":nrepl-disconnect")
                          (J ":nrepl-jack-in")
                          (L ":nrepl-load-file")
                          (b ":nrepl-eval-buffer")
                          (l ":nrepl-lookup-picker")
                          (m ":nrepl-eval-multiple-selections")
                          (p ":nrepl-eval-prompt")
                          (s ":nrepl-eval-selection")))
                (A-ret ":nrepl-eval-selection"))
        (select (space (n (C ":nrepl-connect")
                          (D ":nrepl-disconnect")
                          (J ":nrepl-jack-in")
                          (L ":nrepl-load-file")
                          (b ":nrepl-eval-buffer")
                          (l ":nrepl-lookup-picker")
                          (m ":nrepl-eval-multiple-selections")
                          (p ":nrepl-eval-prompt")
                          (s ":nrepl-eval-selection")))
                (A-ret ":nrepl-eval-selection")))
```

This gives you (in both normal and select modes):
- `Space + n + C` - Connect to nREPL
- `Space + n + J` - Jack-in (start server and connect)
- `Space + n + D` - Disconnect
- `Space + n + L` - Load and evaluate a file
- `Space + n + b` - Evaluate buffer
- `Space + n + l` - Open symbol lookup picker
- `Space + n + m` - Evaluate multiple selections
- `Space + n + p` - Evaluate from prompt
- `Space + n + s` - Evaluate selection
- `Alt + Enter` - Quick evaluate selection

See [helix-config](https://github.com/mattwparas/helix-config) for more key-binding examples.

**5. Restart Helix**

### Manual Installation

If you prefer manual installation or the script doesn’t work for your system:

```sh
# Build the plugin
cargo build --release

# Copy files (adjust paths for your OS)
mkdir -p ~/.steel/native ~/.config/helix ~/.config/helix/cogs/nrepl
cp target/release/libsteel_nrepl.dylib ~/.steel/native/  # or .so on Linux, .dll on Windows
cp nrepl.scm ~/.config/helix/
cp -r cogs/nrepl/* ~/.config/helix/cogs/nrepl/

# Add to ~/.config/helix/init.scm
echo '(require "nrepl.scm")' >> ~/.config/helix/init.scm
```

### Getting Started

After installation:

**Option 1: Jack-In (Recommended for Clojure/Babashka/Leiningen projects)**

```
# Open a file in your project
:nrepl-jack-in

# Plugin automatically starts server and connects
# Select some code and evaluate
:nrepl-eval-selection

# Check the *nrepl* buffer for results

# When done:
:nrepl-disconnect
# Choose 'y' to kill the server, or 'n' to leave it running
```

**Option 2: Manual Server (For other languages or custom setups)**

1. **Start an nREPL server manually:**
   ```sh
   # Clojure
   clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.5.0"} cider/cider-nrepl {:mvn/version "0.58.0"}}}'\
    -M -m nrepl.cmdline\
    --middleware "[cider.nrepl/cider-middleware]"\
    --port 7888

   # Or Babashka
   bb nrepl-server 7888
   ```

2. **In Helix:**
   ```
   :nrepl-connect
   # Enter: localhost:7888 (or press Enter for default)

   # Select some code and evaluate
   :nrepl-eval-selection

   # Check the *nrepl* buffer for results
   ```

3. **When done:**
   ```
   :nrepl-disconnect
   ```

## LLM Disclosure

I’ve written a bit of Scheme over the years, but have next to no Rust experience. Claude Code assisted heavily with the crates in this repo.

## License

AGPL-3.0-or-later

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
