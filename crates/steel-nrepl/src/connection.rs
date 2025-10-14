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
        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
            ))
        })?;

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(self.conn_id, session, code.to_string(), None)
            .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?;

        Ok(request_id)
    }

    /// Submit an eval request with custom timeout (non-blocking, returns request ID immediately)
    ///
    /// Usage: (define req-id (nrepl-eval-with-timeout session "(+ 1 2)" 5000))
    pub fn eval_with_timeout(&mut self, code: &str, timeout_ms: usize) -> SteelNReplResult<usize> {
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
        .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?;

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

/// Close an nREPL connection
///
/// This properly closes all sessions on the server, then closes the TCP connection
/// and removes all associated sessions from the registry.
///
/// **You must call this** for every connection created with `nrepl-connect`
/// to avoid resource leaks.
///
/// # Errors
/// Returns an error if the connection ID is not found (already closed or never existed).
/// If closing a session fails, it logs the error but continues to close remaining sessions.
///
/// Usage: (nrepl-close conn-id)
pub fn nrepl_close(conn_id: ConnectionId) -> SteelNReplResult<()> {
    // First, get all sessions for this connection
    let sessions = registry::get_all_sessions(conn_id)
        .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?;

    // Close each session on the server via worker thread
    // We collect errors but don't fail on the first one - we want to close all sessions
    let mut close_errors = Vec::new();
    for session in sessions {
        if let Some(Err(e)) = registry::close_session_blocking(conn_id, session) {
            // Log error but continue closing other sessions
            close_errors.push(format!("Failed to close session: {}", e));
        }
    }

    // Now remove the connection from the registry (closes TCP connection and shuts down worker)
    if !registry::remove_connection(conn_id) {
        return Err(steel_error(format!("Connection {} not found", conn_id)));
    }

    // If there were errors closing sessions, report them
    if !close_errors.is_empty() {
        eprintln!("Warnings while closing connection {}:", conn_id);
        for error in &close_errors {
            eprintln!("  - {}", error);
        }
    }

    Ok(())
}
