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

use crate::error::{nrepl_error_to_steel, steel_error, SteelNReplResult};
use crate::registry::{self, ConnectionId, SessionId};
use nrepl_rs::NReplClient;
use steel::SteelVal;

/// Connect to an nREPL server
/// Returns a connection ID
///
/// Usage: (nrepl-connect "localhost:7888")
pub fn nrepl_connect(address: String) -> SteelNReplResult<ConnectionId> {
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|e| steel_error(format!("Failed to create runtime: {}", e)))?;

    let client = runtime
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
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|e| steel_error(format!("Failed to create runtime: {}", e)))?;

    let session = registry::get_connection_mut(conn_id, |client| {
        runtime.block_on(client.clone_session())
    })
    .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
    .map_err(nrepl_error_to_steel)?;

    let session_id = registry::add_session(conn_id, session)
        .ok_or_else(|| steel_error(format!("Failed to add session to connection {}", conn_id)))?;

    Ok(session_id)
}

/// Evaluate code in a session
/// Returns a hashmap with :value, :output, :error, :ns
///
/// Usage: (nrepl-eval conn-id session-id "(+ 1 2)")
pub fn nrepl_eval(
    conn_id: ConnectionId,
    session_id: SessionId,
    code: String,
) -> SteelNReplResult<SteelVal> {
    let runtime = tokio::runtime::Runtime::new()
        .map_err(|e| steel_error(format!("Failed to create runtime: {}", e)))?;

    let session = registry::get_session(conn_id, session_id).ok_or_else(|| {
        steel_error(format!(
            "Session {} not found in connection {}",
            session_id, conn_id
        ))
    })?;

    let result = registry::get_connection_mut(conn_id, |client| {
        runtime.block_on(client.eval(&session, code))
    })
    .ok_or_else(|| steel_error(format!("Connection {} not found", conn_id)))?
    .map_err(nrepl_error_to_steel)?;

    // Convert to Steel hashmap
    crate::callback::result_to_steel_val(result)
}

/// Close an nREPL connection
///
/// Usage: (nrepl-close conn-id)
pub fn nrepl_close(conn_id: ConnectionId) -> SteelNReplResult<()> {
    if registry::remove_connection(conn_id) {
        Ok(())
    } else {
        Err(steel_error(format!("Connection {} not found", conn_id)))
    }
}
