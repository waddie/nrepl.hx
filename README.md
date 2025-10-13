# nrepl.hx

An nREPL client plugin for [Helix](https://github.com/helix-editor/helix/), enabling interactive REPL-driven development directly in your editor.

The plugin uses a modular **language adapter system** that allows customization of error formatting, prompt styling, and result presentation for different nREPL implementations. Currently supports Clojure/Babashka with a fallback for other languages.

Currently you’ll need [mattwparas’s steel-event-system Helix fork](https://github.com/mattwparas/helix/tree/steel-event-system) to use this, and may want to check out his [helix-config](https://github.com/mattwparas/helix-config) repo to see how to set up keybindings, etc.

## Demo

![An asciinema recording of interacting with a Clojure nREPL in Helix](https://github.com/waddie/nrepl.hx/blob/main/images/nrepl.gif?raw=true)

## Status

This is a work in progress, experimental plugin for a work in progress, experimental plugin system. Exception handling is sparse. Testing is minimal. Edge cases have gone unconsidered. Caveat emptor.

## Usage

This plugin provides the following commands:

- `:nrepl-connect [host:port]` - Connect to nREPL server. Prompts for host if not provided, finally defaults to `localhost:7888`
- `:nrepl-disconnect` - Disconnect from the server
- `:nrepl-eval-prompt` - Prompt for code to evaluate
- `:nrepl-eval-selection` - Evaluate the current selection
- `:nrepl-eval-multiple-selections` - Evaluate all selections in sequence
- `:nrepl-eval-buffer` - Evaluate the entire buffer

All evaluation results are displayed in a dedicated `*nrepl*` buffer with a `ns=>` prompt. The `*nrepl*` buffer will inherit the language setting from whichever buffer you initiated the connection from, so the responses will be syntax highlighted, etc.

## Installation

### Prerequisites

You’ll need:
- [mattwparas’s steel-event-system Helix fork](https://github.com/mattwparas/helix/tree/steel-event-system)
- Rust toolchain (for building)
- An nREPL server (e.g., Clojure, Babashka, ClojureScript, nbb)

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
- Copy the dylib to `~/.steel/native/`
- Copy `nrepl.scm` to `~/.config/helix/`
- Copy language adapters to `~/.config/helix/cogs/nrepl/`
- Provide instructions for updating `init.scm`

**3. Enable the plugin:**

Add to `~/.config/helix/init.scm`:

```scheme
(require "nrepl.scm")
```

**4. Add keybindings (optional but recommended):**

Add to `~/.config/helix/init.scm`:

```scheme
(require "cogs/keymaps.scm")

(keymap (global)
        (normal (space (n (C ":nrepl-connect")
                          (D ":nrepl-disconnect")
                          (b ":nrepl-eval-buffer")
                          (m ":nrepl-eval-multiple-selections")
                          (p ":nrepl-eval-prompt")
                          (s ":nrepl-eval-selection")))
                (A-ret ":nrepl-eval-selection"))
        (select (space (n (C ":nrepl-connect")
                          (D ":nrepl-disconnect")
                          (b ":nrepl-eval-buffer")
                          (m ":nrepl-eval-multiple-selections")
                          (p ":nrepl-eval-prompt")
                          (s ":nrepl-eval-selection")))
                (A-ret ":nrepl-eval-selection")))
```

This gives you (in both normal and select modes):
- `Space + n + C` - Connect to nREPL
- `Space + n + D` - Disconnect
- `Space + n + b` - Evaluate buffer
- `Space + n + m` - Evaluate multiple selections
- `Space + n + p` - Evaluate from prompt
- `Space + n + s` - Evaluate selection
- `Alt + Enter` - Quick evaluate selection

See [helix-config](https://github.com/mattwparas/helix-config) for more keybinding examples.

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

1. **Start an nREPL server:**
   ```sh
   # Clojure
   clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.4.0"}}}' -M -m nrepl.cmdline --port 7888

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
