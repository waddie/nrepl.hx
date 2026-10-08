#!/bin/sh
# Drive Helix with nrepl.hx against `proof serve`, once per scenario, using the
# quipu scripts in this directory. Run from the repo root:
#
#   sh tests/e2e/run.sh                    # every script, every scenario
#   sh tests/e2e/run.sh split-output       # just these scenarios ("" = plain)
#
# Needs on the PATH: the steel-event-system build of hx, proof
# (go install github.com/nrepl/proof/cmd/proof@latest), quipu
# (https://github.com/waddie/quipu) and timeout. The plugin's Steel
# dependencies (ui-utils.hx, run-command, repl-ui.hx) are taken from
# $DEPS_STEEL_HOME/cogs, ~/.steel by default.
#
# Helix runs with a scratch config, Steel home and nREPL port file, so your own
# setup is never loaded. A script skips the scenarios on its "# skip:" line.

set -u

repo=$(pwd)
port=${PORT:-17950}
deps=${DEPS_STEEL_HOME:-$HOME/.steel}

cargo build -q --release -p steel-nrepl || exit 2
case "$(uname -s)" in
  Darwin*) dylib=libsteel_nrepl.dylib ;;
  *) dylib=libsteel_nrepl.so ;;
esac

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/steel/cogs" "$root/steel/native" "$root/config" \
  "$root/xdg/helix" "$root/work"
ln -s "$repo" "$root/steel/cogs/nrepl.hx"
for dep in ui-utils.hx run-command repl-ui.hx; do
  [ -d "$deps/cogs/$dep" ] || { echo "missing $deps/cogs/$dep"; exit 2; }
  ln -s "$deps/cogs/$dep" "$root/steel/cogs/$dep"
done
cp "target/release/$dylib" "$root/steel/native/"
echo '(require "nrepl.hx/nrepl.scm")' > "$root/config/init.scm"
: > "$root/config/helix.scm"
: > "$root/xdg/helix/config.toml"
# Keep clojure-lsp (or whatever else is installed) out of the tests.
printf '[[language]]\nname = "clojure"\nlanguage-servers = []\n' \
  > "$root/xdg/helix/languages.toml"
echo '(+ 1 2)' > "$root/work/test.clj"
echo "$port" > "$root/work/.nrepl-port"

export STEEL_HOME="$root/steel" HELIX_STEEL_CONFIG="$root/config" \
  XDG_CONFIG_HOME="$root/xdg" E2E_WORK="$root/work" E2E_HX="${HX:-hx}"

if [ $# -eq 0 ]; then
  set -- "" split-output empty-messages last-value no-err error-with-done \
    no-op-echo no-close-op no-interrupt no-stdin read-line-throws \
    string-versions no-session-closed byte-writes batched-writes \
    -like=babashka -like=clojure-clr -like=basilisp -like=jank \
    -like=dialtone -like=repartee
fi

failed=""
for args in "$@"; do
  name=${args:-nREPL}
  # $args is unquoted on purpose: the plain run passes no arguments.
  proof serve -listen 127.0.0.1:$port $args > "$root/proof.log" 2>&1 &
  serve=$!
  until nc -z 127.0.0.1 $port 2>/dev/null; do
    kill -0 $serve 2>/dev/null || { cat "$root/proof.log"; exit 2; }
    sleep 0.2
  done
  for script in tests/e2e/*.qp; do
    test=$(basename "$script" .qp)
    if grep -q "^# skip:.* $args\( \|\$\)" "$script" && [ -n "$args" ]; then
      echo "SKIP $name $test"
      continue
    fi
    if timeout 60 quipu -q "$script" < /dev/null > /dev/null 2> "$root/quipu.log"; then
      echo "PASS $name $test"
    else
      echo "FAIL $name $test"
      sed 's/^/    /' "$root/quipu.log"
      failed="$failed $name/$test"
    fi
  done
  kill -INT $serve
  if ! wait $serve; then
    echo "FAIL $name proof's checks of the requests nrepl.hx sent"
    grep -E '^  (FAIL|WARN)|^         ' "$root/proof.log"
    failed="$failed $name/proof"
  fi
done

if [ -n "$failed" ]; then
  echo "failed:$failed"
  exit 1
fi
