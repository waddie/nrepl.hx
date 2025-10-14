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
use nrepl_rs::EvalResult;
use std::time::Duration;
use steel::rvals::Custom;

/// Escape a string for Steel/Scheme syntax
/// Handles: ", \, newlines, tabs, and other common escapes
fn escape_steel_string(s: &str) -> String {
    s.chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            '\n' => vec!['\\', 'n'],
            '\r' => vec!['\\', 'r'],
            '\t' => vec!['\\', 't'],
            c => vec![c],
        })
        .collect()
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
    /// Usage: (define req-id (nrepl-eval session "(+ 1 2)"))
    pub fn eval(&mut self, code: &str) -> SteelNReplResult<usize> {
        // Validate input
        if code.trim().is_empty() {
            return Err(steel_error("Cannot evaluate empty code".to_string()));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
            ))
        })?;

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(self.conn_id, session, code.to_string(), None)
            .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?
            .map_err(steel_error)?;

        Ok(request_id)
    }

    /// Submit an eval request with custom timeout (non-blocking, returns request ID immediately)
    ///
    /// Usage: (define req-id (nrepl-eval-with-timeout session "(+ 1 2)" 5000))
    pub fn eval_with_timeout(&mut self, code: &str, timeout_ms: usize) -> SteelNReplResult<usize> {
        // Validate input
        if code.trim().is_empty() {
            return Err(steel_error("Cannot evaluate empty code".to_string()));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
            ))
        })?;

        let timeout_duration = Duration::from_millis(timeout_ms as u64);

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(
            self.conn_id,
            session,
            code.to_string(),
            Some(timeout_duration),
        )
        .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?
        .map_err(steel_error)?;

        Ok(request_id)
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
            return Err(steel_error("Cannot load empty file contents".to_string()));
        }

        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
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
        .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?
        .map_err(steel_error)?;

        Ok(request_id)
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
pub fn nrepl_try_get_result(conn_id: ConnectionId, request_id: usize) -> SteelNReplResult<Option<String>> {
    // Try to get the response for this specific request ID
    // The worker buffers responses to support concurrent evals
    match registry::try_recv_response(conn_id, request_id) {
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
pub fn nrepl_connect(address: String) -> SteelNReplResult<ConnectionId> {
    // Create worker thread and connect to server
    // Connection happens within the worker's Tokio runtime context
    let conn_id = registry::create_and_connect(address)
        .map_err(nrepl_error_to_steel)?;

    Ok(conn_id)
}

/// Clone a new session from a connection
/// Returns a session handle
///
/// Usage: (define session (nrepl-clone-session conn-id))
pub fn nrepl_clone_session(conn_id: ConnectionId) -> SteelNReplResult<NReplSession> {
    let session = registry::clone_session_blocking(conn_id)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    let session_id = registry::add_session(conn_id, session)
        .ok_or_else(|| steel_error(format!("Failed to add session to connection {}", conn_id)))?;

    Ok(NReplSession {
        conn_id,
        session_id,
    })
}

/// Interrupt an ongoing evaluation
///
/// Sends an interrupt request to cancel a long-running evaluation. Takes the nREPL
/// message ID (not the steel-nrepl request ID) of the evaluation to interrupt.
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
    conn_id: ConnectionId,
    session_id: SessionId,
    interrupt_id: &str,
) -> SteelNReplResult<()> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    registry::interrupt_blocking(conn_id, session, interrupt_id.to_string())
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Close a session on the server
///
/// Explicitly closes a session on the nREPL server and removes it from the registry.
/// After closing, the session cannot be used for further evaluations.
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
pub fn nrepl_close_session(
    conn_id: ConnectionId,
    session_id: SessionId,
) -> SteelNReplResult<()> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    registry::close_session_blocking(conn_id, session)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Send stdin data to a session
///
/// Sends input data to a session for interactive programs that read from stdin.
/// This is useful for programs that call `read-line` or similar input functions.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `data` - The stdin data to send
///
/// Usage: (nrepl-stdin conn-id session-id "user input\n")
pub fn nrepl_stdin(
    conn_id: ConnectionId,
    session_id: SessionId,
    data: &str,
) -> SteelNReplResult<()> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    registry::stdin_blocking(conn_id, session, data.to_string())
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Get code completions for a prefix
///
/// Returns a list of completion suggestions for the given prefix.
/// Useful for implementing autocomplete in editors.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `prefix` - The code prefix to complete (e.g., "ma" might suggest "map", "mapv", etc.)
/// * `ns` - Optional namespace to complete in (e.g., Some("clojure.core"))
/// * `complete_fn` - Optional custom completion function name
///
/// Returns: Steel list string like "(list \"map\" \"mapv\" \"mapcat\")"
///
/// Usage: (nrepl-completions conn-id session-id "ma" #f #f)
pub fn nrepl_completions(
    conn_id: ConnectionId,
    session_id: SessionId,
    prefix: &str,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> SteelNReplResult<String> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    let completions = registry::completions_blocking(conn_id, session, prefix.to_string(), ns, complete_fn)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    // Format as Steel list: (list "item1" "item2" ...)
    let completion_items: Vec<String> = completions
        .iter()
        .map(|s| format!("\"{}\"", escape_steel_string(s)))
        .collect();

    Ok(format!("(list {})", completion_items.join(" ")))
}

/// Lookup information about a symbol
///
/// Returns documentation and metadata for a symbol.
/// Useful for "go to definition", inline docs, and symbol information features.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `sym` - The symbol to look up (e.g., "map", "clojure.core/reduce")
/// * `ns` - Optional namespace context
/// * `lookup_fn` - Optional custom lookup function name
///
/// Returns: Steel hashmap string with symbol information
///
/// Usage: (nrepl-lookup conn-id session-id "map" #f #f)
pub fn nrepl_lookup(
    conn_id: ConnectionId,
    session_id: SessionId,
    sym: &str,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> SteelNReplResult<String> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    let response = registry::lookup_blocking(conn_id, session, sym.to_string(), ns, lookup_fn)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
        .map_err(nrepl_error_to_steel)?;

    // Convert Response.info (BTreeMap<String, String>) to Steel hashmap
    // The info field contains the symbol information from the lookup operation
    let mut parts = Vec::new();

    if let Some(info) = response.info {
        for (key, value) in info.iter() {
            // Convert key to Steel keyword syntax (using #: prefix)
            let key_escaped = escape_steel_string(key);
            let value_escaped = escape_steel_string(value);
            parts.push(format!("'#{} \"{}\"", key_escaped, value_escaped));
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
        .map(|c| format!("(hash 'id {} 'sessions {})", c.connection_id, c.session_count))
        .collect();

    parts.push(format!("'connections (list {})", conn_details.join(" ")));

    format!("(hash {})", parts.join(" "))
}

/// Close an nREPL connection
///
/// This properly closes all sessions on the server, then closes the TCP connection
/// and removes all associated sessions from the registry.
///
/// **You must call this** for every connection created with `nrepl-connect`
/// to avoid resource leaks.
///
/// # Returns
/// Returns Ok with an optional warning string. If Some(warnings), the warnings contain
/// information about sessions that failed to close properly. The connection is still
/// removed from the registry even if individual sessions fail to close.
///
/// # Errors
/// Returns an error if the connection ID is not found (already closed or never existed).
///
/// Usage: (nrepl-close conn-id)
/// Returns: #f if no warnings, or a string with warning messages
pub fn nrepl_close(conn_id: ConnectionId) -> SteelNReplResult<Option<String>> {
    // First, get all sessions for this connection
    let sessions = registry::get_all_sessions(conn_id)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?;

    // Close each session on the server via worker thread
    // We collect errors but don't fail on the first one - we want to close all sessions
    let mut close_errors = Vec::new();
    for session in sessions {
        if let Some(Err(e)) = registry::close_session_blocking(conn_id, session) {
            // Collect error but continue closing other sessions
            close_errors.push(format!("Failed to close session: {}", e));
        }
    }

    // Now remove the connection from the registry (closes TCP connection and shuts down worker)
    if !registry::remove_connection(conn_id) {
        return Err(steel_error(format!("Connection {} not found", conn_id)));
    }

    // If there were errors closing sessions, return them as warnings
    if !close_errors.is_empty() {
        let warning = format!(
            "Warnings while closing connection {}:\n  - {}",
            conn_id,
            close_errors.join("\n  - ")
        );
        Ok(Some(warning))
    } else {
        Ok(None)
    }
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
        assert!(hashmap.contains("'output (list"), "Should contain output list");
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
        assert!(hashmap.contains("'output (list"), "Should contain output list");
        assert!(hashmap.contains(r#"hello\n"#), "Should contain first output with escaped newline");
        assert!(hashmap.contains(r#"world\n"#), "Should contain second output with escaped newline");
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
        assert!(hashmap.contains("'error \"Syntax error\\nLine 42\""), "Should contain joined errors");
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

        assert!(hashmap.contains("'error #f"), "Empty error list should be #f");
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
}
