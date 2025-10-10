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

/// Bencode codec for nREPL messages
///
/// This module handles encoding and decoding of nREPL messages using bencode format.

use crate::error::{NReplError, Result};
use crate::message::{Request, Response};

pub fn encode_request(request: &Request) -> Result<Vec<u8>> {
    serde_bencode::to_bytes(request)
        .map_err(|e| NReplError::Codec(e.to_string()))
}

pub fn decode_response(data: &[u8]) -> Result<Response> {
    serde_bencode::from_bytes(data)
        .map_err(|e| NReplError::Codec(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode_roundtrip() {
        // TODO: Implement roundtrip test
    }
}
