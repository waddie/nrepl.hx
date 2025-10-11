# nrepl.hx

An nREPL client plugin for [Helix](https://github.com/helix-editor/helix/), enabling interactive REPL-driven development directly in your editor.

While nREPL is language-agnostic, this plugin has currently only been tested with Clojure.

Currently you’ll need [mattwparas’s steel-event-system Helix fork](https://github.com/mattwparas/helix/tree/steel-event-system) to use this, and may want to check out his [helix-config](https://github.com/mattwparas/helix-config) repo to see how to set up keybindings, etc.

## Status

This is a work in progress, experimental plugin for a work in progress, experimental plugin system. Exception handling is sparse. Testing is minimal. Edge cases have gone unconsidered. Caveat emptor.

## LLM Disclosure

I’ve written a bit of Scheme over the years, but have next to no Rust experience. Claude Code assisted heavily with the crates in this repo.

## Usage

This plugin provides the following commands:

- `:nrepl-connect [address]` - Connect to nREPL server (prompts for address if not provided, e.g., "localhost:7888")
- `:nrepl-disconnect` - Disconnect from the server
- `:nrepl-eval-prompt` - Prompt for code to evaluate
- `:nrepl-eval-selection` - Evaluate the current selection
- `:nrepl-eval-buffer` - Evaluate the entire buffer
- `:nrepl-eval-multiple-selections` - Evaluate all selections in sequence

All evaluation results are displayed in a dedicated `*nrepl*` buffer with a simple `=>` prompt format. The `*nrepl*` buffer will inherit the language setting from whichever buffer you initiated the connection from, so the responses will be syntax highlighted, etc.

**Example workflow:**
```
:nrepl-connect localhost:7888
# Select some code
:nrepl-eval-selection
# Check the *nrepl* buffer to see results
:nrepl-disconnect
```

![An asciinema recording of interacting with a Clojure nREPL in Helix](https://github.com/waddie/nrepl.hx/blob/main/images/nrepl.gif?raw=true)

## Installation

**1. Build Helix with Steel plugin system:**

```sh
git clone https://github.com/mattwparas/helix.git -b steel-event-system
cd helix
cargo xtask steel
```

**2. Build the nrepl.hx plugin:**

```sh
git clone https://github.com/waddie/nrepl.hx.git
cd nrepl.hx
cargo build --release
```

**3. Install the dylib:**

```sh
# macOS/Linux
cp target/release/libsteel_nrepl.dylib ~/.steel/native/
# or .so on Linux, .dll on Windows
```

**4. Enable the plugin:**

Add to `~/.config/helix/init.scm`:

```scheme
(require "nrepl.scm")
```

Then copy `nrepl.scm` to your Helix config directory:

```sh
cp nrepl.scm ~/.config/helix/
```

Keybindings need to be added to `init.scm` too, `config.toml` doesn’t know about Steel functions.

For example, to evaluate the current selection in the nREPL on `Alt-<enter>`:

```scheme
(require "cogs/keymaps.scm")

[…]

(keymap (global)
        (normal (A-ret ":nrepl-eval-selection"))
        (select (A-ret ":nrepl-eval-selection")))
```

See [helix-config](https://github.com/mattwparas/helix-config) for more.

Finally, restart Helix.

## License

AGPL-3.0-or-later

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
