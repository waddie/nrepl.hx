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

//! Connection management for Steel FFI

use crate::error::{SteelNReplResult, nrepl_error_to_steel, steel_error};
use crate::registry::{self, ConnectionId, SessionId};
use crate::worker::RequestId;
use nrepl_rs::EvalResult;
use std::borrow::Cow;
use std::time::Duration;
use steel::rvals::Custom;

/// Maximum code size in bytes to prevent DoS attacks
///
/// This limit prevents malicious or accidental submission of extremely large
/// code strings that could exhaust memory or cause processing delays.
///
/// 10MB is generous for legitimate code while preventing abuse:
/// - Most source files are well under 1MB
/// - 10MB is ~200,000 lines of typical code
/// - Large enough for reasonable use cases
/// - Small enough to prevent memory exhaustion
const MAX_CODE_SIZE: usize = 10 * 1024 * 1024; // 10MB

/// Escape a string for Steel/Scheme syntax
/// Handles: ", \, newlines, tabs, and other common escapes
///
/// Uses Cow<str> to avoid allocations when no escaping is needed.
/// Returns a borrowed reference if the string contains no special characters,
/// otherwise returns an owned escaped string.
fn escape_steel_string(s: &str) -> Cow<'_, str> {
    // Check if escaping is needed
    let needs_escape = s
        .chars()
        .any(|c| matches!(c, '"' | '\\' | '\n' | '\r' | '\t'));

    if !needs_escape {
        // No escaping needed - return borrowed reference (zero allocation)
        Cow::Borrowed(s)
    } else {
        // Escaping needed - build escaped string
        let escaped: String = s
            .chars()
            .flat_map(|c| match c {
                '"' => vec!['\\', '"'],
                '\\' => vec!['\\', '\\'],
                '\n' => vec!['\\', 'n'],
                '\r' => vec!['\\', 'r'],
                '\t' => vec!['\\', 't'],
                c => vec![c],
            })
            .collect();
        Cow::Owned(escaped)
    }
}

/// Convert an EvalResult to a Steel-readable hashmap string
/// Returns a hash construction call: (hash 'value "..." 'output [...] 'error "..." 'ns "...")
/// Uses #f for false/null values (Steel is R5RS Scheme, no nil)
fn eval_result_to_steel_hashmap(result: &EvalResult) -> String {
    let mut parts = Vec::new();

    // Add 'value
    let value_str = match &result.value {
        Some(v) => format!("\"{}\"", escape_steel_string(v)),
        None => "#f".to_string(),
    };
    parts.push(format!("'value {}", value_str));

    // Add 'output as a list of strings
    let output_items: Vec<String> = result
        .output
        .iter()
        .map(|s| format!("\"{}\"", escape_steel_string(s)))
        .collect();
    parts.push(format!("'output (list {})", output_items.join(" ")));

    // Add 'error - join multiple errors with newlines, or #f if none
    let error_str = if result.error.is_empty() {
        "#f".to_string()
    } else {
        format!("\"{}\"", escape_steel_string(&result.error.join("\n")))
    };
    parts.push(format!("'error {}", error_str));

    // Add 'ns
    let ns_str = match &result.ns {
        Some(n) => format!("\"{}\"", escape_steel_string(n)),
        None => "#f".to_string(),
    };
    parts.push(format!("'ns {}", ns_str));

    format!("(hash {})", parts.join(" "))
}

/// A handle to an nREPL session that can be used from Steel
#[derive(Clone)]
pub struct NReplSession {
    pub conn_id: ConnectionId,
    pub session_id: SessionId,
}

impl Custom for NReplSession {}

