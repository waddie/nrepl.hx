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

//! Error path tests for nrepl-rs
//!
//! These tests verify that error handling works correctly for various failure modes.
//! Most do not require a running nREPL server.

mod common;

use nrepl_rs::NReplError;
use nrepl_rs::worker::Worker;
use std::time::Duration;

#[test]
fn test_connection_refused() {
    // Try to connect to a port that's not listening
    let worker = Worker::new();
    let result = worker.connect_blocking("localhost:39999".to_string());

    assert!(
        result.is_err(),
        "Should fail to connect to non-listening port"
    );

    match result {
        Err(NReplError::Connection(io_err)) => {
            assert!(
                io_err.kind() == std::io::ErrorKind::ConnectionRefused,
                "Expected ConnectionRefused, got: {:?}",
                io_err.kind()
            );
        }
        Err(other) => panic!("Expected Connection error, got: {other:?}"),
        Ok(()) => panic!("Expected error, but connection succeeded"),
    }
}

#[test]
fn test_invalid_host() {
    // Try to connect to a hostname that doesn't resolve
    let worker = Worker::new();
    let result = worker.connect_blocking("invalid.host.that.does.not.exist:7888".to_string());

    assert!(result.is_err(), "Should fail to connect to invalid host");

    match result {
        Err(NReplError::Connection(_)) => {
            // Could be various IO errors depending on system (NotFound, etc)
            // Just verify it's a Connection error
        }
        Err(other) => panic!("Expected Connection error, got: {other:?}"),
        Ok(()) => panic!("Expected error, but connection succeeded"),
    }
}

#[test]
fn test_codec_error_incomplete_bencode() {
    use nrepl_rs::codec::decode_response;

    // Incomplete bencode - just the start of a dict with no end
    let incomplete = b"d2:id5:msg-1";

    let result = decode_response(incomplete);
    assert!(result.is_err(), "Should fail on incomplete bencode");

    let err = result.unwrap_err();
    match err {
        NReplError::Codec {
            message, position, ..
        } => {
            assert!(
                message.contains("Incomplete") || message.contains("incomplete"),
                "Error should mention incomplete data, got: {message}"
            );
            assert!(position > 0, "Position should be tracked");
        }
        other => panic!("Expected Codec error, got: {other:?}"),
    }
}

#[test]
fn test_codec_error_invalid_bencode_type() {
    use nrepl_rs::codec::decode_response;

    // Invalid bencode - starts with 'x' which isn't a valid bencode type
    let invalid = b"x123:invalid";

    let result = decode_response(invalid);
    assert!(result.is_err(), "Should fail on invalid bencode type");

    let err = result.unwrap_err();
    match err {
        NReplError::Codec {
            message,
            position,
            buffer_preview,
        } => {
            assert!(
                message.contains("Invalid") || message.contains("invalid"),
                "Error should mention invalid data, got: {message}"
            );
            assert_eq!(position, 0, "Error at position 0");
            assert!(
                buffer_preview.is_some(),
                "Should include buffer preview for debugging"
            );
        }
        other => panic!("Expected Codec error, got: {other:?}"),
    }
}

#[test]
fn test_codec_error_string_length_overflow() {
    use nrepl_rs::codec::decode_response;

    // String claims to be 9999 bytes but buffer is much smaller
    let overflow = b"9999:short";

    let result = decode_response(overflow);
    assert!(
        result.is_err(),
        "Should fail when string length exceeds buffer"
    );

    let err = result.unwrap_err();
    match err {
        NReplError::Codec { message, .. } => {
            assert!(
                message.contains("Incomplete") || message.contains("string"),
                "Error should mention incomplete string data, got: {message}"
            );
        }
        other => panic!("Expected Codec error, got: {other:?}"),
    }
}

#[test]
fn test_codec_error_integer_overflow() {
    use nrepl_rs::codec::decode_response;

    // String with length that would cause integer overflow when computing end position
    // MAX_STRING_LENGTH is 10MB, so use something bigger than that
    let overflow = b"999999999999999999999:x";

    let result = decode_response(overflow);
    assert!(
        result.is_err(),
        "Should fail on string length exceeding MAX_STRING_LENGTH"
    );

    let err = result.unwrap_err();
    match err {
        NReplError::Codec { message, .. } => {
            // The parser may reject this as invalid before checking MAX_STRING_LENGTH
            assert!(
                message.contains("Invalid") || message.contains("exceeds maximum"),
                "Error should mention invalid or maximum size, got: {message}"
            );
        }
        other => panic!("Expected Codec error, got: {other:?}"),
    }
}

#[test]
fn test_codec_valid_response_with_preview() {
    use nrepl_rs::codec::decode_response;

    // Valid bencode response
    let valid = b"d2:id5:msg-17:session11:session-4566:statusl4:doneee";

    let result = decode_response(valid);
    assert!(result.is_ok(), "Should decode valid bencode");

    let (response, consumed) = result.unwrap();
    assert_eq!(response.id, "msg-1");
    assert_eq!(response.session, "session-456");
    assert_eq!(consumed, valid.len());
}

