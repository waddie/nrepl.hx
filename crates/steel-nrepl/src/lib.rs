// Copyright (C) 2025 Tom Waddington
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

//! Steel FFI wrapper for nREPL client
//!
//! This crate provides a Foreign Function Interface (FFI) that exposes the [`nrepl-rs`]
//! async nREPL client to Steel Scheme scripts. It builds as a dynamic library
//! (`libsteel_nrepl.dylib/so/dll`) that can be loaded by Steel's FFI system.
//!
//! # Architecture
//!
//! The crate uses a three-layer architecture to bridge async Rust with synchronous Steel code:
//!
//! ## 1. Registry Layer ([`registry`] module)
//!
//! - **Global state**: Thread-safe `Arc<Mutex<Registry>>` manages all connections and sessions
//! - **ID assignment**: Allocates integer IDs for connections and sessions
//! - **Lookup**: Maps IDs to underlying `Worker` and `Session` objects
//! - **Cleanup**: Removes connections when closed by client
//!
//! ## 2. Worker Layer ([`worker`] module)
//!
//! - **Background thread**: Each connection gets a dedicated worker thread with its own Tokio runtime
//! - **Async isolation**: Prevents blocking the main Steel thread during long evaluations
//! - **Non-blocking submission**: `submit_eval()` returns immediately with a request ID
//! - **Polling pattern**: Steel code polls for results with `try_recv_response()`
//! - **Response buffering**: Supports multiple concurrent evaluations without losing responses
//!
//! ## 3. FFI Layer ([`connection`] module)
//!
//! - **Steel-compatible functions**: Export Rust functions that Steel can call
//! - **S-expression formatting**: Converts results to Steel data structures
//! - **Error conversion**: Maps `NReplError` to Steel-friendly error strings
//!
//! # Usage Pattern
//!
//! ## From Steel
//!
//! ```scheme
//! ; Load the FFI module
//! (require-builtin steel-nrepl as ffi)
//!
//! ; Connect to nREPL server
//! (define conn-id (ffi.connect "127.0.0.1:7888"))
//!
//! ; Clone a session
//! (define session (ffi.clone-session conn-id))
//!
//! ; Submit evaluation (non-blocking)
//! (define request-id (ffi.eval session "(+ 1 2)"))
//!
//! ; Poll for result (returns false if not ready)
//! (define result (ffi.try-get-result conn-id request-id))
//!
//! ; Result is an S-expression string that evaluates to a hashmap:
//! ; (hash 'value "3" 'output (list) 'error #f 'ns "user")
//!
//! ; IMPORTANT: Always close connections to prevent resource leaks
//! (ffi.close conn-id)
//! ```
//!
//! ## Connection Lifecycle
//!
//! 1. **Connect**: `connect(address)` → `conn_id` (creates worker thread, establishes TCP connection)
//! 2. **Clone session**: `clone-session(conn_id)` → `session` (session object for evaluations)
//! 3. **Evaluate**: `eval(session, code)` → `request_id` (submits to worker, returns immediately)
//! 4. **Poll results**: `try-get-result(conn_id, request_id)` → result or `#f` (non-blocking check)
//! 5. **Close**: `close(conn_id)` → closes sessions and shuts down worker (REQUIRED)
//!
//! **⚠️ Resource Management**: Connections are NOT automatically closed. Always call `close()`
//! when done, or worker threads and TCP connections will leak.
//!
//! # Exported FFI Functions
//!
//! The following functions are registered with Steel and available after loading the module:
//!
//! - `connect(address: String) -> Int` - Connect to nREPL server, returns connection ID
//! - `clone-session(conn-id: Int) -> Session` - Clone a new session for evaluations
//! - `eval(session: Session, code: String) -> Int` - Submit eval, returns request ID
//! - `eval-with-timeout(session: Session, code: String, timeout-ms: Int) -> Int` - Eval with custom timeout
//! - `load-file(session: Session, contents: String, path: String, name: String) -> Int` - Load file
//! - `try-get-result(conn-id: Int, request-id: Int) -> String|False` - Poll for result (non-blocking)
//! - `interrupt(conn-id: Int, session: Session, interrupt-id: String) -> Bool` - Interrupt evaluation
//! - `close-session(conn-id: Int, session: Session) -> Result` - Close a specific session
//! - `stdin(conn-id: Int, session: Session, data: String) -> Result` - Send stdin to evaluation
//! - `completions(conn-id: Int, session: Session, prefix: String, ...) -> List` - Get completions
//! - `lookup(conn-id: Int, session: Session, symbol: String, ...) -> Hashmap` - Lookup symbol info
//! - `stats(conn-id: Int) -> Hashmap` - Get connection statistics
//! - `close(conn-id: Int) -> Bool` - Close connection and shutdown worker
//!
//! # Thread Safety
//!
//! - **Registry**: Protected by `Arc<Mutex<Registry>>`, all operations acquire lock briefly
//! - **Worker channels**: Uses standard library `mpsc` channels for thread communication
//! - **Session cloning**: Each `Session` can be cheaply cloned and used across threads
//!
//! # Resource Limits
//!
//! - **Max connections**: 100 concurrent connections (see `registry::MAX_CONNECTIONS`)
//! - **Max pending responses**: 1000 buffered responses per worker (see `worker::MAX_PENDING_RESPONSES`)
//! - **Response size**: 10MB max per nREPL response (enforced by nrepl-rs)
//! - **Timeouts**: 60s default eval timeout, 30s for blocking operations
//!
//! # Error Handling
//!
//! FFI functions return errors as:
//! - **Option**: `None` for invalid connection/session IDs
//! - **Result in S-expression**: `(hash ... 'error "error message" ...)`
//! - **String errors**: Returned directly for submission failures
//!
//! # S-Expression Result Formats
//!
//! Several FFI functions return S-expression strings that Steel code must parse and evaluate.
//! These strings are valid Steel/Scheme code that construct data structures when evaluated.
//!
//! ## Eval Results (from `try-get-result`)
//!
//! Returns a string containing a hash construction call:
//!
//! ```scheme
//! (hash 'value "3"              ; Evaluation result (string or #f if none)
//!       'output (list "line1\n" "line2\n")  ; Stdout/stderr output (list of strings)
//!       'error #f               ; Error message (string or #f if no error)
//!       'ns "user")             ; Current namespace (string or #f)
//! ```
//!
//! **Fields**:
//! - `'value`: The result value as a string, or `#f` if evaluation produced no value
//! - `'output`: List of output strings (stdout/stderr), may be empty `(list)`
//! - `'error`: Error message string if evaluation failed, or `#f` for success
//! - `'ns`: Namespace after evaluation (e.g., "user", "clojure.core"), or `#f`
//!
//! **Usage**:
//! ```scheme
//! (define result-str (ffi.try-get-result conn-id req-id))
//! (when result-str  ; Returns #f if not ready yet
//!   (define result (eval (read (open-input-string result-str))))
//!   (hash-get result 'value))   ; Get the value
//! ```
//!
//! ## Completions (from `completions`)
//!
//! Returns a list of completion strings:
//!
//! ```scheme
//! (list "map" "mapv" "mapcat" "map-indexed")
//! ```
//!
//! **Usage**:
//! ```scheme
//! (define completions-str (ffi.completions conn-id session-id "ma" #f #f))
//! (define completions (eval (read (open-input-string completions-str))))
//! ; completions is now a list: '("map" "mapv" "mapcat" ...)
//! ```
//!
//! ## Lookup (from `lookup`)
//!
//! Returns a hash with symbol metadata:
//!
//! ```scheme
//! (hash '#:arglists "([f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls])"
//!       '#:doc "Returns a lazy sequence consisting of the result of applying f..."
//!       '#:file "clojure/core.clj"
//!       '#:line "2776"
//!       '#:name "map"
//!       '#:ns "clojure.core")
//! ```
//!
//! **Common fields** (server-dependent):
//! - `'#:arglists`: Function argument lists
//! - `'#:doc`: Documentation string
//! - `'#:file`: Source file path
//! - `'#:line`: Line number in source
//! - `'#:name`: Symbol name
//! - `'#:ns`: Defining namespace
//!
//! Note: Available fields depend on nREPL server implementation and middleware.
//!
//! ## Stats (from `stats`)
//!
//! Returns registry statistics:
//!
//! ```scheme
//! (hash 'total-connections 2
//!       'total-sessions 5
//!       'max-connections 100
//!       'next-conn-id 3
//!       'connections (list (hash 'id 1 'sessions 2)
//!                         (hash 'id 2 'sessions 3)))
//! ```
//!
//! **Fields**:
//! - `'total-connections`: Current number of open connections
//! - `'total-sessions`: Total sessions across all connections
//! - `'max-connections`: Maximum allowed connections (100)
//! - `'next-conn-id`: Next connection ID that will be assigned
//! - `'connections`: List of per-connection stats with `'id` and `'sessions` count
//!
//! # Module Structure
//!
//! ```text
//! lib.rs           ← You are here (module declaration and FFI registration)
//! ├── registry.rs  ← Global connection/session registry
//! ├── worker.rs    ← Background worker thread with Tokio runtime
//! ├── connection.rs ← FFI function implementations and result formatting
//! └── error.rs     ← Error type conversions
//! ```
//!
//! [`nrepl-rs`]: ../nrepl_rs/index.html

pub mod connection;
pub mod error;
pub mod registry;
pub mod worker;

use steel::{
    declare_module,
    steel_vm::ffi::{FFIModule, RegisterFFIFn},
};

// Export the Steel module using the declare_module! macro
declare_module!(create_module);

fn create_module() -> FFIModule {
    let mut module = FFIModule::new("steel-nrepl");

    module
        .register_fn("connect", connection::nrepl_connect)
        .register_fn("clone-session", connection::nrepl_clone_session)
        .register_fn("eval", connection::NReplSession::eval)
        .register_fn(
            "eval-with-timeout",
            connection::NReplSession::eval_with_timeout,
        )
        .register_fn("load-file", connection::NReplSession::load_file)
        .register_fn("try-get-result", connection::nrepl_try_get_result)
        .register_fn("interrupt", connection::nrepl_interrupt)
        .register_fn("close-session", connection::nrepl_close_session)
        .register_fn("stdin", connection::nrepl_stdin)
        .register_fn("completions", connection::nrepl_completions)
        .register_fn("lookup", connection::nrepl_lookup)
        .register_fn("stats", connection::nrepl_stats)
        .register_fn("close", connection::nrepl_close);

    module
}
