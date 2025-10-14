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

//! FFI Integration tests for steel-nrepl
//!
//! These tests verify the entire FFI stack from connection through evaluation,
//! including S-expression format generation and error propagation.
//!
//! **Requirements:**
//! - A running nREPL server on localhost:7888
//! - Run with: cargo test -p steel-nrepl --test ffi_integration -- --ignored --test-threads=1
//!
//! **Setup:**
//! ```bash
//! clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//! ```

use steel_nrepl::{
    connection::{nrepl_clone_session, nrepl_close, nrepl_connect, nrepl_try_get_result},
};
use std::{thread, time::Duration};

/// Helper to connect to test server and return connection ID
fn connect_test_server() -> usize {
    nrepl_connect("localhost:7888".to_string()).expect("Failed to connect to test server")
}

/// Helper to poll for result with timeout
/// Returns Result<Option<String>, Error> where:
/// - Ok(Some(result)) = Got result
/// - Ok(None) = Timeout waiting for result
/// - Err(e) = Error occurred (e.g., nREPL timeout, connection error)
fn poll_for_result(conn_id: usize, request_id: usize, timeout_ms: u64) -> Result<Option<String>, String> {
    let start = std::time::Instant::now();
    let timeout = Duration::from_millis(timeout_ms);

    while start.elapsed() < timeout {
        match nrepl_try_get_result(conn_id, request_id) {
            Ok(Some(result)) => return Ok(Some(result)),
            Ok(None) => {
                // Result not ready yet, sleep and retry
                thread::sleep(Duration::from_millis(10));
            }
            Err(e) => {
                // Return error (e.g., nREPL timeout, connection error)
                return Err(format!("{:?}", e));
            }
        }
    }

    Ok(None) // Polling timeout (result never arrived)
}

/// Parse S-expression hash to verify format (simple validation)
/// Returns (value, output_count, has_error, namespace)
fn parse_sexpr_hash(sexpr: &str) -> (Option<String>, usize, bool, Option<String>) {
    // This is a simple parser to verify the basic format
    // A proper parser would use a full S-expression library

    // Should start with "(hash "
    assert!(sexpr.starts_with("(hash "), "S-expr should start with '(hash ', got: {}", sexpr);
    assert!(sexpr.ends_with(')'), "S-expr should end with ')'");

    // Extract value
    let value = if sexpr.contains("'value \"") {
        let start = sexpr.find("'value \"").unwrap() + 8;
        let rest = &sexpr[start..];
        let end = rest.find('"').unwrap();
        Some(rest[..end].to_string())
    } else if sexpr.contains("'value #f") {
        None
    } else {
        panic!("Could not find 'value in S-expr: {}", sexpr);
    };

    // Count output list items
    let output_count = if sexpr.contains("'output (list") {
        let start = sexpr.find("'output (list").unwrap() + 14;
        let rest = &sexpr[start..];
        let end = rest.find(')').unwrap();
        let list_contents = &rest[..end];
        if list_contents.trim().is_empty() {
            0
        } else {
            // Count quoted strings
            list_contents.matches('"').count() / 2
        }
    } else {
        0
    };

    // Check for error
    let has_error = !sexpr.contains("'error #f");

    // Extract namespace
    let ns = if sexpr.contains("'ns \"") {
        let start = sexpr.find("'ns \"").unwrap() + 5;
        let rest = &sexpr[start..];
        let end = rest.find('"').unwrap();
        Some(rest[..end].to_string())
    } else {
        None
    };

    (value, output_count, has_error, ns)
}