#[test]
fn test_error_display_codec() {
    let err = NReplError::codec("test error", 42);
    let display = format!("{err}");
    assert!(display.contains("Codec error"));
    assert!(display.contains("42"));
    assert!(display.contains("test error"));
}

#[test]
fn test_error_display_codec_with_preview() {
    let buffer = b"test\x00\x01\x02";
    let err = NReplError::codec_with_preview("parse failed", 10, buffer);
    let display = format!("{err}");
    assert!(display.contains("Codec error"));
    assert!(display.contains("10"));
    assert!(display.contains("parse failed"));
    assert!(display.contains("buffer preview"));
}

#[test]
fn test_error_display_protocol() {
    let err = NReplError::protocol("missing field");
    let display = format!("{err}");
    assert!(display.contains("Protocol error"));
    assert!(display.contains("missing field"));
}

#[test]
fn test_error_display_protocol_with_response() {
    let err = NReplError::protocol_with_response("missing field", "d2:id5:msg-1e");
    let display = format!("{err}");
    assert!(display.contains("Protocol error"));
    assert!(display.contains("missing field"));
    assert!(display.contains("response"));
}

#[test]
fn test_error_display_session_not_found() {
    let err = NReplError::SessionNotFound("session-123".to_string());
    let display = format!("{err}");
    assert!(display.contains("Session not found"));
    assert!(display.contains("session-123"));
}

#[test]
fn test_error_display_operation_failed() {
    let err = NReplError::OperationFailed("timeout occurred".to_string());
    let display = format!("{err}");
    assert!(display.contains("Operation failed"));
    assert!(display.contains("timeout occurred"));
}

#[test]
fn test_error_display_timeout() {
    let err = NReplError::Timeout {
        operation: "eval".to_string(),
        duration: Duration::from_secs(5),
    };
    let display = format!("{err}");
    assert!(display.contains("Timeout"));
    assert!(display.contains("eval"));
    assert!(display.contains("5s"));
}

#[test]
fn test_error_source_connection() {
    use std::error::Error;

    let io_err = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "refused");
    let err = NReplError::Connection(io_err);

    // Should have a source
    assert!(
        err.source().is_some(),
        "Connection error should have source"
    );
}

#[test]
fn test_error_source_other_types() {
    use std::error::Error;

    let err = NReplError::protocol("test");
    assert!(
        err.source().is_none(),
        "Protocol error should not have source"
    );

    let err = NReplError::SessionNotFound("test".to_string());
    assert!(
        err.source().is_none(),
        "SessionNotFound should not have source"
    );
}

/// Evaluating on a closed session yields an empty result, not an error.
///
/// The worker deliberately keeps no client-side session registry: a `Session`
/// is just a wire id, and the server is the authority on which ids are live.
/// So the eval goes out and nREPL answers with a bare `done` for the retired
/// session, which folds into an `EvalResult` with no value, output, or error.
///
/// Callers that need to know a session died should watch `close-session` or
/// `ls-sessions` rather than inferring it from an eval result.
#[test]
#[ignore = "requires a running nREPL server"]
fn test_eval_with_closed_session_yields_empty_result() {
    let (mut worker, session) = common::connect();

    common::close_session(&worker, session.clone()).expect("Failed to close");

    let result = common::eval(&mut worker, &session, "(+ 1 2)").expect("eval should not error");

    assert_eq!(result.value, None, "Closed session should produce no value");
    assert!(
        result.error.is_empty(),
        "Closed session should produce no error text, got: {:?}",
        result.error
    );
}

// Integration test for interrupting an id that was never submitted
#[test]
#[ignore = "requires a running nREPL server"]
fn test_interrupt_unknown_request() {
    use nrepl_rs::worker::WorkerCommand;
    use std::sync::mpsc::channel;

    let (worker, session) = common::connect();

    // Mint an id without ever submitting an eval for it, then interrupt it.
    let target = worker.next_id();

    let (reply_tx, reply_rx) = channel();
    worker
        .command_sender()
        .send(WorkerCommand::Interrupt {
            op_id: worker.next_id(),
            session,
            target,
            reply: reply_tx,
        })
        .expect("worker thread gone");

    let result = reply_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("interrupt reply timed out");

    // Servers differ: some ack an interrupt for an unknown id, some report
    // session-idle. Either is fine; what must not happen is a hang.
    match result {
        Ok(()) => {}
        Err(other) => println!("Interrupt of unknown id returned error: {other:?}"),
    }
}

// Integration test for close_session - requires real server
#[test]
#[ignore = "requires a running nREPL server"]
fn test_close_session_completes() {
    let (worker, session) = common::connect();

    let result = common::close_session(&worker, session);

    match result {
        Ok(()) => {
            // Normal case - session closed successfully
        }
        Err(NReplError::Timeout {
            operation,
            duration,
        }) => {
            assert_eq!(operation, "close-session");
            assert_eq!(duration, Duration::from_secs(10));
        }
        Err(other) => {
            panic!("Unexpected error closing session: {other:?}");
        }
    }
}
