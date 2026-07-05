#!/usr/bin/env bash
# nrepl.hx installation script.
#
# Installs the native Steel dylib to ~/.steel/native/ and copies the Scheme
# plugin into ~/.steel/cogs/nrepl.hx/ - the same locations Steel's forge package
# manager uses - so `(require "nrepl.hx/nrepl.scm")` resolves the same way
# whether installed via forge or this script.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

# Detect OS and dylib extension
case "$(uname -s)" in
    Darwin*)
        DYLIB_EXT="dylib"
        OS="macOS"
        ;;
    Linux*)
        DYLIB_EXT="so"
        OS="Linux"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        DYLIB_EXT="dll"
        OS="Windows"
        ;;
    *)
        error "Unsupported operating system: $(uname -s)"
        ;;
esac

info "Detected OS: $OS"

# Check if dylib exists
DYLIB_PATH="target/release/libsteel_nrepl.$DYLIB_EXT"
if [ ! -f "$DYLIB_PATH" ]; then
    error "Dylib not found at $DYLIB_PATH. Run 'cargo build --release' first."
fi

# Check if nrepl.scm exists
if [ ! -f "nrepl.scm" ]; then
    error "nrepl.scm not found in current directory. Run this script from the nrepl.hx repository root."
fi

# Create directories if they don't exist
STEEL_DIR="$HOME/.steel/native"
DEST="$HOME/.steel/cogs/nrepl.hx"
HELIX_DIR="$HOME/.config/helix"

info "Creating directories..."
mkdir -p "$STEEL_DIR"
mkdir -p "$DEST/cogs"

# nrepl.hx requires the shared ui-utils.hx library; its modules must be in
# ~/.steel/cogs/ui-utils.hx/ or the pickers fail to load. Install from a sibling
# checkout (override with UI_UTILS_DIR), else a shallow clone.
if [ ! -d "$HOME/.steel/cogs/ui-utils.hx" ]; then
    UI_UTILS_DIR="${UI_UTILS_DIR:-../ui-utils.hx}"
    if [ -d "$UI_UTILS_DIR" ]; then
        info "Installing ui-utils.hx from $UI_UTILS_DIR..."
        (cd "$UI_UTILS_DIR" && ./install.sh) >/dev/null
    else
        TMP_DIR=$(mktemp -d)
        info "Cloning ui-utils.hx..."
        git clone --depth 1 https://github.com/waddie/ui-utils.hx "$TMP_DIR/ui-utils.hx" >/dev/null 2>&1 \
            || error "ui-utils.hx is not installed and could not be cloned. Set UI_UTILS_DIR to a checkout and re-run."
        (cd "$TMP_DIR/ui-utils.hx" && ./install.sh) >/dev/null
        rm -rf "$TMP_DIR"
    fi
    success "Installed ui-utils.hx"
else
    success "ui-utils.hx already installed"
fi

# Copy dylib
info "Installing dylib to $STEEL_DIR..."
cp "$DYLIB_PATH" "$STEEL_DIR/"
success "Dylib installed"

# Copy Scheme file
info "Installing nrepl.scm to $DEST..."
cp "nrepl.scm" "$DEST/"
success "nrepl.scm installed"

# Copy cogs directory
info "Installing language adapters to $DEST/cogs/nrepl/..."
cp -r cogs/nrepl "$DEST/cogs/"
success "Language adapters installed"

# Check init.scm and provide instructions
INIT_SCM="$HELIX_DIR/init.scm"
if [ -f "$INIT_SCM" ]; then
    if grep -q '(require "nrepl.hx/nrepl.scm")' "$INIT_SCM"; then
        success "init.scm already requires nrepl.hx"
    else
        echo ""
        info "Add this line to $INIT_SCM:"
        echo ""
        echo "    (require \"nrepl.hx/nrepl.scm\")"
        echo ""
    fi
else
    echo ""
    info "Create $INIT_SCM with:"
    echo ""
    echo "    (require \"nrepl.hx/nrepl.scm\")"
    echo ""
fi

# Suggest keybindings
echo ""
info "Suggested keybindings for init.scm:"
echo ""
echo "    (keymap (global)"
echo "            (normal (space (n (C \":nrepl-connect\")"
echo "                              (D \":nrepl-disconnect\")"
echo "                              (b \":nrepl-eval-buffer\")"
echo "                              (m \":nrepl-eval-multiple-selections\")"
echo "                              (p \":nrepl-eval-prompt\")"
echo "                              (s \":nrepl-eval-selection\")))"
echo "                    (A-ret \":nrepl-eval-selection\"))"
echo "            (select (space (n (C \":nrepl-connect\")"
echo "                              (D \":nrepl-disconnect\")"
echo "                              (b \":nrepl-eval-buffer\")"
echo "                              (m \":nrepl-eval-multiple-selections\")"
echo "                              (p \":nrepl-eval-prompt\")"
echo "                              (s \":nrepl-eval-selection\")))"
echo "                    (A-ret \":nrepl-eval-selection\")))"
echo ""

echo ""
success "Installation complete!"
echo ""
info "Next steps:"
echo "  1. Restart Helix"
echo "  2. Start an nREPL server: clj -M -m nrepl.cmdline --port 7888"
echo "  3. In Helix, run: :nrepl-connect"
echo ""
