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
use crate::message::{BencodeValue, Request, Response, response_from_bencode};

/// Maximum allowed length for a single bencode string (10MB)
/// This prevents malicious servers from causing OOM by sending extremely large length values.
/// Matches `MAX_RESPONSE_SIZE` in connection.rs: the read loop caps its buffer there before
/// decoding, so a string can never legitimately exceed the response it arrives in.
const MAX_STRING_LENGTH: usize = 10 * 1024 * 1024;

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
                // Tolerate a non-conforming server that emits a key with no
                // value (guile-ares-rs does this for stack frames with no source
                // location: `...6:sourceed...` — the `source` key is followed
                // straight by the dict-terminating `e`). Strictly this is invalid
                // bencode, but if we treated it as truncation we'd report the
                // whole message `Incomplete` forever and wedge the reader. Closing
                // the dict here keeps framing aligned so the message can be skipped
                // (or salvaged) and later messages still decode.
                if pos < data.len() && data[pos] == b'e' {
                    break;
                }
                pos = find_bencode_end(data, pos)?; // value
            }
            if pos >= data.len() {
                return Err(NReplError::codec_with_preview("Incomplete dict", pos, data));
            }
            pos += 1; // Skip 'e'
            Ok(pos)
        }
        b'0'..=b'9' => find_string_end(data, pos),
        _ => Err(NReplError::codec_with_preview(
            format!("Invalid bencode byte: 0x{:02x}", data[pos]),
            pos,
            data,
        )),
    }
}

