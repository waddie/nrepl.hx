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
mkdir -p ~/.config/helix

# Copy dylib
echo "Installing dylib to ~/.steel/native/..."
cp target/release/libsteel_nrepl.$EXT ~/.steel/native/

# Copy Helix plugin
echo "Installing nrepl.scm to ~/.config/helix/..."
cp nrepl.scm ~/.config/helix/

echo ""
echo "✅ Installation complete!"
echo ""
echo "Add to your ~/.config/helix/init.scm:"
echo "  (require \"nrepl.scm\")"
echo ""
echo "Available commands in Helix:"
echo "  :nrepl-connect          - Connect to nREPL server (default: localhost:7888)"
echo "  :nrepl-disconnect       - Close connection"
echo "  :nrepl-eval-prompt      - Prompt for code and evaluate"
echo "  :nrepl-show-buffer      - Show *nrepl* REPL buffer in split"
echo ""
echo "Make sure you have a Clojure nREPL server running:"
echo "  clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version \"1.1.0\"}}}' -M -m nrepl.cmdline --port 7888"
echo ""
echo "Output will appear in the *nrepl* buffer with standard REPL formatting:"
echo "  user=> (+ 1 2)"
echo "  3"
