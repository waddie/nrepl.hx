# steel-nrepl

Steel FFI bindings for nREPL, providing an nREPL client interface for Steel Scheme.

While nREPL is language-agnostic, these bindings have currently only been tested with Clojure.

## Status

This is a work in progress, experimental FFI layer for a work in progress, experimental plugin system. Caveat emptor.

## Important: Connection Lifecycle

**Connections are not automatically closed!** You must manually call `(close conn-id)` to avoid resource leaks.

```scheme
;; Good: Always close connections
(define conn-id (connect "localhost:7888"))
(define session-id (clone-session conn-id))
(define result (eval session-id "(+ 1 2)"))
(close conn-id)  ;; IMPORTANT!

;; Bad: Connection leaks!
(let ((conn-id (connect "localhost:7888")))
  (eval session-id "code")
  ;; conn-id goes out of scope but TCP connection stays open!
)
```

## API

### `(connect address) -> connection-id`

Connects to an nREPL server.

```scheme
(define conn-id (connect "localhost:7888"))
```

### `(clone-session conn-id) -> session-id`

Creates a new session on an existing connection.

```scheme
(define session-id (clone-session conn-id))
```

### `(eval session-id code) -> result-string`

Evaluates code in a session. Returns the result as a string.

```scheme
(define result (eval session-id "(+ 1 2)"))
;; => "3"
```

### `(eval-with-timeout session-id code timeout-ms) -> result-string`

Evaluates code with a custom timeout (in milliseconds).

```scheme
;; Timeout after 5 seconds
(eval-with-timeout session-id "(Thread/sleep 3000)" 5000)
```

### `(close conn-id) -> #t`

Closes a connection and all its sessions. **Always call this!**

```scheme
(close conn-id)
```

## Building

```bash
cargo build --release -p steel-nrepl
# Output: target/release/libsteel_nrepl.dylib (or .so/.dll)
```

Install to Steel's native library directory:

```bash
cp target/release/libsteel_nrepl.dylib ~/.steel/native/
```

## Usage from Steel

```scheme
(#%require-dylib "libsteel_nrepl"
  (only-in connect
           clone-session
           eval
           eval-with-timeout
           close))
```

## License

AGPL-3.0-or-later
