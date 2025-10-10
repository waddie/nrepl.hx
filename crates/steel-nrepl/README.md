# steel-nrepl (Layer 2)

Steel FFI wrapper for nREPL client.

## Important: Connection Lifecycle

**Connections are not automatically closed!** You must manually call `nrepl-close` to avoid resource leaks.

### Correct Usage Pattern

```scheme
;; Good: Always close connections
(define conn (nrepl-connect "localhost:7888"))
(define session (nrepl-clone-session conn))

;; Use the connection
(define result (nrepl-eval conn session "(+ 1 2)"))

;; IMPORTANT: Close when done
(nrepl-close conn)
```

### ❌ Incorrect Usage

```scheme
;; Bad: Connection leaks!
(let ((conn (nrepl-connect "localhost:7888")))
  (nrepl-eval conn session "code")
  ;; conn goes out of scope but TCP connection stays open!
  )
```

## API Functions

### `nrepl-connect`
```scheme
(nrepl-connect address) -> connection-id
```

Connects to an nREPL server. Returns a connection ID.

**Parameters:**
- `address`: String like "localhost:7888"

**Returns:** Connection ID (integer)

**Example:**
```scheme
(define conn (nrepl-connect "localhost:7888"))
```

### `nrepl-clone-session`
```scheme
(nrepl-clone-session conn-id) -> session-id
```

Creates a new session on an existing connection.

**Parameters:**
- `conn-id`: Connection ID from `nrepl-connect`

**Returns:** Session ID (integer)

**Example:**
```scheme
(define session (nrepl-clone-session conn))
```

### `nrepl-eval`
```scheme
(nrepl-eval conn-id session-id code) -> result-hashmap
```

Evaluates Clojure code in a session with default timeout (60 seconds).

**Parameters:**
- `conn-id`: Connection ID
- `session-id`: Session ID
- `code`: String containing Clojure code

**Returns:** Hashmap with keys:
- `value`: Evaluation result (string or #f)
- `output`: List of stdout/stderr strings
- `error`: Error message (string or #f)
- `ns`: Current namespace (string or #f)

**Example:**
```scheme
(define result (nrepl-eval conn session "(+ 1 2)"))
(hash-ref result 'value)  ;; => "3"
```

### `nrepl-eval-with-timeout`
```scheme
(nrepl-eval-with-timeout conn-id session-id code timeout-ms) -> result-hashmap
```

Evaluates Clojure code in a session with custom timeout.

**Parameters:**
- `conn-id`: Connection ID
- `session-id`: Session ID
- `code`: String containing Clojure code
- `timeout-ms`: Timeout in milliseconds (integer)

**Returns:** Same hashmap as `nrepl-eval`

**Errors:** Returns an error if evaluation exceeds the timeout.

**Example:**
```scheme
;; Timeout after 5 seconds
(define result (nrepl-eval-with-timeout conn session "(Thread/sleep 3000)" 5000))

;; This will timeout and return an error
(define result (nrepl-eval-with-timeout conn session "(Thread/sleep 10000)" 1000))
```

### `nrepl-close`
```scheme
(nrepl-close conn-id) -> #t or error
```

Closes a connection and all its sessions. **Always call this!**

**Parameters:**
- `conn-id`: Connection ID to close

**Example:**
```scheme
(nrepl-close conn)
```

## Architecture

This is Layer 2 of the steel-nrepl architecture:

```
Layer 3: Helix Plugin (Steel Scheme)
    ↓
Layer 2: steel-nrepl (This crate - FFI dylib)
    ↓
Layer 1: nrepl-rs (Pure Rust client)
```

## Building

```bash
cargo build -p steel-nrepl
# Output: target/debug/libsteel_nrepl.dylib
```

## Performance Note

A shared tokio runtime is used for all operations. This is efficient and avoids creating/destroying runtimes per call.

## Thread Safety

All functions are thread-safe. The connection registry uses `Arc<Mutex<>>` internally.

## License

AGPL-3.0-or-later
