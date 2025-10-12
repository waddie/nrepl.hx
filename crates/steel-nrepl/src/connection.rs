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
use lazy_static::lazy_static;
use nrepl_rs::{EvalResult, NReplClient};
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

    // Add 'error
    let error_str = match &result.error {
        Some(e) => format!("\"{}\"", escape_steel_string(e)),
        None => "#f".to_string(),
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
    /// Evaluate code in this session with default timeout (5 seconds)
    /// Returns a Steel hash construction call as a string
    ///
    /// Format: (hash 'value "..." 'output (list "...") 'error "..." 'ns "...")
    ///
    /// Usage: (nrepl-eval session "(+ 1 2)")
    pub fn eval(&mut self, code: &str) -> SteelNReplResult<String> {
        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
            ))
        })?;

        let result = registry::get_connection_mut(self.conn_id, |client| {
            RUNTIME.block_on(client.eval(&session, code.to_string()))
        })
        .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?
        .map_err(nrepl_error_to_steel)?;

        // Return as Steel hashmap
        Ok(eval_result_to_steel_hashmap(&result))
    }

    /// Evaluate code in this session with custom timeout
    /// Returns a Steel hash construction call as a string
    ///
    /// Format: (hash 'value "..." 'output (list "...") 'error "..." 'ns "...")
    ///
    /// The timeout is specified in milliseconds. If the evaluation takes longer
    /// than the timeout, an error is returned.
    ///
    /// Usage: (nrepl-eval-with-timeout session "(+ 1 2)" 5000)
    pub fn eval_with_timeout(&mut self, code: &str, timeout_ms: usize) -> SteelNReplResult<String> {
        let session = registry::get_session(self.conn_id, self.session_id).ok_or_else(|| {
            steel_error(format!(
                "Session {} not found in connection {}",
                self.session_id, self.conn_id
            ))
        })?;

        let timeout_duration = Duration::from_millis(timeout_ms as u64);

        let result = registry::get_connection_mut(self.conn_id, |client| {
            RUNTIME.block_on(client.eval_with_timeout(&session, code.to_string(), timeout_duration))
        })
        .ok_or_else(|| steel_error(format!("Connection {} not found", self.conn_id)))?
        .map_err(nrepl_error_to_steel)?;

        // Return as Steel hashmap
        Ok(eval_result_to_steel_hashmap(&result))
    }
}

lazy_static! {
    /// Shared tokio runtime for all nREPL operations
    /// This avoids creating/destroying a runtime on every FFI call
    static ref RUNTIME: tokio::runtime::Runtime = {
        tokio::runtime::Runtime::new()
            .expect("Failed to create tokio runtime for steel-nrepl")
    };
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
    let client = RUNTIME
        .block_on(NReplClient::connect(&address))
        .map_err(nrepl_error_to_steel)?;

    let conn_id = registry::add_connection(client);
    Ok(conn_id)
}

/// Clone a new session from a connection
/// Returns a session handle
///
/// Usage: (define session (nrepl-clone-session conn-id))
pub fn nrepl_clone_session(conn_id: ConnectionId) -> SteelNReplResult<NReplSession> {
    let session =
        registry::get_connection_mut(conn_id, |client| RUNTIME.block_on(client.clone_session()))
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
/// This closes the TCP connection and removes all associated sessions.
/// **You must call this** for every connection created with `nrepl-connect`
/// to avoid resource leaks.
///
/// # Errors
/// Returns an error if the connection ID is not found (already closed or never existed).
///
/// Usage: (nrepl-close conn-id)
pub fn nrepl_close(conn_id: ConnectionId) -> SteelNReplResult<()> {
    if registry::remove_connection(conn_id) {
        Ok(())
    } else {
        Err(steel_error(format!("Connection {} not found", conn_id)))
    }
}
