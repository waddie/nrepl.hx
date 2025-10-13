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

pub type Result<T> = std::result::Result<T, NReplError>;

#[derive(Debug)]
pub enum NReplError {
    Connection(std::io::Error),

    Codec {
        message: String,
        position: usize,
        buffer_preview: Option<String>,
    },

    Protocol {
        message: String,
        response: Option<String>,
    },

    SessionNotFound(String),

    OperationFailed(String),

    Timeout { operation: String, duration: Duration },
}

// Implement From for std::io::Error
impl From<std::io::Error> for NReplError {
    fn from(error: std::io::Error) -> Self {
        NReplError::Connection(error)
    }
}

// Implement std::error::Error trait
impl std::error::Error for NReplError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            NReplError::Connection(e) => Some(e),
            _ => None,
        }
    }
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

// Custom Display implementation to handle optional context
impl std::fmt::Display for NReplError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connection(e) => write!(f, "Connection error: {}", e),
            Self::Codec {
                message,
                position,
                buffer_preview,
            } => {
                write!(f, "Codec error at byte {}: {}", position, message)?;
                if let Some(preview) = buffer_preview {
                    write!(f, "{}", preview)?;
                }
                Ok(())
            }
            Self::Protocol { message, response } => {
                write!(f, "Protocol error: {}", message)?;
                if let Some(resp) = response {
                    write!(f, "{}", resp)?;
                }
                Ok(())
            }
            Self::SessionNotFound(id) => write!(f, "Session not found: {}", id),
            Self::OperationFailed(msg) => write!(f, "Operation failed: {}", msg),
            Self::Timeout {
                operation,
                duration,
            } => write!(f, "Timeout after {:?} while {}", duration, operation),
        }
    }
}