/// Find the end position of a bencode string (`<length>:<data>`) starting at `pos`.
fn find_string_end(data: &[u8], start: usize) -> Result<usize> {
    let mut pos = start;
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
            format!("String length {len} would cause integer overflow at position {pos}"),
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

/// Outcome of attempting to decode a single response from the head of `data`.
///
/// This distinguishes the two failure modes that the streaming reader must treat
/// very differently:
///
/// - [`Decoded::Incomplete`] - not enough bytes buffered yet; read more.
/// - [`Decoded::Malformed`] - a *structurally complete* bencode message that
///   nonetheless failed to deserialize into a [`Response`] (e.g. a non-conforming
///   server sent an unexpected value shape). Retrying is futile: the same bytes
///   will fail identically forever, stalling every later response queued behind
///   them. The caller should skip `consumed` bytes and move on.
pub enum Decoded {
    /// A complete, well-formed response and the number of bytes it consumed.
    Message {
        response: Box<Response>,
        consumed: usize,
    },
    /// A complete but undecodable message; skip `consumed` bytes.
    Malformed { consumed: usize, message: String },
    /// Not enough bytes buffered yet for a complete message.
    Incomplete,
}

/// Decode a single response from the head of `data`, classifying the result so
/// the reader can skip undecodable-but-complete messages instead of looping on
/// them. See [`Decoded`].
pub fn decode_one(data: &[u8]) -> Decoded {
    match find_bencode_end(data, 0) {
        Ok(consumed) => match serde_bencode::from_bytes::<Response>(&data[..consumed]) {
            Ok(response) => Decoded::Message {
                response: Box::new(response),
                consumed,
            },
            // Strict decode failed on a *complete* frame — usually because a
            // non-conforming server sent an unexpected value shape. Before giving
            // up on the message, try to salvage it with a tolerant value-tree
            // parse: if we can recover a routable response (one with an `id`), the
            // op awaiting it completes with whatever the server actually sent
            // instead of hanging until its timeout. Only when even the lenient
            // parse can't produce a routable response do we treat it as Malformed
            // and skip it.
            Err(e) => match parse_value(&data[..consumed], 0)
                .map(|(value, _)| value)
                .and_then(response_from_bencode)
            {
                Some(response) => Decoded::Message {
                    response: Box::new(response),
                    consumed,
                },
                None => Decoded::Malformed {
                    consumed,
                    message: e.to_string(),
                },
            },
        },
        // A structural error means the buffered bytes don't yet form a complete
        // message (or are not parseable as bencode framing); either way the
        // reader's recourse is to read more, so report Incomplete.
        Err(_) => Decoded::Incomplete,
    }
}

/// Tolerant recursive bencode parser producing a [`BencodeValue`] tree and the
/// end offset of the parsed value.
///
/// Unlike `serde_bencode`, this never rejects a message for a *type* reason: it
/// is used as the salvage path in [`decode_one`] for frames that strict decoding
/// refused. It mirrors the dangling-key tolerance of [`find_bencode_end`] so it
/// can walk past the same non-conforming dicts. `None` means the bytes ran out
/// mid-value (which should not happen on an already-framed slice, but is handled
/// defensively rather than panicking).
fn parse_value(data: &[u8], start: usize) -> Option<(BencodeValue, usize)> {
    let first = *data.get(start)?;
    match first {
        b'i' => {
            // Integer: i<number>e
            let mut pos = start + 1;
            while pos < data.len() && data[pos] != b'e' {
                pos += 1;
            }
            if pos >= data.len() {
                return None;
            }
            let num = std::str::from_utf8(&data[start + 1..pos])
                .ok()
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0);
            Some((BencodeValue::Int(num), pos + 1))
        }
        b'l' => {
            // List: l<items>e
            let mut pos = start + 1;
            let mut items = Vec::new();
            while pos < data.len() && data[pos] != b'e' {
                let (item, next) = parse_value(data, pos)?;
                items.push(item);
                pos = next;
            }
            if pos >= data.len() {
                return None;
            }
            Some((BencodeValue::List(items), pos + 1))
        }
        b'd' => {
            // Dict: d<key><value>...e
            let mut pos = start + 1;
            let mut map = std::collections::BTreeMap::new();
            while pos < data.len() && data[pos] != b'e' {
                let (key, after_key) = parse_value(data, pos)?;
                pos = after_key;
                // Dangling key with no value (see find_bencode_end): close the dict.
                if pos >= data.len() || data[pos] == b'e' {
                    break;
                }
                let (val, after_val) = parse_value(data, pos)?;
                pos = after_val;
                // A non-string key can't appear in conforming bencode; coerce it
                // to its string representation rather than dropping the entry.
                let key_str = match key {
                    BencodeValue::String(s) => s,
                    other => other.to_string_repr(),
                };
                map.insert(key_str, val);
            }
            if pos >= data.len() {
                return None;
            }
            Some((BencodeValue::Dict(map), pos + 1))
        }
        b'0'..=b'9' => {
            // String: <length>:<data>
            let mut pos = start;
            while pos < data.len() && data[pos] != b':' {
                pos += 1;
            }
            if pos >= data.len() {
                return None;
            }
            let len: usize = std::str::from_utf8(&data[start..pos]).ok()?.parse().ok()?;
            let data_start = pos + 1;
            let data_end = data_start.checked_add(len)?;
            if data_end > data.len() {
                return None;
            }
            let s = String::from_utf8_lossy(&data[data_start..data_end]).into_owned();
            Some((BencodeValue::String(s), data_end))
        }
        _ => None,
    }
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
        assert!(encoded_str.contains('1'));
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
    fn test_bencode_keys_are_sorted_on_serialize() {
        // Conformance #6: bencode dictionaries must emit keys in sorted (raw byte)
        // order. serde_bencode is expected to do this for us; this test pins that
        // behaviour so a dependency change can't silently break wire compliance.
        let request = Request {
            op: "eval".to_string(),
            id: "req-1".to_string(),
            session: Some("s1".to_string()),
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

        // The serialized dict contains keys code, id, op, session. Find each
        // key's position and assert they appear in ascending order.
        let keys = ["4:code", "2:id", "2:op", "7:session"];
        let mut last_pos = 0;
        for key in keys {
            let pos = encoded_str
                .find(key)
                .unwrap_or_else(|| panic!("key {key} missing from {encoded_str}"));
            assert!(
                pos >= last_pos,
                "key {key} at {pos} is out of sorted order in {encoded_str}"
            );
            last_pos = pos;
        }
    }

    #[test]
    fn test_decode_one_classifies_incomplete_complete_and_malformed() {
        // Complete, well-formed message decodes.
        let good = b"d2:id5:msg-16:statusl4:doneee";
        match decode_one(good) {
            Decoded::Message { response, consumed } => {
                assert_eq!(response.id, "msg-1");
                assert_eq!(consumed, good.len());
            }
            _ => panic!("expected Message"),
        }

        // Truncated message (missing trailing bytes) is Incomplete.
        let partial = &good[..good.len() - 3];
        assert!(matches!(decode_one(partial), Decoded::Incomplete));

        // Structurally complete bencode whose `id` is an integer (responses
        // require a string id) is a complete-but-undecodable message: it must be
        // reported as Malformed with the full consumed length, never Incomplete —
        // otherwise the reader loops on it forever.
        let bad = b"d2:idi7e6:statusl4:doneee";
        match decode_one(bad) {
            Decoded::Malformed { consumed, .. } => assert_eq!(consumed, bad.len()),
            other => panic!(
                "expected Malformed, got {}",
                match other {
                    Decoded::Message { .. } => "Message",
                    Decoded::Incomplete => "Incomplete",
                    Decoded::Malformed { .. } => unreachable!(),
                }
            ),
        }
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

    #[test]
    fn test_decode_one_accepts_list_shaped_ops() {
        // guile-ares-rs sends `describe`'s `ops` as a flat *list* of op-name
        // strings rather than a map. Strict serde decoding rejects that, which
        // used to drop the whole describe response and stall the connect. Verify
        // the salvage path recovers it with the op names as keys.
        let desc = b"d2:id1:23:opsl4:eval8:describe5:clonee6:statusl4:doneee";
        match decode_one(desc) {
            Decoded::Message { response, consumed } => {
                assert_eq!(consumed, desc.len());
                let ops = response.ops.expect("ops present");
                assert!(ops.contains_key("eval"));
                assert!(ops.contains_key("describe"));
                assert!(ops.contains_key("clone"));
                assert!(response.status.iter().any(|s| s == "done"));
            }
            _ => panic!("expected Message"),
        }
    }

    #[test]
    fn test_decode_one_salvages_guile_dangling_source_key() {
        // guile-ares-rs emits stack frames with a `source` key that has *no
        // value* (`...6:sourceed...`) when the frame has no source location.
        // That is invalid bencode: find_bencode_end used to error and decode_one
        // reported the message Incomplete, wedging the reader forever (every
        // later response queued behind it, so eval errors and all subsequent
        // evals timed out). The message must instead frame, be salvaged (keeping
        // the `err` text), and the following messages must still decode.

        // msg1: error frame whose stack contains a dangling `source` key.
        let mut stack_frame = vec![b'd'];
        stack_frame.extend_from_slice(b"6:source"); // key with NO value
        stack_frame.push(b'e'); // dict closes immediately (the malformation)
        let mut stack = vec![b'l'];
        stack.extend_from_slice(&stack_frame);
        stack.push(b'e');
        let mut msg1 = vec![b'd'];
        msg1.extend_from_slice(b"2:id1:3");
        msg1.extend_from_slice(b"3:err4:boom");
        msg1.extend_from_slice(b"21:ares.evaluation/stack");
        msg1.extend_from_slice(&stack);
        msg1.push(b'e');

        // msg2: the matching `ex` + done frame.
        let msg2 = b"d2:id1:32:ex9:some-kind6:statusl5:error4:doneee";

        let mut buf = msg1.clone();
        buf.extend_from_slice(msg2);

        // First message: salvaged, not Incomplete, and we keep the err text.
        match decode_one(&buf) {
            Decoded::Message { response, consumed } => {
                assert_eq!(consumed, msg1.len(), "must frame exactly one message");
                assert_eq!(response.id, "3");
                assert_eq!(response.err.as_deref(), Some("boom"));
            }
            Decoded::Incomplete => panic!("regression: dangling-key frame wedged the reader"),
            Decoded::Malformed { .. } => panic!("err text should have been salvaged"),
        }

        // Second message decodes normally and carries the `ex` + done that
        // completes the eval.
        match decode_one(&buf[msg1.len()..]) {
            Decoded::Message { response, consumed } => {
                assert_eq!(consumed, msg2.len());
                assert_eq!(response.ex.as_deref(), Some("some-kind"));
                assert!(response.status.iter().any(|s| s == "done"));
            }
            _ => panic!("expected Message for the ex/done frame"),
        }
    }
}
