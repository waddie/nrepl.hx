#!/usr/bin/env bash
# Copyright (C) 2025 Tom Waddington
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# Install steel-nrepl locally for development

set -e

echo "Building steel-nrepl..."
cargo build --release

# Detect OS and set dylib extension
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    EXT="so"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    EXT="dylib"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
    EXT="dll"
else
    echo "Unknown OS: $OSTYPE"
    exit 1
fi

# Create directories if they don't exist
mkdir -p ~/.steel/native
mkdir -p ~/.config/helix/cogs

# Copy dylib
echo "Installing dylib to ~/.steel/native/..."
cp target/release/libsteel_nrepl.$EXT ~/.steel/native/

# Link Steel plugin (or copy if ln not available)
echo "Linking Steel plugin to ~/.config/helix/cogs/..."
if [ -e ~/.config/helix/cogs/steel-nrepl ]; then
    rm -rf ~/.config/helix/cogs/steel-nrepl
fi
ln -s "$(pwd)/cogs" ~/.config/helix/cogs/steel-nrepl

echo ""
echo "✅ Installation complete!"
echo ""
echo "Usage in Helix:"
echo "  :connect-repl localhost 7888"
echo "  :eval-selection"
echo ""
echo "Make sure you have a Clojure nREPL server running:"
echo "  clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version \"1.1.0\"}}}' -M -m nrepl.cmdline --port 7888"