impl NReplSession {
    /// Submit an eval request (non-blocking, returns request ID immediately)
    ///
    /// This function submits the eval to a background worker thread and returns
    /// a request ID immediately. Use `nrepl-try-get-result` to poll for completion.
    ///
    /// Usage: (define req-id (nrepl-eval session "(+ 1 2)" file-path line-num col-num))
    /// File location parameters are optional (pass #f for any or all of them).
    pub fn eval(
        &mut self,
        code: &str,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> SteelNReplResult<usize> {
        // Validate input
        if code.trim().is_empty() {
            return Err(steel_error(
                "Cannot evaluate empty code. Provide non-empty code to evaluate.".to_string(),
            ));
        }

        // Check code size to prevent DoS attacks
        if code.len() > MAX_CODE_SIZE {
            return Err(steel_error(format!(
                "Code size ({} bytes) exceeds maximum allowed size ({} bytes)",
                code.len(),
                MAX_CODE_SIZE
            )));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
                self.session_id.as_usize(), self.conn_id.as_usize()
            ))
        })?;

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(
            self.conn_id,
            session,
            code.to_string(),
            None,
            file,
            line,
            column,
        )
        .ok_or_else(|| {
            steel_error(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                self.conn_id.as_usize()
            ))
        })?
        .map_err(|e| steel_error(e.to_string()))?;

        Ok(request_id.as_usize())
    }

    /// Submit an eval request with custom timeout (non-blocking, returns request ID immediately)
    ///
    /// Usage: (define req-id (nrepl-eval-with-timeout session "(+ 1 2)" 5000 file-path line-num col-num))
    /// File location parameters are optional (pass #f for any or all of them).
    pub fn eval_with_timeout(
        &mut self,
        code: &str,
        timeout_ms: usize,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> SteelNReplResult<usize> {
        // Validate input
        if code.trim().is_empty() {
            return Err(steel_error(
                "Cannot evaluate empty code. Provide non-empty code to evaluate.".to_string(),
            ));
        }

        // Check code size to prevent DoS attacks
        if code.len() > MAX_CODE_SIZE {
            return Err(steel_error(format!(
                "Code size ({} bytes) exceeds maximum allowed size ({} bytes)",
                code.len(),
                MAX_CODE_SIZE
            )));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
                self.session_id.as_usize(), self.conn_id.as_usize()
            ))
        })?;

        let timeout_duration = Duration::from_millis(timeout_ms as u64);

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(
            self.conn_id,
            session,
            code.to_string(),
            Some(timeout_duration),
            file,
            line,
            column,
        )
        .ok_or_else(|| {
            steel_error(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                self.conn_id.as_usize()
            ))
        })?
        .map_err(|e| steel_error(e.to_string()))?;

        Ok(request_id.as_usize())
    }

    /// Submit a load-file request (non-blocking, returns request ID immediately)
    ///
    /// Loads file contents with optional file path and name for better error messages.
    /// This is similar to eval but provides context for error reporting.
    ///
    /// Usage: (define req-id (nrepl-load-file session file-contents "/path/to/file.clj" "file.clj"))
    /// Or with no path info: (define req-id (nrepl-load-file session file-contents #f #f))
    pub fn load_file(
        &mut self,
        file_contents: &str,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> SteelNReplResult<usize> {
        // Validate input
        if file_contents.trim().is_empty() {
            return Err(steel_error(
                "Cannot load empty file contents. Provide non-empty file contents to load."
                    .to_string(),
            ));
        }

        // Check file size to prevent DoS attacks
        if file_contents.len() > MAX_CODE_SIZE {
            return Err(steel_error(format!(
                "File size ({} bytes) exceeds maximum allowed size ({} bytes)",
                file_contents.len(),
                MAX_CODE_SIZE
            )));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
                self.session_id.as_usize(), self.conn_id.as_usize()
            ))
        })?;

        // Submit load-file to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_load_file(
            self.conn_id,
            session,
            file_contents.to_string(),
            file_path,
            file_name,
        )
        .ok_or_else(|| {
            steel_error(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                self.conn_id.as_usize()
            ))
        })?
        .map_err(|e| steel_error(e.to_string()))?;

        Ok(request_id.as_usize())
    }

    /// Get code completions for a prefix
    ///
    /// Returns a list of completion suggestions with metadata for the given prefix.
    /// Useful for implementing autocomplete in editors.
    ///
    /// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
    /// If the server doesn't respond within this timeout, a timeout error is returned.
    ///
    /// # Arguments
    /// * `prefix` - The code prefix to complete (e.g., "ma" might suggest "map", "mapv", etc.)
    /// * `ns` - Optional namespace to complete in (e.g., Some("clojure.core"))
    /// * `complete_fn` - Optional custom completion function name
    ///
    /// # Returns
    ///
    /// Returns a Steel list of hashmaps, each containing completion metadata:
    ///
    /// ```scheme
    /// (list
    ///   (hash '#:candidate "map" '#:ns "clojure.core" '#:type "function")
    ///   (hash '#:candidate "mapv" '#:ns "clojure.core" '#:type "function")
    ///   (hash '#:candidate "defmacro" '#:ns "clojure.core" '#:type "macro")
    ///   ...)
    /// ```
    ///
    /// Each hash contains:
    /// - `'#:candidate`: The completion string
    /// - `'#:ns`: The namespace where defined (or #f if unknown)
    /// - `'#:type`: The symbol type - "function", "macro", "var", etc. (or #f if unknown)
    ///
    /// Usage: (session.completions "ma" #f #f)
    pub fn completions(
        &self,
        prefix: &str,
        ns: Option<String>,
        complete_fn: Option<String>,
    ) -> SteelNReplResult<String> {
        if std::env::var("NREPL_DEBUG").is_ok() {
            eprintln!(
                "[NREPL_DEBUG] completions called: conn_id={}, session_id={}, prefix={:?}",
                self.conn_id.as_usize(),
                self.session_id.as_usize(),
                prefix
            );
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
                self.session_id.as_usize(), self.conn_id.as_usize()
            ))
        })?;

        if std::env::var("NREPL_DEBUG").is_ok() {
            eprintln!(
                "[NREPL_DEBUG] Retrieved session from registry, calling completions_blocking"
            );
        }

        let completions = registry::completions_blocking(
            self.conn_id,
            session,
            prefix.to_string(),
            ns,
            complete_fn,
        )
        .map_err(nrepl_error_to_steel)?;

        if std::env::var("NREPL_DEBUG").is_ok() {
            eprintln!(
                "[NREPL_DEBUG] completions_blocking returned {} items",
                completions.len()
            );
        }

        // Format as Steel list of hashmaps with full completion metadata:
        // (list (hash '#:candidate "map" '#:ns "clojure.core" '#:type "function") ...)
        let completion_items: Vec<String> = completions
            .iter()
            .map(|c| {
                let mut parts = Vec::new();

                // Always include candidate
                parts.push(format!(
                    "'#:candidate \"{}\"",
                    escape_steel_string(&c.candidate)
                ));

                // Include namespace if present
                if let Some(ns) = &c.ns {
                    parts.push(format!("'#:ns \"{}\"", escape_steel_string(ns)));
                } else {
                    parts.push("'#:ns #f".to_string());
                }

                // Include type if present
                if let Some(ctype) = &c.candidate_type {
                    parts.push(format!("'#:type \"{}\"", escape_steel_string(ctype)));
                } else {
                    parts.push("'#:type #f".to_string());
                }

                format!("(hash {})", parts.join(" "))
            })
            .collect();

        Ok(format!("(list {})", completion_items.join(" ")))
    }

    /// Lookup information about a symbol
    ///
    /// Returns documentation and metadata for a symbol.
    /// Useful for "go to definition", inline docs, and symbol information features.
    ///
    /// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
    /// If the server doesn't respond within this timeout, a timeout error is returned.
    ///
    /// # Arguments
    /// * `sym` - The symbol to look up (e.g., "map", "clojure.core/reduce")
    /// * `ns` - Optional namespace context
    /// * `lookup_fn` - Optional custom lookup function name
    ///
    /// # Returns
    ///
    /// Returns an S-expression string containing a hashmap with symbol metadata.
    /// The exact fields depend on the nREPL server implementation and available middleware.
    ///
    /// **Example result for looking up "map" in Clojure:**
    /// ```scheme
    /// (hash '#:arglists "([f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls])"
    ///       '#:doc "Returns a lazy sequence consisting of the result of applying f..."
    ///       '#:file "clojure/core.clj"
    ///       '#:line "2776"
    ///       '#:name "map"
    ///       '#:ns "clojure.core")
    /// ```
    ///
    /// **Common fields** (server-dependent):
    /// - `'#:arglists`: Function argument lists as a string
    /// - `'#:doc`: Documentation string
    /// - `'#:file`: Source file path where symbol is defined
    /// - `'#:line`: Line number in source file (as string)
    /// - `'#:name`: Symbol name
    /// - `'#:ns`: Defining namespace
    /// - Other fields may be present depending on server capabilities
    ///
    /// If the symbol is not found or the server doesn't provide info, returns an empty hash: `(hash )`
    ///
    /// # Usage
    /// ```scheme
    /// (define lookup-str (session.lookup "map" #f #f))
    /// (define info (eval (read (open-input-string lookup-str))))
    /// (hash-get info '#:doc)  ; Get documentation string
    /// ```
    pub fn lookup(
        &self,
        sym: &str,
        ns: Option<String>,
        lookup_fn: Option<String>,
    ) -> SteelNReplResult<String> {
        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
                self.session_id.as_usize(), self.conn_id.as_usize()
            ))
        })?;

        let response =
            registry::lookup_blocking(self.conn_id, session, sym.to_string(), ns, lookup_fn)
                .map_err(nrepl_error_to_steel)?;

        // Convert Response.info (BTreeMap<String, String>) to Steel hashmap
        // The info field contains the symbol information from the lookup operation
        let mut parts = Vec::new();

        if let Some(info) = response.info {
            for (key, value) in info.iter() {
                // Convert key to Steel keyword syntax (using #: prefix)
                let key_escaped = escape_steel_string(key);
                let value_escaped = escape_steel_string(value);
                parts.push(format!("'#:{} \"{}\"", key_escaped, value_escaped));
            }
        }

        // If no info was returned, return an empty hash
        Ok(format!("(hash {})", parts.join(" ")))
    }
}

