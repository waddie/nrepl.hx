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
///
/// Bencode format:
/// - Strings: <length>:<string> (e.g., "4:spam")
/// - Integers: i<number>e (e.g., "i42e")
/// - Lists: l<items>e (e.g., "l4:spam4:eggse")
/// - Dictionaries: d<key><value>...e (e.g., "d3:cow3:moo4:spam4:eggse")

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
    fn test_encode_simple_request() {
        let request = Request {
            op: "clone".to_string(),
            id: "1".to_string(),
            session: None,
            code: None,
            file: None,
        };

        let encoded = encode_request(&request).expect("encoding failed");

        // Bencode should contain the op and id
        let encoded_str = String::from_utf8_lossy(&encoded);
        assert!(encoded_str.contains("clone"));
        assert!(encoded_str.contains("1"));
    }

    #[test]
    fn test_encode_eval_request() {
        let request = Request {
            op: "eval".to_string(),
            id: "msg-123".to_string(),
            session: Some("session-456".to_string()),
            code: Some("(+ 1 2)".to_string()),
            file: None,
        };

        let encoded = encode_request(&request).expect("encoding failed");
        let encoded_str = String::from_utf8_lossy(&encoded);

        assert!(encoded_str.contains("eval"));
        assert!(encoded_str.contains("msg-123"));
        assert!(encoded_str.contains("session-456"));
        assert!(encoded_str.contains("(+ 1 2)"));
    }

    #[test]
    fn test_decode_response() {
        // Minimal bencode response: d2:id5:msg-17:session11:session-4566:statusl4:doneee
        // This represents: {"id": "msg-1", "session": "session-456", "status": ["done"]}
        let bencode = b"d2:id5:msg-17:session11:session-4566:statusl4:doneee";

        let response = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.session, "session-456");
        assert_eq!(response.status, vec!["done"]);
    }

    #[test]
    fn test_decode_eval_response_with_value() {
        // Response with value: {"id": "msg-1", "session": "s1", "status": ["done"], "value": "3"}
        let bencode = b"d2:id5:msg-17:session2:s16:statusl4:donee5:value1:3e";

        let response = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.value, Some("3".to_string()));
        assert!(response.status.contains(&"done".to_string()));
    }

    #[test]
    fn test_roundtrip_request() {
        let request = Request {
            op: "eval".to_string(),
            id: "test-id".to_string(),
            session: Some("test-session".to_string()),
            code: Some("(println \"hello\")".to_string()),
            file: None,
        };

        let encoded = encode_request(&request).expect("encoding failed");

        // We can't directly roundtrip because Request and Response are different types
        // But we can verify the encoding is valid bencode
        assert!(!encoded.is_empty());
        assert!(encoded[0] == b'd'); // Should start with dictionary marker
    }

    #[test]
    fn test_decode_error_response() {
        // Response with error: {"id": "msg-1", "status": ["error"], "err": "Division by zero"}
        let bencode = b"d2:id5:msg-13:err16:Division by zero6:statusl5:erroree";

        let response = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.err, Some("Division by zero".to_string()));
        assert!(response.status.contains(&"error".to_string()));
    }

    #[test]
    fn test_decode_response_with_output() {
        // Response with stdout: {"id": "msg-1", "out": "Hello\n", "status": []}
        let bencode = b"d2:id5:msg-13:out6:Hello\n6:statuslee";

        let response = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.out, Some("Hello\n".to_string()));
    }
}
