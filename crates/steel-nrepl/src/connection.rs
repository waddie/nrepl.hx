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
use nrepl_rs::NReplClient;
use steel::SteelVal;
use std::time::Duration;

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
/// Returns a session ID
///
/// Usage: (nrepl-clone-session conn-id)
pub fn nrepl_clone_session(conn_id: ConnectionId) -> SteelNReplResult<SessionId> {
    let session =
        registry::get_connection_mut(conn_id, |client| RUNTIME.block_on(client.clone_session()))
            .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
            .map_err(nrepl_error_to_steel)?;

    let session_id = registry::add_session(conn_id, session)
        .ok_or_else(|| steel_error(format!("Failed to add session to connection {}", conn_id)))?;

    Ok(session_id)
}

/// Evaluate code in a session with default timeout (60 seconds)
/// Returns a hashmap with :value, :output, :error, :ns
///
/// Usage: (nrepl-eval conn-id session-id "(+ 1 2)")
pub fn nrepl_eval(
    conn_id: ConnectionId,
    session_id: SessionId,
    code: String,
) -> SteelNReplResult<SteelVal> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    let result = registry::get_connection_mut(conn_id, |client| {
        RUNTIME.block_on(client.eval(&session, code))
    })
    .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
    .map_err(nrepl_error_to_steel)?;

    // Convert to Steel hashmap
    crate::callback::result_to_steel_val(result)
}

/// Evaluate code in a session with custom timeout
/// Returns a hashmap with :value, :output, :error, :ns
///
/// The timeout is specified in milliseconds. If the evaluation takes longer
/// than the timeout, an error is returned.
///
/// Usage: (nrepl-eval-with-timeout conn-id session-id "(+ 1 2)" 5000)
pub fn nrepl_eval_with_timeout(
    conn_id: ConnectionId,
    session_id: SessionId,
    code: String,
    timeout_ms: u64,
) -> SteelNReplResult<SteelVal> {
    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    let timeout_duration = Duration::from_millis(timeout_ms);

    let result = registry::get_connection_mut(conn_id, |client| {
        RUNTIME.block_on(client.eval_with_timeout(&session, code, timeout_duration))
    })
    .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
    .map_err(nrepl_error_to_steel)?;

    // Convert to Steel hashmap
    crate::callback::result_to_steel_val(result)
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