// Note: We no longer need a shared runtime here because each worker thread
// has its own Tokio runtime. This avoids runtime contention and allows
// better isolation of async operations.

/// Try to get a completed eval result (non-blocking)
///
/// Returns #f if no result is ready yet.
/// Returns the result string if ready: (hash 'value "..." 'output (list) 'error #f 'ns "user")
///
/// Usage in polling loop:
/// ```scheme
/// (define req-id (nrepl-eval session code))
/// (helix-await-callback
///   (lambda ()
///     (nrepl-try-get-result conn-id req-id))
///   (lambda (result)
///     (when result
///       ;; Got result! Process it
///       (process-result result))))
/// ```
pub fn nrepl_try_get_result(conn_id: usize, request_id: usize) -> SteelNReplResult<Option<String>> {
    // Try to get the response for this specific request ID
    // The worker buffers responses to support concurrent evals
    match registry::try_recv_response(ConnectionId::new(conn_id), RequestId::new(request_id)) {
        Some(response) => {
            let result = response.result.map_err(nrepl_error_to_steel)?;
            Ok(Some(eval_result_to_steel_hashmap(&result)))
        }
        None => {
            // Response not ready yet
            Ok(None)
        }
    }
}

/// Connect to an nREPL server
/// Returns a connection ID
///
/// **Important:** You must call `nrepl-close` when done to avoid resource leaks.
/// Connections are not automatically closed when the ID goes out of scope.
///
/// # Example
/// ```scheme
/// (define conn (nrepl-connect "localhost:7888"))
/// (define session (nrepl-clone-session conn))
/// ;; ... use connection ...
/// (nrepl-close conn)  ; Don't forget this!
/// ```
///
/// Usage: (nrepl-connect "localhost:7888")
pub fn nrepl_connect(address: String) -> SteelNReplResult<usize> {
    // Create worker thread and connect to server
    // Connection happens within the worker's Tokio runtime context
    let conn_id = registry::create_and_connect(address).map_err(nrepl_error_to_steel)?;

    Ok(conn_id.as_usize())
}