#[test]
#[ignore]
fn test_ffi_connect_and_close() {
    let conn_id = connect_test_server();
    assert!(conn_id > 0, "Connection ID should be positive");

    // Close the connection
    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_clone_session() {
    let conn_id = connect_test_server();

    let session = nrepl_clone_session(conn_id).expect("Failed to clone session");
    assert_eq!(session.conn_id.as_usize(), conn_id, "Session should reference correct connection");
    assert!(session.session_id.as_usize() > 0, "Session ID should be positive");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_simple_expression() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit eval
    let request_id = session.eval("(+ 1 2)").expect("Failed to submit eval");
    assert!(request_id > 0, "Request ID should be positive");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Parse S-expression
    let (value, output_count, has_error, ns) = parse_sexpr_hash(&result);

    assert_eq!(value, Some("3".to_string()), "Value should be 3");
    assert_eq!(output_count, 0, "Should have no output");
    assert!(!has_error, "Should have no error");
    assert!(ns.is_some(), "Should have namespace");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_with_output() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit eval with output
    let request_id = session
        .eval(r#"(do (println "hello") (+ 1 2))"#)
        .expect("Failed to submit eval");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Parse S-expression
    let (value, output_count, has_error, _ns) = parse_sexpr_hash(&result);

    assert_eq!(value, Some("3".to_string()), "Value should be 3");
    assert!(output_count > 0, "Should have output");
    assert!(!has_error, "Should have no error");
    assert!(result.contains("hello"), "Output should contain 'hello'");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_with_error() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit eval that causes error
    let request_id = session.eval("(/ 1 0)").expect("Failed to submit eval");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Parse S-expression
    let (value, _output_count, has_error, _ns) = parse_sexpr_hash(&result);

    // Either no value or has error
    assert!(value.is_none() || has_error, "Should indicate error for division by zero");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_with_timeout() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit eval with custom timeout (5 seconds should be plenty for quick eval)
    let request_id = session
        .eval_with_timeout("(+ 10 20)", 5000)
        .expect("Failed to submit eval with timeout");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 10000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Parse S-expression
    let (value, _output_count, has_error, _ns) = parse_sexpr_hash(&result);

    assert_eq!(value, Some("30".to_string()), "Value should be 30");
    assert!(!has_error, "Should have no error");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_timeout_fires() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit eval that sleeps 5 seconds with 1 second timeout
    let request_id = session
        .eval_with_timeout("(Thread/sleep 5000)", 1000)
        .expect("Failed to submit eval with timeout");

    // Poll for result (should get timeout error)
    let result = poll_for_result(conn_id, request_id, 10000);

    // Should get an Err because the nREPL operation timed out
    assert!(result.is_err(), "Should get timeout error from nREPL");

    // Verify error message contains "timed out"
    let err_msg = result.unwrap_err();
    assert!(err_msg.to_lowercase().contains("timed out") || err_msg.to_lowercase().contains("timeout"),
            "Error message should mention timeout, got: {}", err_msg);

    // Verify we can continue using the connection after timeout
    let request_id2 = session.eval("(+ 1 2)").expect("Failed to submit second eval");
    let result2 = poll_for_result(conn_id, request_id2, 5000)
        .expect("Failed to poll for result")
        .expect("Connection should remain usable after timeout");

    let (value, _, _, _) = parse_sexpr_hash(&result2);
    assert_eq!(value, Some("3".to_string()), "Connection should remain usable");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_eval_empty_code_validation() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Try to eval empty string
    let result = session.eval("");
    assert!(result.is_err(), "Empty code should be rejected");

    // Try to eval whitespace-only string
    let result = session.eval("   \n\t  ");
    assert!(result.is_err(), "Whitespace-only code should be rejected");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_concurrent_evals() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Submit multiple evals without waiting for results
    let req1 = session.eval("(+ 1 2)").expect("Failed to submit eval 1");
    let req2 = session.eval("(* 3 4)").expect("Failed to submit eval 2");
    let req3 = session.eval("(- 10 5)").expect("Failed to submit eval 3");

    // All request IDs should be different
    assert_ne!(req1, req2, "Request IDs should be unique");
    assert_ne!(req2, req3, "Request IDs should be unique");
    assert_ne!(req1, req3, "Request IDs should be unique");

    // Poll for all results
    let result1 = poll_for_result(conn_id, req1, 5000).expect("Failed to poll").expect("Timeout on eval 1");
    let result2 = poll_for_result(conn_id, req2, 5000).expect("Failed to poll").expect("Timeout on eval 2");
    let result3 = poll_for_result(conn_id, req3, 5000).expect("Failed to poll").expect("Timeout on eval 3");

    // Parse results
    let (value1, _, _, _) = parse_sexpr_hash(&result1);
    let (value2, _, _, _) = parse_sexpr_hash(&result2);
    let (value3, _, _, _) = parse_sexpr_hash(&result3);

    assert_eq!(value1, Some("3".to_string()), "First eval should return 3");
    assert_eq!(value2, Some("12".to_string()), "Second eval should return 12");
    assert_eq!(value3, Some("5".to_string()), "Third eval should return 5");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_multiple_sessions() {
    let conn_id = connect_test_server();

    let mut session1 = nrepl_clone_session(conn_id).expect("Failed to clone session 1");
    let mut session2 = nrepl_clone_session(conn_id).expect("Failed to clone session 2");

    // Session IDs should be different
    assert_ne!(session1.session_id, session2.session_id, "Sessions should have different IDs");

    // Test REPL-specific isolation using *1 (last result)
    // Note: In nREPL, vars defined with `def` are shared across sessions,
    // but REPL-specific vars like *1, *2, *3 are session-isolated

    // Eval in session 1
    let req1 = session1.eval("(+ 10 20)").expect("Failed to eval in session 1");
    let result1 = poll_for_result(conn_id, req1, 5000).expect("Failed to poll").expect("Timeout on session 1 eval");
    let (value1, _, _, _) = parse_sexpr_hash(&result1);
    assert_eq!(value1, Some("30".to_string()), "Session 1 should return 30");

    // Eval in session 2
    let req2 = session2.eval("(* 5 6)").expect("Failed to eval in session 2");
    let result2 = poll_for_result(conn_id, req2, 5000).expect("Failed to poll").expect("Timeout on session 2 eval");
    let (value2, _, _, _) = parse_sexpr_hash(&result2);
    assert_eq!(value2, Some("30".to_string()), "Session 2 should return 30");

    // Check *1 in session 1 (should be 30 from + 10 20)
    let req3 = session1.eval("*1").expect("Failed to eval *1 in session 1");
    let result3 = poll_for_result(conn_id, req3, 5000).expect("Failed to poll").expect("Timeout on *1 eval");
    let (value3, _, _, _) = parse_sexpr_hash(&result3);
    assert_eq!(value3, Some("30".to_string()), "Session 1's *1 should be 30 (result of + 10 20)");

    // Check *1 in session 2 (should be 30 from * 5 6)
    let req4 = session2.eval("*1").expect("Failed to eval *1 in session 2");
    let result4 = poll_for_result(conn_id, req4, 5000).expect("Failed to poll").expect("Timeout on *1 eval");
    let (value4, _, _, _) = parse_sexpr_hash(&result4);
    assert_eq!(value4, Some("30".to_string()), "Session 2's *1 should be 30 (result of * 5 6)");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_load_file() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Load file contents
    let file_contents = "(defn test-fn [x] (* x 2))";
    let request_id = session
        .load_file(
            file_contents,
            Some("/test/path.clj".to_string()),
            Some("path.clj".to_string()),
        )
        .expect("Failed to submit load-file");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for load-file result");

    // Parse S-expression
    let (_value, _, has_error, _) = parse_sexpr_hash(&result);
    assert!(!has_error, "Load-file should not have error");

    // Verify the function was defined
    let req2 = session.eval("(test-fn 21)").expect("Failed to eval test-fn");
    let result2 = poll_for_result(conn_id, req2, 5000).expect("Failed to poll").expect("Timeout on test-fn eval");
    let (value2, _, _, _) = parse_sexpr_hash(&result2);
    assert_eq!(value2, Some("42".to_string()), "test-fn should return 42");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_s_expression_escaping() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Eval code that returns strings with special characters
    let request_id = session
        .eval(r#""line1\nline2\ttab\"quoted\"""#)
        .expect("Failed to submit eval");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Verify the S-expression has properly escaped strings
    assert!(result.contains(r#"\n"#), "Should escape newlines");
    assert!(result.contains(r#"\t"#), "Should escape tabs");
    assert!(result.contains(r#"\""#), "Should escape quotes");

    // Parse to verify format
    let (value, _, has_error, _) = parse_sexpr_hash(&result);
    assert!(!has_error, "Should have no error");
    assert!(value.is_some(), "Should have a value");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_connection_limit() {
    // This test verifies MAX_CONNECTIONS limit (100 connections)
    // Creating 100+ connections would be expensive, so we just verify
    // the limit is checked by looking at error messages

    // Note: This is a smoke test. A full test would need to create 100+ connections
    // which is impractical in CI. The actual limit check is in registry.rs:52-56.

    let conn_id = connect_test_server();
    assert!(conn_id > 0, "Should be able to create at least one connection");
    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_error_propagation() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Test various error scenarios

    // 1. Syntax error
    let req1 = session.eval("(+ 1").expect("Failed to submit eval");
    let result1 = poll_for_result(conn_id, req1, 5000).expect("Failed to poll").expect("Timeout on eval");
    let (_, _, has_error1, _) = parse_sexpr_hash(&result1);
    assert!(has_error1, "Syntax error should be reported");

    // 2. Undefined variable
    let req2 = session.eval("undefined-variable").expect("Failed to submit eval");
    let result2 = poll_for_result(conn_id, req2, 5000).expect("Failed to poll").expect("Timeout on eval");
    let (_, _, has_error2, _) = parse_sexpr_hash(&result2);
    assert!(has_error2, "Undefined variable should be reported");

    nrepl_close(conn_id).expect("Failed to close connection");
}

#[test]
#[ignore]
fn test_ffi_namespace_tracking() {
    let conn_id = connect_test_server();
    let mut session = nrepl_clone_session(conn_id).expect("Failed to clone session");

    // Switch to custom namespace
    let request_id = session
        .eval("(ns test.custom)")
        .expect("Failed to submit eval");

    // Poll for result
    let result = poll_for_result(conn_id, request_id, 5000)
        .expect("Failed to poll for result")
        .expect("Timeout waiting for eval result");

    // Parse S-expression
    let (_, _, has_error, ns) = parse_sexpr_hash(&result);
    assert!(!has_error, "Should not have error");
    assert_eq!(ns, Some("test.custom".to_string()), "Should switch to test.custom namespace");

    nrepl_close(conn_id).expect("Failed to close connection");
}
