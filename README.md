# steel-nrepl

Clojure nREPL client for Helix editor with Steel scripting.

## Status

🚧 **Work in Progress** - Currently in scaffolding phase

## Architecture

This project uses a three-layer architecture for maximum reusability:

```
┌─────────────────────────────────────┐
│  Layer 3: Helix Plugin (cogs/)      │
│  Steel Scheme code                  │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  Layer 2: Steel FFI (steel-nrepl)   │
│  Rust dylib exposing to Steel       │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│  Layer 1: nREPL Client (nrepl-rs)   │
│  Pure Rust, publishable to crates.io│
└─────────────────────────────────────┘
```

### Layer 1: `nrepl-rs`

Pure Rust async nREPL client library. Can be used standalone in any Rust project.

**Features:**
- Async-first with Tokio
- Bencode encoding/decoding
- Session management
- Full nREPL protocol support

**Status:** ✅ **COMPLETE** - Fully functional and validated against real server

### Layer 2: `steel-nrepl`

Rust dylib that exposes nREPL client to Steel scripting via FFI.

**Features:**
- Thread-safe callback system
- Connection registry
- Error propagation to Steel

**Status:** 🟡 Scaffolded, not yet implemented

### Layer 3: Helix Plugin

Steel scripts providing seamless Clojure REPL experience in Helix.

**Planned Commands:**
- `:connect-repl` - Connect to nREPL server
- `:eval-form` - Evaluate form under cursor
- `:eval-selection` - Evaluate selection
- `:eval-buffer` - Evaluate entire buffer
- `:load-file` - Load current file
- `:repl-interrupt` - Interrupt evaluation

**Status:** 🟡 Scaffolded, not yet implemented

## Project Structure

```
steel-nrepl/
├── crates/
│   ├── nrepl-rs/              # Layer 1: Pure Rust
│   └── steel-nrepl/           # Layer 2: FFI wrapper
├── cogs/                       # Layer 3: Helix plugin
│   ├── nrepl.scm
│   └── nrepl/
├── docs/                       # Documentation
└── scripts/                    # Helper scripts
```

## Development

### Prerequisites

- Rust 1.82+ (MSRV to be determined)
- Helix editor with Steel support
- A running Clojure nREPL server for testing

### Building

```bash
# Build everything
cargo build --release

# Build specific layer
cargo build -p nrepl-rs
cargo build -p steel-nrepl
```

### Testing

```bash
# Test pure Rust client
cargo test -p nrepl-rs

# Test FFI layer
cargo test -p steel-nrepl
```

### Local Installation

```bash
# Install dylib
cp target/release/libsteel_nrepl.{so,dylib,dll} ~/.steel/native/

# Link Steel plugin
ln -s $(pwd)/cogs ~/.config/helix/cogs/steel-nrepl
```

## Installation (Future)

### Via Forge (Recommended)

```bash
forge pkg install --git https://github.com/yourname/steel-nrepl.git
```

### Manual

1. Download pre-built dylib for your platform from releases
2. Copy to `~/.steel/native/`
3. Copy `cogs/nrepl.scm` to `~/.config/helix/cogs/`

## Usage (Planned)

### Start nREPL Server

```bash
# Using Clojure CLI
clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' \
    -M -m nrepl.cmdline --port 7888

# Using Leiningen
lein repl :headless :port 7888
```

### In Helix

```
# Connect
:connect-repl localhost 7888

# Evaluate
:eval-form       # Eval form under cursor
:eval-selection  # Eval selection
:eval-buffer     # Eval entire buffer

# Load file
:load-file

# Disconnect
:disconnect-repl
```

## Documentation

See `docs/` directory for:
- Architecture decisions
- nREPL protocol notes
- API documentation
- Development guide

## Roadmap

See [STEEL_NREPL_IMPLEMENTATION_PLAN.md](../steel-experimenting/STEEL_NREPL_IMPLEMENTATION_PLAN.md) for detailed implementation plan.

### Phase 1: Layer 1 Foundation ✅ **COMPLETE**
- [x] Project structure
- [x] Bencode codec (8 tests passing)
- [x] TCP connection
- [x] Clone operation
- [x] Eval operation
- [x] Integration tests (7 tests passing)
- [x] Validated against real nREPL server

### Phase 2: Layer 2 FFI ✅ Scaffolded
- [x] Project structure
- [ ] Steel FFI bindings
- [ ] Callback mechanism
- [ ] Build as dylib

### Phase 3: Layer 3 Plugin ✅ Scaffolded
- [x] Project structure
- [ ] Connection management
- [ ] Basic commands
- [ ] Output display

### Phase 4+: Enhancement
- [ ] Advanced features
- [ ] Documentation
- [ ] CI/CD
- [ ] Public release

## Contributing

Contributions welcome! This project is in early stages.

## Author

Tom Waddington

## License

AGPL-3.0-or-later

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

## References

- [nREPL Protocol](https://nrepl.org/nrepl/index.html)
- [Steel Language](https://github.com/mattwparas/steel)
- [Helix Editor](https://helix-editor.com/)