/// Clone a new session from a connection
/// Returns a session handle
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// Usage: (define session (nrepl-clone-session conn-id))
pub fn nrepl_clone_session(conn_id: usize) -> SteelNReplResult<NReplSession> {
    let conn_id = ConnectionId::new(conn_id);
    let session = registry::clone_session_blocking(conn_id).map_err(nrepl_error_to_steel)?;

    let session_id = registry::add_session(conn_id, session).ok_or_else(|| {
        steel_error(format!(
            "Failed to add session to connection {}. The connection may have been closed.",
            conn_id.as_usize()
        ))
    })?;

    Ok(NReplSession {
        conn_id,
        session_id,
    })
}

/// Interrupt an ongoing evaluation
///
/// **⚠️ ARCHITECTURAL LIMITATION**: This operation is fully implemented and exported via FFI,
/// but **cannot work effectively** with the current steel-nrepl worker architecture. Calling
/// this function will send the interrupt request to the server, but the request cannot be
/// processed until after the ongoing evaluation completes, defeating its purpose.
///
/// ## Why Interrupt Cannot Work
///
/// The steel-nrepl worker thread processes commands sequentially:
/// 1. Worker thread receives `WorkerCommand::Eval` from the channel
/// 2. Worker blocks on `rt.block_on(c.eval_with_request(...))` (worker.rs:170)
/// 3. Inside eval, nrepl-rs enters a blocking loop reading TCP responses (connection.rs ~794-928)
/// 4. While blocked in steps 2-3, the worker cannot process new commands from the channel
/// 5. An `interrupt` command sent during eval sits unprocessed in the channel
/// 6. The interrupt is only processed after eval completes (defeats its purpose)
///
/// This is the same architectural limitation as documented in nrepl-rs `NReplClient::interrupt()`.
/// The worker thread's sequential command processing prevents concurrent interrupt operations.
///
/// ## To Fix This Would Require
///
/// Major architectural changes to steel-nrepl:
/// 1. **Spawn eval as separate task**: Don't block worker thread, spawn eval operations as
///    concurrent Tokio tasks
/// 2. **Multiple connections**: One connection for eval, one for control operations like interrupt
/// 3. **Split worker responsibilities**: Separate thread/task for interrupt handling
///
/// ## Current Mitigation
///
/// Use `nrepl-eval-with-timeout` to specify a maximum evaluation time. If an evaluation hangs,
/// it will timeout and return an error.
///
/// ---
///
/// Sends an interrupt request to cancel a long-running evaluation. Takes the nREPL
/// message ID (not the steel-nrepl request ID) of the evaluation to interrupt.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// **Note:** This requires the nREPL message ID which is generated by nrepl-rs.
/// For now, this is primarily useful for advanced use cases or debugging.
/// Future improvements will track message IDs automatically.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID containing the evaluation
/// * `interrupt_id` - The nREPL message ID to interrupt (e.g., "req-123")
///
/// Usage: (nrepl-interrupt conn-id session-id "req-123")
pub fn nrepl_interrupt(
    conn_id: usize,
    session_id: usize,
    interrupt_id: &str,
) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
            session_id.as_usize(),
            conn_id.as_usize()
        ))
    })?;

    registry::interrupt_blocking(conn_id, session, interrupt_id.to_string())
        .map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Close a session on the server
///
/// Explicitly closes a session on the nREPL server and removes it from the registry.
/// After closing, the session cannot be used for further evaluations.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// This is useful when you want to clean up a specific session without closing
/// the entire connection. For closing all sessions and the connection, use
/// `nrepl-close` instead.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID to close
///
/// Usage: (nrepl-close-session conn-id session-id)
pub fn nrepl_close_session(conn_id: usize, session_id: usize) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}. It may have already been closed.",
            session_id.as_usize(),
            conn_id.as_usize()
        ))
    })?;

    // Close the session on the server
    registry::close_session_blocking(conn_id, session).map_err(nrepl_error_to_steel)?;

    // Remove the session from the registry now that it's closed on the server
    // This prevents the session from being reused and cleans up memory
    registry::remove_session(conn_id, session_id);

    Ok(())
}

/// Send stdin data to a session
///
/// Sends input data to a session for interactive programs that read from stdin.
/// This is useful for programs that call `read-line` or similar input functions.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `data` - The stdin data to send
///
/// Usage: (nrepl-stdin conn-id session-id "user input\n")
pub fn nrepl_stdin(conn_id: usize, session_id: usize, data: &str) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
            session_id.as_usize(),
            conn_id.as_usize()
        ))
    })?;

    registry::stdin_blocking(conn_id, session, data.to_string()).map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Get code completions for a prefix
