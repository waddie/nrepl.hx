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

/// Convert nrepl_rs::NReplError to SteelErr
///
/// Preserves error type information with helpful context messages for debugging.
pub fn nrepl_error_to_steel(err: nrepl_rs::NReplError) -> SteelErr {
    use nrepl_rs::NReplError;

    match err {
        NReplError::Timeout {
            operation,
            duration,
        } => SteelErr::new(
            ErrorKind::Generic,
            format!("Operation '{}' timed out after {:?}", operation, duration),
        ),
        NReplError::SessionNotFound(id) => SteelErr::new(
            ErrorKind::Generic,
            format!(
                "Session not found: {}. It may have been closed or never existed.",
                id
            ),
        ),
        NReplError::Connection(e) => SteelErr::new(
            ErrorKind::Generic,
            format!(
                "Connection error: {}. Check if nREPL server is running and accessible.",
                e
            ),
        ),
        NReplError::Codec {
            message, position, ..
        } => SteelErr::new(
            ErrorKind::Generic,
            format!(
                "Message decoding error at byte {}: {}. The server may have sent malformed data.",
                position, message
            ),
        ),
        NReplError::Protocol { message, .. } => SteelErr::new(
            ErrorKind::Generic,
            format!(
                "Protocol error: {}. The server response was unexpected.",
                message
            ),
        ),
        NReplError::OperationFailed(msg) => {
            SteelErr::new(ErrorKind::Generic, format!("Operation failed: {}", msg))
        }
    }
}

/// Create a generic Steel error
pub fn steel_error(message: String) -> SteelErr {
    SteelErr::new(ErrorKind::Generic, message)
}
