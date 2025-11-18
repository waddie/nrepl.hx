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
/// - Strings: `<length>:<string>` (e.g., "4:spam")
/// - Integers: `i<number>e` (e.g., "i42e")
/// - Lists: `l<items>e` (e.g., "l4:spam4:eggse")
/// - Dictionaries: `d<key><value>...e` (e.g., "d3:cow3:moo4:spam4:eggse")
use crate::error::{NReplError, Result};
use crate::message::{Request, Response};

/// Maximum allowed length for a single bencode string (100MB)
/// This prevents malicious servers from causing OOM by sending extremely large length values
const MAX_STRING_LENGTH: usize = 100 * 1024 * 1024;

pub fn encode_request(request: &Request) -> Result<Vec<u8>> {
    serde_bencode::to_bytes(request).map_err(|e| NReplError::codec(e.to_string(), 0))
}

/// Find the end position of a bencode message
/// Returns the number of bytes consumed by one complete bencode value
fn find_bencode_end(data: &[u8], start: usize) -> Result<usize> {
    let mut pos = start;

    if pos >= data.len() {
        return Err(NReplError::codec_with_preview(
            "Incomplete bencode message",
            pos,
            data,
        ));
    }

    match data[pos] {
        b'i' => {
            // Integer: i<number>e
            pos += 1;
            while pos < data.len() && data[pos] != b'e' {
                pos += 1;
            }
            if pos >= data.len() {
                return Err(NReplError::codec_with_preview(
                    "Incomplete integer",
                    pos,
                    data,
                ));
            }
            pos += 1; // Skip 'e'
            Ok(pos)
        }
        b'l' => {
            // List: l<items>e
            pos += 1;
            while pos < data.len() && data[pos] != b'e' {
                pos = find_bencode_end(data, pos)?;
            }
            if pos >= data.len() {
                return Err(NReplError::codec_with_preview("Incomplete list", pos, data));
            }
            pos += 1; // Skip 'e'
            Ok(pos)
        }
        b'd' => {
            // Dict: d<key><value>...e
            pos += 1;
            while pos < data.len() && data[pos] != b'e' {
                pos = find_bencode_end(data, pos)?; // key
                pos = find_bencode_end(data, pos)?; // value
            }
            if pos >= data.len() {
                return Err(NReplError::codec_with_preview("Incomplete dict", pos, data));
            }
            pos += 1; // Skip 'e'
            Ok(pos)
        }
        b'0'..=b'9' => {
            // String: <length>:<data>
            let mut len_str = Vec::new();
            while pos < data.len() && data[pos] != b':' {
                len_str.push(data[pos]);
                pos += 1;
            }
            if pos >= data.len() {
                return Err(NReplError::codec_with_preview(
                    "Incomplete string length",
                    pos,
                    data,
                ));
            }
            pos += 1; // Skip ':'

            let len = std::str::from_utf8(&len_str)
                .map_err(|_| NReplError::codec("Invalid string length encoding", pos))?
                .parse::<usize>()
                .map_err(|_| NReplError::codec("Invalid string length value", pos))?;

            // Check maximum string length to prevent OOM from malicious servers
            if len > MAX_STRING_LENGTH {
                return Err(NReplError::codec(
                    format!(
                        "String length {} exceeds maximum allowed size of {} bytes ({} MB)",
                        len,
                        MAX_STRING_LENGTH,
                        MAX_STRING_LENGTH / (1024 * 1024)
                    ),
                    pos,
                ));
            }

            // Validate length before consuming bytes to prevent:
            // 1. Integer overflow when adding len to pos
            // 2. Out-of-bounds access attempts
            let end_pos = pos.checked_add(len).ok_or_else(|| {
                NReplError::codec(
                    format!(
                        "String length {} would cause integer overflow at position {}",
                        len, pos
                    ),
                    pos,
                )
            })?;

            if end_pos > data.len() {
                return Err(NReplError::codec_with_preview(
                    format!(
                        "Incomplete string data: claims length {} but only {} bytes available",
                        len,
                        data.len() - pos
                    ),
                    pos,
                    data,
                ));
            }

            Ok(end_pos)
        }
        _ => Err(NReplError::codec_with_preview(
            format!("Invalid bencode byte: 0x{:02x}", data[pos]),
            pos,
            data,
        )),
    }
}

