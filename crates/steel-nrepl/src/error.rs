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

//! Error handling for Steel FFI

use steel::SteelErr;
use steel::rerrs::ErrorKind;

pub type SteelNReplResult<T> = Result<T, SteelErr>;

/// Convert `nrepl_rs::NReplError` to `SteelErr`
///
/// Every variant maps to `ErrorKind::Generic` (Steel has no richer kind that
/// fits), so the only thing that varies is the message: the error itself plus
/// the advice that tells a user what to do about it.
///
/// The message text is load-bearing. It reaches the Scheme side and ends up in
/// the `*nrepl*` buffer, so the wording here is behaviour, not decoration. Note
/// that these are deliberately not `{err}`-derived: `NReplError`'s own Display
/// text differs for Timeout, Codec and Protocol.
#[must_use]
pub fn nrepl_error_to_steel(err: nrepl_rs::NReplError) -> SteelErr {
    use nrepl_rs::NReplError;

    let message = match err {
        NReplError::Timeout {
            operation,
            duration,
        } => format!("Operation '{operation}' timed out after {duration:?}"),
        NReplError::SessionNotFound(id) => {
            format!("Session not found: {id}. It may have been closed or never existed.")
        }
        NReplError::Connection(e) => {
            format!("Connection error: {e}. Check if nREPL server is running and accessible.")
        }
        NReplError::Codec {
            message, position, ..
        } => format!(
            "Message decoding error at byte {position}: {message}. The server may have sent malformed data."
        ),
        NReplError::Protocol { message, .. } => {
            format!("Protocol error: {message}. The server response was unexpected.")
        }
        NReplError::OperationFailed(msg) => format!("Operation failed: {msg}"),
    };

    steel_error(message)
}

/// Create a generic Steel error
#[must_use]
pub fn steel_error(message: String) -> SteelErr {
    SteelErr::new(ErrorKind::Generic, message)
}