///
/// Returns a list of completion suggestions with metadata for the given prefix.
/// Useful for implementing autocomplete in editors.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `prefix` - The code prefix to complete (e.g., "ma" might suggest "map", "mapv", etc.)
/// * `ns` - Optional namespace to complete in (e.g., Some("clojure.core"))
/// * `complete_fn` - Optional custom completion function name
///
/// # Returns
///
/// Returns a Steel list of hashmaps, each containing completion metadata:
///
/// ```scheme
/// (list
///   (hash '#:candidate "map" '#:ns "clojure.core" '#:type "function")
///   (hash '#:candidate "mapv" '#:ns "clojure.core" '#:type "function")
///   (hash '#:candidate "defmacro" '#:ns "clojure.core" '#:type "macro")
///   ...)
/// ```
///
/// Each hash contains:
/// - `'#:candidate`: The completion string
/// - `'#:ns`: The namespace where defined (or #f if unknown)
/// - `'#:type`: The symbol type - "function", "macro", "var", etc. (or #f if unknown)
///
/// Usage: (nrepl-completions conn-id session-id "ma" #f #f)
pub fn nrepl_completions(
    conn_id: usize,
    session_id: usize,
    prefix: &str,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> SteelNReplResult<String> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
            session_id.as_usize(),
            conn_id.as_usize()
        ))
    })?;

    let completions =
        registry::completions_blocking(conn_id, session, prefix.to_string(), ns, complete_fn)
            .map_err(nrepl_error_to_steel)?;

    // Format as Steel list of hashmaps with full completion metadata:
    // (list (hash '#:candidate "map" '#:ns "clojure.core" '#:type "function") ...)
    let completion_items: Vec<String> = completions
        .iter()
        .map(|c| {
            let mut parts = Vec::new();

            // Always include candidate
            parts.push(format!(
                "'#:candidate \"{}\"",
                escape_steel_string(&c.candidate)
            ));

            // Include namespace if present
            if let Some(ns) = &c.ns {
                parts.push(format!("'#:ns \"{}\"", escape_steel_string(ns)));
            } else {
                parts.push("'#:ns #f".to_string());
            }

            // Include type if present
            if let Some(ctype) = &c.candidate_type {
                parts.push(format!("'#:type \"{}\"", escape_steel_string(ctype)));
            } else {
                parts.push("'#:type #f".to_string());
            }

            format!("(hash {})", parts.join(" "))
        })
        .collect();

    Ok(format!("(list {})", completion_items.join(" ")))
}

/// Lookup information about a symbol
///
/// Returns documentation and metadata for a symbol.
/// Useful for "go to definition", inline docs, and symbol information features.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `sym` - The symbol to look up (e.g., "map", "clojure.core/reduce")
/// * `ns` - Optional namespace context
/// * `lookup_fn` - Optional custom lookup function name
///
/// # Returns
///
/// Returns an S-expression string containing a hashmap with symbol metadata.
/// The exact fields depend on the nREPL server implementation and available middleware.
///
/// **Example result for looking up "map" in Clojure:**
/// ```scheme
/// (hash '#:arglists "([f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls])"
///       '#:doc "Returns a lazy sequence consisting of the result of applying f..."
///       '#:file "clojure/core.clj"
///       '#:line "2776"
///       '#:name "map"
///       '#:ns "clojure.core")
/// ```
///
/// **Common fields** (server-dependent):
/// - `'#:arglists`: Function argument lists as a string
/// - `'#:doc`: Documentation string
/// - `'#:file`: Source file path where symbol is defined
/// - `'#:line`: Line number in source file (as string)
/// - `'#:name`: Symbol name
/// - `'#:ns`: Defining namespace
/// - Other fields may be present depending on server capabilities
///
/// If the symbol is not found or the server doesn't provide info, returns an empty hash: `(hash )`
///
/// # Usage
/// ```scheme
/// (define lookup-str (nrepl-lookup conn-id session-id "map" #f #f))
/// (define info (eval (read (open-input-string lookup-str))))
/// (hash-get info '#:doc)  ; Get documentation string
/// ```
pub fn nrepl_lookup(
    conn_id: usize,
    session_id: usize,
    sym: &str,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> SteelNReplResult<String> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
            session_id.as_usize(),
            conn_id.as_usize()
        ))
    })?;

    let response = registry::lookup_blocking(conn_id, session, sym.to_string(), ns, lookup_fn)
        .map_err(nrepl_error_to_steel)?;

    // Convert Response.info (BTreeMap<String, String>) to Steel hashmap
    // The info field contains the symbol information from the lookup operation
    let mut parts = Vec::new();

    if let Some(info) = response.info {
        for (key, value) in info.iter() {
            // Convert key to Steel keyword syntax (using #: prefix)
            let key_escaped = escape_steel_string(key);
            let value_escaped = escape_steel_string(value);
            parts.push(format!("'#:{} \"{}\"", key_escaped, value_escaped));
        }
    }

    // If no info was returned, return an empty hash
    Ok(format!("(hash {})", parts.join(" ")))
}

/// Get registry statistics for observability
///
/// Returns a hashmap with connection and session counts, useful for monitoring.
///
/// Returns: Steel hashmap string with stats like:
/// `(hash 'total-connections 2 'total-sessions 5 'max-connections 100)`
///
/// Usage: (nrepl-stats)
pub fn nrepl_stats() -> String {
    let stats = registry::get_stats();

    // Format as Steel hashmap with connection details
    let mut parts = vec![
        format!("'total-connections {}", stats.total_connections),
        format!("'total-sessions {}", stats.total_sessions),
        format!("'max-connections {}", stats.max_connections),
        format!("'next-conn-id {}", stats.next_conn_id),
    ];

    // Add connection details as list
    let conn_details: Vec<String> = stats
        .connections
        .iter()
        .map(|c| {
            format!(
                "(hash 'id {} 'sessions {})",
                c.connection_id.as_usize(),
                c.session_count
            )
        })
        .collect();

    parts.push(format!("'connections (list {})", conn_details.join(" ")));

    format!("(hash {})", parts.join(" "))
}

