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

use std::time::Duration;
use thiserror::Error;

pub type Result<T> = std::result::Result<T, NReplError>;

#[derive(Debug, Error)]
pub enum NReplError {
    #[error("Connection error: {0}")]
    Connection(#[from] std::io::Error),

    #[error("Codec error at byte {position}: {message}{}", buffer_preview.as_deref().unwrap_or(""))]
    Codec {
        message: String,
        position: usize,
        buffer_preview: Option<String>,
    },

    #[error("Protocol error: {message}{}", response.as_deref().unwrap_or(""))]
    Protocol {
        message: String,
        response: Option<String>,
    },

    #[error("Session not found: {0}")]
    SessionNotFound(String),

    #[error("Operation failed: {0}")]
    OperationFailed(String),

    #[error("Timeout after {duration:?} while {operation}")]
    Timeout { operation: String, duration: Duration },
}

impl NReplError {
    /// Create a codec error with context
    pub fn codec(message: impl Into<String>, position: usize) -> Self {
        Self::Codec {
            message: message.into(),
            position,
            buffer_preview: None,
        }
    }

    /// Create a codec error with buffer preview for debugging
    pub fn codec_with_preview(
        message: impl Into<String>,
        position: usize,
        buffer: &[u8],
    ) -> Self {
        let preview_len = buffer.len().min(100);
        let hex_preview = buffer[..preview_len]
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect::<Vec<_>>()
            .join(" ");

        Self::Codec {
            message: message.into(),
            position,
            buffer_preview: Some(format!(" (buffer preview: {})", hex_preview)),
        }
    }

    /// Create a protocol error with optional response context
    pub fn protocol(message: impl Into<String>) -> Self {
        Self::Protocol {
            message: message.into(),
            response: None,
        }
    }

    /// Create a protocol error with response data for debugging
    pub fn protocol_with_response(message: impl Into<String>, response: impl Into<String>) -> Self {
        Self::Protocol {
            message: message.into(),
            response: Some(format!(" (response: {})", response.into())),
        }
    }
}
