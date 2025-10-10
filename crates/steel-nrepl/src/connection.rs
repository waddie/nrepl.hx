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

use crate::error::SteelNReplResult;
/// Connection management for Steel FFI
use steel::rvals::SteelVal;
use steel::steel_vm::register_fn::RegisterFn;

pub type ConnectionId = usize;

/// Connect to an nREPL server
/// Returns a connection ID
#[steel::steel_vm::register_fn]
pub fn nrepl_connect(host: String, port: u16) -> SteelNReplResult<ConnectionId> {
    // TODO: Implement connection
    todo!("Implement nrepl_connect")
}

/// Close an nREPL connection
#[steel::steel_vm::register_fn]
pub fn nrepl_close(conn_id: ConnectionId) -> SteelNReplResult<()> {
    // TODO: Implement close
    todo!("Implement nrepl_close")
}

/// Evaluate code asynchronously with callback
#[steel::steel_vm::register_fn]
pub fn nrepl_eval(conn_id: ConnectionId, code: String, callback: SteelVal) -> SteelNReplResult<()> {
    // TODO: Implement eval with callback
    todo!("Implement nrepl_eval")
}

/// Load file asynchronously with callback
#[steel::steel_vm::register_fn]
pub fn nrepl_load_file(
    conn_id: ConnectionId,
    path: String,
    callback: SteelVal,
) -> SteelNReplResult<()> {
    // TODO: Implement load-file with callback
    todo!("Implement nrepl_load_file")
}

/// Interrupt ongoing evaluation
#[steel::steel_vm::register_fn]
pub fn nrepl_interrupt(conn_id: ConnectionId) -> SteelNReplResult<()> {
    // TODO: Implement interrupt
    todo!("Implement nrepl_interrupt")
}