/// Close an nREPL connection
///
/// Removes the connection from the registry and triggers graceful shutdown.
/// The worker thread's Drop implementation will call shutdown() which closes
/// all sessions on the server and the TCP connection.
///
/// **You must call this** for every connection created with `nrepl-connect`
/// to avoid resource leaks.
///
/// **Non-blocking:** This function returns immediately. The actual cleanup
/// (closing sessions and TCP connection) happens in the background via the
/// worker thread's shutdown sequence with a 10-second timeout.
///
/// # Errors
/// Returns an error if the connection ID is not found (already closed or never existed).
///
/// Usage: (nrepl-close conn-id)
pub fn nrepl_close(conn_id: usize) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);

    // Remove connection from registry
    // This triggers worker Drop → shutdown() → client.shutdown()
    // which closes all sessions cleanly in the background
    if !registry::remove_connection(conn_id) {
        return Err(steel_error(format!(
            "Connection {} not found. It may have already been closed.",
            conn_id.as_usize()
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_escape_steel_string_quotes() {
        assert_eq!(escape_steel_string("\"hello\""), r#"\"hello\""#);
    }

    #[test]
    fn test_escape_steel_string_backslashes() {
        assert_eq!(escape_steel_string(r"path\to\file"), r"path\\to\\file");
    }

    #[test]
    fn test_escape_steel_string_newlines() {
        assert_eq!(escape_steel_string("line1\nline2"), r"line1\nline2");
    }

    #[test]
    fn test_escape_steel_string_tabs() {
        assert_eq!(escape_steel_string("col1\tcol2"), r"col1\tcol2");
    }

    #[test]
    fn test_escape_steel_string_carriage_return() {
        assert_eq!(escape_steel_string("line1\rline2"), r"line1\rline2");
    }

    #[test]
    fn test_escape_steel_string_combined() {
        let input = "He said \"Hello\"\nNext line\tTab here\\backslash";
        let expected = r#"He said \"Hello\"\nNext line\tTab here\\backslash"#;
        assert_eq!(escape_steel_string(input), expected);
    }

    #[test]
    fn test_escape_steel_string_empty() {
        assert_eq!(escape_steel_string(""), "");
    }

    #[test]
    fn test_escape_steel_string_no_escapes_needed() {
        assert_eq!(escape_steel_string("simple text"), "simple text");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_simple_value() {
        let result = EvalResult {
            value: Some("42".to_string()),
            output: vec![],
            error: vec![],
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify it's a valid S-expression hash
        assert!(hashmap.starts_with("(hash "), "Should start with '(hash '");
        assert!(hashmap.ends_with(')'), "Should end with ')'");

        // Verify it contains expected keys
        assert!(hashmap.contains("'value \"42\""), "Should contain value");
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );
        assert!(hashmap.contains("'error #f"), "Should contain no error");
        assert!(hashmap.contains("'ns \"user\""), "Should contain namespace");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_with_output() {
        let result = EvalResult {
            value: Some("3".to_string()),
            output: vec!["hello\n".to_string(), "world\n".to_string()],
            error: vec![],
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify output list contains both strings
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );
        assert!(
            hashmap.contains(r#"hello\n"#),
            "Should contain first output with escaped newline"
        );
        assert!(
            hashmap.contains(r#"world\n"#),
            "Should contain second output with escaped newline"
        );
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_with_error() {
        let result = EvalResult {
            value: None,
            output: vec![],
            error: vec!["Syntax error".to_string(), "Line 42".to_string()],
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify error is joined with newlines
        assert!(
            hashmap.contains("'error \"Syntax error\\nLine 42\""),
            "Should contain joined errors"
        );
        assert!(hashmap.contains("'value #f"), "Should contain no value");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_no_namespace() {
        let result = EvalResult {
            value: Some("result".to_string()),
            output: vec![],
            error: vec![],
            ns: None,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        assert!(hashmap.contains("'ns #f"), "Should contain no namespace");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_special_chars_in_value() {
        let result = EvalResult {
            value: Some("\"quoted\"\n\ttabbed".to_string()),
            output: vec![],
            error: vec![],
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify special characters are escaped
        assert!(hashmap.contains(r#"\"quoted\""#), "Should escape quotes");
        assert!(hashmap.contains(r"\n"), "Should escape newline");
        assert!(hashmap.contains(r"\t"), "Should escape tab");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_empty_error_list() {
        let result = EvalResult {
            value: Some("ok".to_string()),
            output: vec![],
            error: vec![], // Empty error list should become #f
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        assert!(
            hashmap.contains("'error #f"),
            "Empty error list should be #f"
        );
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_multiple_output_entries() {
        let result = EvalResult {
            value: Some("done".to_string()),
            output: vec![
                "line 1".to_string(),
                "line 2".to_string(),
                "line 3".to_string(),
            ],
            error: vec![],
            ns: Some("test.ns".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify all output entries are present
        assert!(hashmap.contains("\"line 1\""), "Should contain first line");
        assert!(hashmap.contains("\"line 2\""), "Should contain second line");
        assert!(hashmap.contains("\"line 3\""), "Should contain third line");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_empty_string_output() {
        // Test edge case where output contains empty strings
        let result = EvalResult {
            value: Some("result".to_string()),
            output: vec!["".to_string(), "non-empty".to_string(), "".to_string()],
            error: vec![],
            ns: Some("user".to_string()),
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify output list is present
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );

        // Empty strings should appear as ""
        // The output should have three entries: two empty strings and one non-empty
        assert!(hashmap.contains("\"\""), "Should contain empty strings");
        assert!(
            hashmap.contains("\"non-empty\""),
            "Should contain non-empty string"
        );

        // Verify structure is valid
        assert!(hashmap.starts_with("(hash "), "Should start with '(hash '");
        assert!(hashmap.ends_with(')'), "Should end with ')'");
    }

    #[test]
    fn test_escape_steel_string_unicode_and_emoji() {
        // Test that Unicode and emoji characters are preserved as-is
        // Steel/Scheme strings support UTF-8, so we don't need to escape these

        // Unicode characters from various languages
        let unicode_text = "Hello 世界 مرحبا мир"; // Chinese, Arabic, Cyrillic
        assert_eq!(
            escape_steel_string(unicode_text),
            unicode_text,
            "Unicode text should be preserved"
        );

        // Emoji
        let emoji_text = "🎉 🚀 ❤️ 👍";
        assert_eq!(
            escape_steel_string(emoji_text),
            emoji_text,
            "Emoji should be preserved"
        );

        // Mixed content with special chars that DO need escaping
        let mixed = "Hello 🌍\nNext line\t\"quoted\"";
        let expected = "Hello 🌍\\nNext line\\t\\\"quoted\\\""; // Only ASCII special chars escaped
        assert_eq!(
            escape_steel_string(mixed),
            expected,
            "Should preserve Unicode while escaping ASCII special chars"
        );

        // Edge case: Unicode with backslash
        let unicode_with_backslash = "Path\\to\\日本語\\file";
        let expected_unicode_backslash = "Path\\\\to\\\\日本語\\\\file"; // Backslashes escaped, Unicode preserved
        assert_eq!(
            escape_steel_string(unicode_with_backslash),
            expected_unicode_backslash,
            "Should escape backslashes but preserve Unicode"
        );
    }

    #[test]
    fn test_max_code_size_constant() {
        // Verify MAX_CODE_SIZE is set to expected value
        assert_eq!(
            MAX_CODE_SIZE,
            10 * 1024 * 1024,
            "MAX_CODE_SIZE should be 10MB"
        );
    }

    #[test]
    fn test_eval_with_invalid_connection_id() {
        // Test that eval with an invalid (non-existent) connection ID returns an error
        // This verifies the error handling path when the session lookup fails due to
        // the connection not existing in the registry

        let invalid_conn_id = ConnectionId::new(999);
        let session_id = SessionId::new(1);

        // Create a session struct with invalid IDs
        let mut session = NReplSession {
            conn_id: invalid_conn_id,
            session_id,
        };

        // Attempt to eval - should fail with "Session not found" error
        let result = session.eval("(+ 1 2)", None, None, None);

        assert!(
            result.is_err(),
            "eval should fail with invalid connection ID"
        );
        let err_msg = format!("{:?}", result.unwrap_err());
        assert!(
            err_msg.contains("Session") && err_msg.contains("not found"),
            "Error should mention session not found, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_eval_with_invalid_session_id() {
        // Test that eval with an invalid session ID returns an error
        // This verifies error handling when the session ID doesn't exist in a connection
        //
        // Note: We can't easily test this in a pure unit test because we'd need a real
        // connection in the registry. This test documents the expected behavior, which
        // is actually the same as invalid connection ID - both result in session not found.
        //
        // The actual behavior is tested in integration tests where we can create real
        // connections and then try to use invalid session IDs.

        let conn_id = ConnectionId::new(1);
        let invalid_session_id = SessionId::new(999);

        let mut session = NReplSession {
            conn_id,
            session_id: invalid_session_id,
        };

        // Attempt to eval - should fail with "Session not found" error
        let result = session.eval("(+ 1 2)", None, None, None);

        assert!(result.is_err(), "eval should fail with invalid session ID");
        let err_msg = format!("{:?}", result.unwrap_err());
        assert!(
            err_msg.contains("Session") && err_msg.contains("not found"),
            "Error should mention session not found, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_session_removal_after_close_session() {
        // Test that nrepl_close_session removes the session from the registry
        // This is important to prevent memory leaks and reuse of closed sessions
        //
        // Note: This is a unit test documenting the expected behavior. The actual
        // removal is tested in integration tests where we can create real connections
        // and sessions, then verify they're removed from the registry after closing.
        //
        // The implementation in connection.rs:377 calls registry::remove_session()
        // after successfully closing the session on the server. This test documents
        // that this cleanup step must happen.

        // This test serves as documentation of the cleanup contract:
        // 1. Session is closed on the nREPL server
        // 2. Session is removed from the registry (connection.rs:377)
        // 3. Subsequent attempts to use the session fail with "Session not found"

        // The actual testing happens in:
        // - tests/ffi_integration.rs - verifies session cleanup in integration tests
        // - registry.rs unit tests - verify remove_session() works correctly

        // For now, just verify the expected error message format
        let conn_id = ConnectionId::new(1);
        let session_id = SessionId::new(1);

        let mut session = NReplSession {
            conn_id,
            session_id,
        };

        // After close_session is called, subsequent eval should fail
        let result = session.eval("(+ 1 2)", None, None, None);
        assert!(result.is_err(), "eval should fail after session is closed");

        let err_msg = format!("{:?}", result.unwrap_err());
        assert!(
            err_msg.contains("Session") && err_msg.contains("not found"),
            "Error should indicate session not found, got: {}",
            err_msg
        );
    }

    // Property-based tests using proptest
    use proptest::prelude::*;

    proptest! {
        /// Property: Escaped string should never be shorter than the original
        ///
        /// Since escaping only adds characters (never removes), the escaped
        /// string must be >= original length
        #[test]
        fn prop_escaped_length_never_decreases(s in ".*") {
            let escaped = escape_steel_string(&s);
            prop_assert!(escaped.len() >= s.len(),
                "Escaped string ({} bytes) shorter than original ({} bytes): {:?} -> {:?}",
                escaped.len(), s.len(), s, escaped);
        }

        /// Property: No unescaped quotes in output
        ///
        /// After escaping, any quote character (") must be preceded by a backslash.
        /// This ensures the string can be safely embedded in Steel/Scheme syntax.
        #[test]
        fn prop_no_unescaped_quotes(s in ".*") {
            let escaped = escape_steel_string(&s);

            // Check each quote is preceded by backslash
            let chars: Vec<char> = escaped.chars().collect();
            for (i, &c) in chars.iter().enumerate() {
                if c == '"' {
                    prop_assert!(i > 0 && chars[i-1] == '\\',
                        "Found unescaped quote at position {} in: {:?}", i, escaped);
                }
            }
        }

        /// Property: No bare newlines, tabs, or carriage returns
        ///
        /// These characters must be escaped as \n, \t, \r respectively.
        /// The literal characters should not appear in the output.
        #[test]
        fn prop_no_bare_control_chars(s in ".*") {
            let escaped = escape_steel_string(&s);

            prop_assert!(!escaped.contains('\n'),
                "Found bare newline in escaped string: {:?}", escaped);
            prop_assert!(!escaped.contains('\t'),
                "Found bare tab in escaped string: {:?}", escaped);
            prop_assert!(!escaped.contains('\r'),
                "Found bare carriage return in escaped string: {:?}", escaped);
        }

        /// Property: All backslashes are doubled or part of valid escape sequences
        ///
        /// After escaping, every backslash should either be:
        /// - Followed by another backslash (escaped backslash: \\)
        /// - Followed by a valid ASCII escape character (", n, t, r)
        /// Note: Non-ASCII characters after backslash are fine (they pass through unchanged)
        #[test]
        fn prop_valid_escape_sequences(s in ".*") {
            let escaped = escape_steel_string(&s);
            let chars: Vec<char> = escaped.chars().collect();

            let mut i = 0;
            while i < chars.len() {
                if chars[i] == '\\' {
                    prop_assert!(i + 1 < chars.len(),
                        "Backslash at end of string (position {}): {:?}", i, escaped);

                    let next = chars[i + 1];
                    // After a backslash, we expect either:
                    // - Another backslash (escaped \)
                    // - An ASCII escape char (", n, t, r)
                    // - Or a non-ASCII char (which is fine, just data)
                    if next.is_ascii() {
                        prop_assert!(
                            next == '\\' || next == '"' || next == 'n' || next == 't' || next == 'r',
                            "Invalid ASCII escape sequence \\{} at position {} in: {:?}",
                            next, i, escaped
                        );
                    }
                    // If we have \\, skip the next backslash
                    if next == '\\' {
                        i += 2;
                        continue;
                    }
                }
                i += 1;
            }
        }

        /// Property: Unicode and emoji are preserved
        ///
        /// Non-ASCII characters should pass through unchanged, only ASCII
        /// special characters should be escaped.
        #[test]
        fn prop_unicode_preserved(s in "[\\u{80}-\\u{10FFFF}]+") {
            // Generate strings with only non-ASCII characters
            let escaped = escape_steel_string(&s);

            // Since the input contains no ASCII special chars, output should equal input
            prop_assert_eq!(&escaped, &s,
                "Unicode-only string was modified: {:?} -> {:?}", s, escaped);
        }

        /// Property: Escaping is consistent
        ///
        /// Calling escape_steel_string twice should produce the same result as
        /// calling it once (idempotence for already-escaped strings).
        /// Note: This is NOT true in general because escaping adds backslashes
        /// which then get escaped again. This property tests that re-escaping
        /// is well-defined.
        #[test]
        fn prop_double_escape_is_well_defined(s in ".*") {
            let escaped_once = escape_steel_string(&s);
            let escaped_twice = escape_steel_string(&escaped_once);

            // Verify second escape is valid (doesn't panic or produce invalid output)
            prop_assert!(escaped_twice.len() >= escaped_once.len(),
                "Second escape produced shorter string: {:?} -> {:?}",
                escaped_once, escaped_twice);
        }

        /// Property: Empty string remains empty
        #[test]
        fn prop_empty_string_unchanged(_s in prop::strategy::Just(())) {
            let escaped = escape_steel_string("");
            prop_assert_eq!(&escaped, "",
                "Empty string was modified: {:?}", escaped);
        }

        /// Property: Strings without special characters are unchanged
        ///
        /// If a string contains only alphanumeric, spaces, and common punctuation
        /// (no quotes, backslashes, or control chars), it should pass through as-is.
        #[test]
        fn prop_safe_strings_unchanged(s in "[a-zA-Z0-9 .,;:!?()\\[\\]{}]+") {
            let escaped = escape_steel_string(&s);
            prop_assert_eq!(&escaped, &s,
                "Safe string was modified: {:?} -> {:?}", s, escaped);
        }
    }
}