/// Decode a response from bencode data
/// Returns the response and the number of bytes consumed
pub fn decode_response(data: &[u8]) -> Result<(Response, usize)> {
    // First find where the message ends
    let msg_len = find_bencode_end(data, 0)?;

    // Decode just that portion
    let response: Response = serde_bencode::from_bytes(&data[..msg_len])
        .map_err(|e| NReplError::codec_with_preview(e.to_string(), 0, &data[..msg_len]))?;

    Ok((response, msg_len))
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
            line: None,
            column: None,
            file: None,
            file_path: None,
            file_name: None,
            interrupt_id: None,
            stdin: None,
            verbose: None,
            prefix: None,
            complete_fn: None,
            ns: None,
            options: None,
            sym: None,
            lookup_fn: None,
            middleware: None,
            extra_namespaces: None,
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
            line: None,
            column: None,
            file: None,
            file_path: None,
            file_name: None,
            interrupt_id: None,
            stdin: None,
            verbose: None,
            prefix: None,
            complete_fn: None,
            ns: None,
            options: None,
            sym: None,
            lookup_fn: None,
            middleware: None,
            extra_namespaces: None,
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

        let (response, consumed) = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.session, "session-456");
        assert_eq!(response.status, vec!["done"]);
        assert_eq!(consumed, bencode.len());
    }

    #[test]
    fn test_decode_eval_response_with_value() {
        // Response with value: {"id": "msg-1", "session": "s1", "status": ["done"], "value": "3"}
        let bencode = b"d2:id5:msg-17:session2:s16:statusl4:donee5:value1:3e";

        let (response, consumed) = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.value, Some("3".to_string()));
        assert!(response.status.contains(&"done".to_string()));
        assert_eq!(consumed, bencode.len());
    }

    #[test]
    fn test_roundtrip_request() {
        let request = Request {
            op: "eval".to_string(),
            id: "test-id".to_string(),
            session: Some("test-session".to_string()),
            code: Some("(println \"hello\")".to_string()),
            line: None,
            column: None,
            file: None,
            file_path: None,
            file_name: None,
            interrupt_id: None,
            stdin: None,
            verbose: None,
            prefix: None,
            complete_fn: None,
            ns: None,
            options: None,
            sym: None,
            lookup_fn: None,
            middleware: None,
            extra_namespaces: None,
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

        let (response, consumed) = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.err, Some("Division by zero".to_string()));
        assert!(response.status.contains(&"error".to_string()));
        assert_eq!(consumed, bencode.len());
    }

    #[test]
    fn test_decode_response_with_output() {
        // Response with stdout: {"id": "msg-1", "out": "Hello\n", "status": []}
        let bencode = b"d2:id5:msg-13:out6:Hello\n6:statuslee";

        let (response, consumed) = decode_response(bencode).expect("decoding failed");

        assert_eq!(response.id, "msg-1");
        assert_eq!(response.out, Some("Hello\n".to_string()));
        assert_eq!(consumed, bencode.len());
    }

    #[test]
    fn test_decode_multiple_messages() {
        // Two messages concatenated
        let msg1 = b"d2:id5:msg-16:statusl4:doneee";
        let msg2 = b"d2:id5:msg-26:statusl4:doneee";
        let mut combined = Vec::new();
        combined.extend_from_slice(msg1);
        combined.extend_from_slice(msg2);

        // Decode first message
        let (response1, consumed1) =
            decode_response(&combined).expect("decoding first message failed");
        assert_eq!(response1.id, "msg-1");
        assert_eq!(consumed1, msg1.len());

        // Decode second message
        let (response2, consumed2) =
            decode_response(&combined[consumed1..]).expect("decoding second message failed");
        assert_eq!(response2.id, "msg-2");
        assert_eq!(consumed2, msg2.len());
    }
}
