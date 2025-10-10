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

use thiserror::Error;

pub type Result<T> = std::result::Result<T, NReplError>;

#[derive(Debug, Error)]
pub enum NReplError {
    #[error("Connection error: {0}")]
    Connection(#[from] std::io::Error),

    #[error("Codec error: {0}")]
    Codec(String),

    #[error("Protocol error: {0}")]
    Protocol(String),

    #[error("Session not found: {0}")]
    SessionNotFound(String),

    #[error("Operation failed: {0}")]
    OperationFailed(String),
}
