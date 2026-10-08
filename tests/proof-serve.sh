#!/bin/sh
# Run crates/nrepl-rs/tests/proof_serve.rs against `proof serve` once per
# scenario, then let proof check the requests the client sent. Run from the
# repo root with proof on the PATH:
#
#   go install github.com/nrepl/proof/cmd/proof@latest
#   sh tests/proof-serve.sh

set -u

port=${PORT:-17930}
failed=""

cargo test -q -p nrepl-rs --test proof_serve --no-run || exit 2

for args in "" split-output empty-messages last-value no-err error-with-done \
  no-op-echo no-close-op no-interrupt no-stdin read-line-throws \
  string-versions no-session-closed shared-state socket-sessions any-session \
  ns-fallback ns-error eof-error unsorted-keys byte-writes batched-writes \
  hang-up -like=babashka -like=clojure-clr -like=basilisp -like=jank \
  -like=dialtone -like=repartee; do
  name=${args:-nREPL}
  echo "--- proof serve $name"
  if [ "$args" = hang-up ]; then
    filter="--exact hang_up"
  else
    filter="--skip hang_up"
  fi
  # $args and $filter are unquoted on purpose: they may be empty or two words.
  proof serve -listen 127.0.0.1:$port $args &
  serve=$!
  until nc -z 127.0.0.1 $port 2>/dev/null; do
    kill -0 $serve 2>/dev/null || exit 2
    sleep 0.2
  done
  NREPL_TEST_ADDR=127.0.0.1:$port cargo test -q -p nrepl-rs --test proof_serve \
    -- --ignored --test-threads=1 $filter || failed="$failed $name"
  kill -INT $serve
  wait $serve || failed="$failed $name(proof)"
done

if [ -n "$failed" ]; then
  echo "failed:$failed"
  exit 1
fi
