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

//! Integration tests for nrepl-rs
//!
//! These tests drive the demux [`Worker`](nrepl_rs::worker::Worker) through the
//! blocking helpers in `tests/common`, and require a running nREPL server.
//!
//! To run:
//! 1. Start an nREPL server, e.g.
//!    bb nrepl-server 7888
//!    or, with Clojure:
//!    clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//!
//! 2. Run tests:
//!    cargo test -p nrepl-rs --test integration -- --ignored --test-threads=1
//!
//! Set `NREPL_TEST_ADDR` to point at a server other than localhost:7888.

// These tests are ignored by default since they require external setup
// Run with: cargo test -p nrepl-rs -- --ignored

mod common;

#[cfg(test)]
mod real_server_tests {
    use crate::common;
    use nrepl_rs::NReplError;
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_connect_to_real_server() {
        let worker = nrepl_rs::worker::Worker::new();
        let result = worker.connect_blocking(common::test_server_addr());
        assert!(result.is_ok(), "Failed to connect to nREPL server");
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_clone_session() {
        let worker = common::connect_worker();
        let session = common::clone_session(&worker);
        assert!(session.is_ok(), "Failed to clone session");
        let session = session.unwrap();
        assert!(!session.id().is_empty(), "Session ID should not be empty");
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_simple_expression() {
        let (mut worker, session) = common::connect();

        let result = common::eval(&mut worker, &session, "(+ 1 2)");
        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()), "Expected value 3");
        assert!(result.error.is_empty(), "Should have no errors");
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_with_output() {
        let (mut worker, session) = common::connect();

        let result = common::eval(&mut worker, &session, r#"(do (println "hello") (+ 1 2))"#);
        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()), "Expected value 3");
        assert!(!result.output.is_empty(), "Should have output");
        assert!(
            result.output.iter().any(|s| s.contains("hello")),
            "Output should contain 'hello', got: {:?}",
            result.output
        );
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_multiple_expressions() {
        let (mut worker, session) = common::connect();

        // First eval
        let result1 = common::eval(&mut worker, &session, "(def x 42)");
        assert!(result1.is_ok(), "First eval failed");

        // Second eval should see the def from first
        let result2 = common::eval(&mut worker, &session, "x");
        assert!(result2.is_ok(), "Second eval failed");
        assert_eq!(result2.unwrap().value, Some("42".to_string()));
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_error() {
        let (mut worker, session) = common::connect();

        // Try to evaluate invalid code
        let result = common::eval(&mut worker, &session, "(/ 1 0)");

        // nREPL should return successfully but with error information
        assert!(
            result.is_ok(),
            "Request should succeed even with eval error"
        );
        let result = result.unwrap();

        // The response should indicate an error occurred
        // (either in status or through error fields)
        assert!(
            !result.error.is_empty() || result.value.is_none(),
            "Should indicate error for division by zero"
        );
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_with_namespace() {
        let (mut worker, session) = common::connect();

        let result = common::eval(&mut worker, &session, "(ns test.ns) (+ 1 2)");
        assert!(result.is_ok(), "Eval with ns failed");

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()));
        assert_eq!(
            result.ns,
            Some("test.ns".to_string()),
            "Should switch to test.ns namespace"
        );
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_with_default_timeout_succeeds() {
        let (mut worker, session) = common::connect();

        // Quick operation should complete within default 60s timeout
        let result = common::eval(&mut worker, &session, "(+ 1 2)");
        assert!(
            result.is_ok(),
            "Quick eval should succeed with default timeout"
        );
        assert_eq!(result.unwrap().value, Some("3".to_string()));
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_with_custom_timeout_succeeds() {
        let (mut worker, session) = common::connect();

        // Quick operation should complete within 5 second timeout
        let result =
            common::eval_with_timeout(&mut worker, &session, "(+ 1 2)", Duration::from_secs(5));
        assert!(
            result.is_ok(),
            "Quick eval should succeed with custom timeout"
        );
        assert_eq!(result.unwrap().value, Some("3".to_string()));
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_timeout_fires() {
        let (mut worker, session) = common::connect();

        // Try to sleep for 5 seconds with a 1 second timeout
        // This should timeout
        let result = common::eval_with_timeout(
            &mut worker,
            &session,
            "(Thread/sleep 5000)",
            Duration::from_secs(1),
        );

        assert!(result.is_err(), "Long-running eval should timeout");

        let err = result.unwrap_err();
        match err {
            NReplError::Timeout {
                operation,
                duration,
            } => {
                assert_eq!(operation, "eval", "Error should be for eval operation");
                assert_eq!(
                    duration,
                    Duration::from_secs(1),
                    "Error should report correct timeout duration"
                );
            }
            other => panic!("Expected Timeout error, got: {other:?}"),
        }
    }

    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_eval_timeout_boundary() {
        let (mut worker, session) = common::connect();

        // Sleep for 100ms with a 5 second timeout - should succeed
        // Note: We use a generous timeout to account for network and processing overhead
        let result = common::eval_with_timeout(
            &mut worker,
            &session,
            "(Thread/sleep 100)",
            Duration::from_secs(5),
        );

        assert!(
            result.is_ok(),
            "Eval completing within timeout should succeed: {:?}",
            result.err()
        );
    }

    /// Test timeout recovery - the worker remains usable after a timeout
    ///
    /// After an eval's deadline fires, the worker drops that eval's pending
    /// state and moves on to the next queued eval. Late responses for the
    /// timed-out request have no pending entry left to route to, so they are
    /// discarded rather than being folded into a later eval's result.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_timeout_recovery() {
        let (mut worker, session) = common::connect();

        // First, trigger a timeout with a slow operation
        let result = common::eval_with_timeout(
            &mut worker,
            &session,
            "(Thread/sleep 5000)",
            Duration::from_secs(1),
        );

        // Verify the timeout occurred
        assert!(result.is_err(), "Long-running eval should timeout");
        match result.unwrap_err() {
            NReplError::Timeout { .. } => {
                // Expected - timeout occurred
            }
            other => panic!("Expected Timeout error, got: {other:?}"),
        }

        // Now verify the worker is still usable by performing a successful eval
        let result = common::eval(&mut worker, &session, "(+ 10 20)");

        assert!(
            result.is_ok(),
            "Worker should remain usable after timeout: {:?}",
            result.err()
        );

        let result = result.unwrap();
        assert_eq!(
            result.value,
            Some("30".to_string()),
            "Subsequent eval should work correctly"
        );
        assert!(
            result.error.is_empty(),
            "Subsequent eval should have no errors"
        );

        // Perform another eval to further verify stability
        let result = common::eval(&mut worker, &session, "(* 6 7)");
        assert!(
            result.is_ok(),
            "Worker should continue working after recovery: {:?}",
            result.err()
        );
        assert_eq!(result.unwrap().value, Some("42".to_string()));
    }

    /// Test persistent buffer handling with multiple output chunks
    ///
    /// This test verifies that the reader's persistent buffer correctly handles
    /// multiple bencode messages that may arrive in rapid succession or within
    /// a single TCP read. The server typically sends multiple responses:
    /// - One or more messages with output/errors (status: [])
    /// - A final message with value and "done" status
    ///
    /// The persistent buffer ensures no messages are lost when multiple arrive
    /// in one TCP packet, and correctly handles partial messages split across reads.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_buffer_handles_multiple_output_chunks() {
        let (mut worker, session) = common::connect();

        // Evaluate code that produces multiple output chunks
        // This will cause the server to send multiple response messages:
        // - Message with "chunk 1" output
        // - Message with "chunk 2" output
        // - Message with "chunk 3" output
        // - Final message with value and "done" status
        let result = common::eval(
            &mut worker,
            &session,
            r#"(do
                 (println "chunk 1")
                 (println "chunk 2")
                 (println "chunk 3")
                 (+ 1 2))"#,
        );

        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()), "Expected value 3");

        // Verify all output chunks were received
        // (may be combined or separate depending on server behavior)
        let combined_output = result.output.join("");
        assert!(
            combined_output.contains("chunk 1"),
            "Should contain 'chunk 1'"
        );
        assert!(
            combined_output.contains("chunk 2"),
            "Should contain 'chunk 2'"
        );
        assert!(
            combined_output.contains("chunk 3"),
            "Should contain 'chunk 3'"
        );
    }

    /// Test persistent buffer with large output
    ///
    /// This verifies the buffer can handle large responses that may be split
    /// across multiple TCP reads, or multiple messages that arrive in one read.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_buffer_handles_large_output() {
        let (mut worker, session) = common::connect();

        // Generate a large string (10KB) which may be split across multiple messages
        let result = common::eval(&mut worker, &session, r#"(apply str (repeat 10000 "x"))"#);

        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert!(result.value.is_some(), "Should have a value");
        let value = result.value.unwrap();
        // `value` is the printed representation (conformance #5), so a string
        // result arrives quoted: 10000 'x' characters wrapped in `"` quotes.
        assert_eq!(
            value.len(),
            10002,
            "Should return the printed representation of a 10000-char string"
        );
        let inner = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .expect("String value should be quoted");
        assert!(
            inner.chars().all(|c| c == 'x'),
            "String should contain only 'x' characters"
        );
    }

    /// Test persistent buffer with rapid sequential evaluations
    ///
    /// This tests that the buffer correctly handles back-to-back evaluations
    /// where responses might arrive in rapid succession or overlap.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_buffer_handles_rapid_evaluations() {
        let (mut worker, session) = common::connect();

        // Perform multiple rapid evaluations
        for i in 1..=10 {
            let result = common::eval(&mut worker, &session, format!("(+ {i} {i})"));

            assert!(result.is_ok(), "Eval {} failed: {:?}", i, result.err());

            let result = result.unwrap();
            assert_eq!(
                result.value,
                Some((i + i).to_string()),
                "Eval {} should return {}",
                i,
                i + i
            );
        }
    }

    /// Test partial message handling across TCP reads
    ///
    /// This test uses a large code string that's likely to result in responses
    /// that span multiple TCP packets, testing that the buffer correctly
    /// accumulates partial messages until complete.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_buffer_handles_partial_messages() {
        let (mut worker, session) = common::connect();

        // Create a large code string (with comments to increase size)
        // The response will be large enough to likely span multiple TCP reads
        let large_code = format!(
            r#"(do
                 ;; Comment: {}
                 (let [data (apply str (repeat 1000 "test data "))]
                   (count data)))"#,
            "x".repeat(1000)
        );

        let result = common::eval(&mut worker, &session, large_code);

        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        // "test data " is 10 chars, repeated 1000 times = 10000
        assert_eq!(
            result.value,
            Some("10000".to_string()),
            "Should return correct count"
        );
    }

    /// Test `MAX_OUTPUT_ENTRIES` `DoS` protection
    ///
    /// Verifies that the client protects against `DoS` attacks via excessive output
    /// flooding. The limit is 10,000 output entries per evaluation.
    ///
    /// This prevents a malicious or buggy server from exhausting client memory
    /// by sending unlimited output responses.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_max_output_entries_protection() {
        let (mut worker, session) = common::connect();

        // Try to generate more than 10,000 output entries
        // Each println creates one output entry
        // We use 10,100 to exceed the limit
        let result = common::eval(&mut worker, &session, r"(dotimes [i 10100] (println i))");

        // The evaluation should fail with a protocol error about exceeding the limit
        assert!(
            result.is_err(),
            "Should fail when exceeding MAX_OUTPUT_ENTRIES (10,000)"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Protocol {
                ref message,
                response: _,
            } => {
                assert!(
                    message.contains("maximum entries limit")
                        || message.contains("10000")
                        || message.contains("10,000"),
                    "Error should mention entries limit, got: {message}"
                );
            }
            other => panic!("Expected Protocol error about entries limit, got: {other:?}"),
        }
    }

    /// Test that output under the limit works fine
    ///
    /// This verifies that evaluations producing output close to but under the
    /// `MAX_OUTPUT_ENTRIES` limit (10,000) complete successfully.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_output_entries_under_limit() {
        let (mut worker, session) = common::connect();

        // Generate 1,000 output entries (well under the 10,000 limit)
        let result = common::eval(&mut worker, &session, r"(dotimes [i 1000] (println i))");

        assert!(
            result.is_ok(),
            "Should succeed with 1,000 entries (under 10,000 limit): {:?}",
            result.err()
        );

        let result = result.unwrap();
        // Should have 1000 output entries
        assert!(
            result.output.len() <= 1000,
            "Should have at most 1000 output entries"
        );
    }

    /// Test oversized-response `DoS` protection
    ///
    /// An 11MB response is refused rather than buffered without limit.
    ///
    /// Which guard fires is worth stating precisely, because it is not the one
    /// the old name suggested: the reader tops up its buffer 4KB at a time, and
    /// each top-up that leaves the bencode message incomplete increments a
    /// counter capped at `MAX_INCOMPLETE_READS` (1000). That cap is reached
    /// after about 4MB, so `MAX_RESPONSE_SIZE` (10MB) is never the guard that
    /// trips for a single streamed response.
    ///
    /// A reader error is terminal for the connection, so the worker fails every
    /// pending op with a connection error carrying the underlying message,
    /// rather than surfacing the bare `Protocol` error.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_oversized_response_is_refused() {
        let (mut worker, session) = common::connect();

        // Try to generate a response larger than the guards allow
        // 11MB = 11 * 1024 * 1024 = 11,534,336 bytes
        let result = common::eval(
            &mut worker,
            &session,
            r#"(apply str (repeat 11534336 "x"))"#,
        );

        assert!(
            result.is_err(),
            "Should fail rather than buffer an 11MB response"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Connection(ref io_err) => {
                let message = io_err.to_string();
                assert!(
                    message.contains("incomplete reads") || message.contains("maximum size"),
                    "Error should name the read guard that tripped, got: {message}"
                );
            }
            other => panic!("Expected Connection error from the read guard, got: {other:?}"),
        }
    }

    /// Test `MAX_OUTPUT_TOTAL_SIZE` `DoS` protection
    ///
    /// Verifies protection against excessive combined stdout+stderr output size.
    /// The limit is 10MB total for all output accumulated during an evaluation.
    ///
    /// This is separate from `MAX_OUTPUT_ENTRIES` (which limits number of entries)
    /// and prevents a few very large output strings from exhausting memory.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_max_output_total_size_protection() {
        let (mut worker, session) = common::connect();

        // Try to print more than 10MB of output
        // Print 100 strings of 120KB each = 12MB total
        let result = common::eval(
            &mut worker,
            &session,
            r#"(dotimes [i 100]
                 (println (apply str (repeat 122880 "x"))))"#,
        );

        // The evaluation should fail with a protocol error about total size
        assert!(
            result.is_err(),
            "Should fail when output exceeds MAX_OUTPUT_TOTAL_SIZE (10MB)"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Protocol {
                ref message,
                response: _,
            } => {
                assert!(
                    message.contains("maximum total size")
                        || message.contains("10")
                        || message.contains("MB"),
                    "Error should mention total size limit, got: {message}"
                );
            }
            other => panic!("Expected Protocol error about total size limit, got: {other:?}"),
        }
    }

    /// Test that large but acceptable responses work
    ///
    /// This verifies that responses close to but under the 10MB limit
    /// complete successfully.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_response_size_under_limit() {
        let (mut worker, session) = common::connect();

        // Generate a 1MB string (well under the 10MB limit)
        let result = common::eval(&mut worker, &session, r#"(apply str (repeat 1048576 "x"))"#);

        assert!(
            result.is_ok(),
            "Should succeed with 1MB response (under 10MB limit): {:?}",
            result.err()
        );

        let result = result.unwrap();
        assert!(result.value.is_some(), "Should have a value");
        let value = result.value.unwrap();
        // `value` is the printed representation (conformance #5), so the 1MB
        // string arrives quoted: 1048576 'x' characters plus two `"` quotes.
        assert_eq!(value.len(), 1_048_578, "Should return quoted 1MB string");
    }

    /// Test session isolation
    ///
    /// Verifies that multiple sessions maintain independent evaluation contexts.
    /// Note: In nREPL, sessions share the same Clojure runtime and namespace.
    /// Vars defined with `def` are visible across all sessions.
    /// What IS isolated between sessions:
    /// - Thread-local bindings (with `binding`)
    /// - REPL-specific vars like *1, *2, *3
    /// - Current namespace pointer
    ///
    /// This test verifies isolation of REPL result history (*1, *2, *3).
    ///
    /// Note: babashka does not isolate `*1` per session, so this test only
    /// passes against a JVM Clojure nREPL server.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_session_isolation() {
        let mut worker = common::connect_worker();

        // Create two independent sessions
        let session1 = common::clone_session(&worker).expect("Failed to clone session 1");
        let session2 = common::clone_session(&worker).expect("Failed to clone session 2");

        // Verify sessions have different IDs
        assert_ne!(
            session1.id(),
            session2.id(),
            "Sessions should have different IDs"
        );

        // Evaluate expression in session 1
        let result = common::eval(&mut worker, &session1, "(+ 10 20)");
        assert!(result.is_ok(), "Failed to eval in session 1");
        assert_eq!(result.unwrap().value, Some("30".to_string()));

        // Evaluate expression in session 2
        let result = common::eval(&mut worker, &session2, "(* 5 6)");
        assert!(result.is_ok(), "Failed to eval in session 2");
        assert_eq!(result.unwrap().value, Some("30".to_string()));

        // Verify session 1's *1 contains its own last result (30 from + 10 20)
        let result = common::eval(&mut worker, &session1, "*1");
        assert!(result.is_ok(), "Failed to eval *1 in session 1");
        assert_eq!(
            result.unwrap().value,
            Some("30".to_string()),
            "Session 1's *1 should be 30 (result of + 10 20)"
        );

        // Verify session 2's *1 contains its own last result (30 from * 5 6)
        let result = common::eval(&mut worker, &session2, "*1");
        assert!(result.is_ok(), "Failed to eval *1 in session 2");
        assert_eq!(
            result.unwrap().value,
            Some("30".to_string()),
            "Session 2's *1 should be 30 (result of * 5 6)"
        );

        // Evaluate different expression in session 1
        let result = common::eval(&mut worker, &session1, "(- 100 50)");
        assert!(result.is_ok(), "Failed to eval in session 1");
        assert_eq!(result.unwrap().value, Some("50".to_string()));

        // Verify session 1's *1 is now 50, but session 2's is still 30
        let result = common::eval(&mut worker, &session1, "*1");
        assert!(result.is_ok(), "Failed to eval *1 in session 1");
        assert_eq!(
            result.unwrap().value,
            Some("50".to_string()),
            "Session 1's *1 should be updated to 50"
        );

        let result = common::eval(&mut worker, &session2, "*1");
        assert!(result.is_ok(), "Failed to eval *1 in session 2");
        assert_eq!(
            result.unwrap().value,
            Some("30".to_string()),
            "Session 2's *1 should still be 30 (unchanged)"
        );
    }

    /// Test session namespace isolation
    ///
    /// Verifies that namespace changes in one session don't affect other sessions.
    ///
    /// Note: babashka shares one namespace pointer across sessions, so this test
    /// only passes against a JVM Clojure nREPL server.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_session_namespace_isolation() {
        let mut worker = common::connect_worker();

        // Create two independent sessions
        let session1 = common::clone_session(&worker).expect("Failed to clone session 1");
        let session2 = common::clone_session(&worker).expect("Failed to clone session 2");

        // Switch session 1 to a custom namespace
        let result = common::eval(&mut worker, &session1, "(ns test.session1)");
        assert!(result.is_ok(), "Failed to switch namespace in session 1");
        assert_eq!(
            result.unwrap().ns,
            Some("test.session1".to_string()),
            "Session 1 should be in test.session1 namespace"
        );

        // Verify session 2 is still in default namespace (user)
        let result = common::eval(&mut worker, &session2, "(str *ns*)");
        assert!(result.is_ok(), "Failed to check namespace in session 2");
        let ns = result.unwrap().value.unwrap();
        assert!(
            ns.contains("user") || ns.contains("default"),
            "Session 2 should still be in default namespace, got: {ns}"
        );

        // Switch session 2 to a different namespace
        let result = common::eval(&mut worker, &session2, "(ns test.session2)");
        assert!(result.is_ok(), "Failed to switch namespace in session 2");
        assert_eq!(
            result.unwrap().ns,
            Some("test.session2".to_string()),
            "Session 2 should be in test.session2 namespace"
        );

        // Verify session 1 is still in its original namespace
        let result = common::eval(&mut worker, &session1, "(str *ns*)");
        assert!(result.is_ok(), "Failed to check namespace in session 1");
        let ns = result.unwrap().value.unwrap();
        assert!(
            ns.contains("test.session1"),
            "Session 1 should still be in test.session1, got: {ns}"
        );
    }

    /// Test that `close-session` retires the session on the server
    ///
    /// The worker keeps no session registry of its own, so this checks the
    /// authoritative thing: after closing, the server's own `ls-sessions` no
    /// longer lists the closed session, and still lists the surviving one.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_close_session_retires_it_on_the_server() {
        let worker = common::connect_worker();

        let session1 = common::clone_session(&worker).expect("Failed to clone session 1");
        let session2 = common::clone_session(&worker).expect("Failed to clone session 2");
        let session1_id = session1.id().to_string();
        let session2_id = session2.id().to_string();

        let listed = common::ls_sessions(&worker).expect("ls-sessions failed");
        assert!(
            listed.contains(&session1_id) && listed.contains(&session2_id),
            "Server should list both new sessions, got: {listed:?}"
        );

        common::close_session(&worker, session1).expect("Failed to close session1");

        let listed = common::ls_sessions(&worker).expect("ls-sessions failed");
        assert!(
            !listed.contains(&session1_id),
            "Closed session should no longer be listed, got: {listed:?}"
        );
        assert!(
            listed.contains(&session2_id),
            "Surviving session should still be listed, got: {listed:?}"
        );

        common::close_session(&worker, session2).expect("Failed to close session2");

        let listed = common::ls_sessions(&worker).expect("ls-sessions failed");
        assert!(
            !listed.contains(&session2_id),
            "Both sessions should be retired, got: {listed:?}"
        );
    }

    /// Test that a session is usable from more than one connection
    ///
    /// A `Session` is just a wire id, so a session cloned on one connection can
    /// be evaluated against from a second connection to the same server, and
    /// both see the same bindings.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_session_shared_across_connections() {
        let (mut worker1, session) = common::connect();
        let mut worker2 = common::connect_worker();

        let result1 = common::eval(&mut worker1, &session, "(def shared-var 42)");
        assert!(
            result1.is_ok(),
            "Worker1 should be able to eval on its own session"
        );

        let result2 = common::eval(&mut worker2, &session, "shared-var");
        assert!(
            result2.is_ok(),
            "Worker2 should be able to eval on the shared session"
        );
        assert_eq!(
            result2.unwrap().value,
            Some("42".to_string()),
            "Worker2 should see the variable defined by worker1 (same session)"
        );
    }

    /// Test describe operation to verify server capabilities
    ///
    /// This test queries the server for supported operations, specifically checking
    /// for completions and lookup operations which are provided by middleware.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_describe_operations() {
        let worker = common::connect_worker();

        let info = common::describe(&worker, true).expect("Failed to describe server");

        // Print server info for debugging
        println!("\n=== Server Information ===");
        if let Some(ref versions) = info.versions {
            println!("Versions: {versions:?}");
        }
        if let Some(ref aux) = info.aux {
            println!("Auxiliary data: {aux:?}");
        }

        // Check and print available operations
        if let Some(ref ops) = info.ops {
            println!("\nAvailable operations ({} total):", ops.len());
            for (op, details) in ops {
                println!("  - {op}: {details:?}");
            }

            // Verify completions and lookup are present
            assert!(
                ops.contains_key("completions"),
                "Server should support 'completions' operation (provided by nrepl.middleware.completion)"
            );
            assert!(
                ops.contains_key("lookup"),
                "Server should support 'lookup' operation (provided by nrepl.middleware.lookup)"
            );

            // Also verify other expected operations
            assert!(ops.contains_key("eval"), "Server should support 'eval'");
            assert!(ops.contains_key("clone"), "Server should support 'clone'");
            assert!(
                ops.contains_key("describe"),
                "Server should support 'describe'"
            );
        } else {
            panic!("Server describe response missing 'ops' field");
        }
    }

    /// Test that `ls-sessions` lists the sessions we cloned
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_ls_sessions() {
        let worker = common::connect_worker();
        let session = common::clone_session(&worker).expect("Failed to clone session");

        let listed = common::ls_sessions(&worker).expect("ls-sessions failed");
        assert!(
            listed.contains(&session.id().to_string()),
            "Server should list the cloned session, got: {listed:?}"
        );
    }

    /// Test basic completions functionality
    ///
    /// Verifies that the completions operation returns results for a simple prefix.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_completions_basic() {
        let (worker, session) = common::connect();

        let completions = common::completions(&worker, &session, "ma", None, None)
            .expect("Completions request failed");

        assert!(!completions.is_empty(), "Should return completions");
        assert!(
            completions.iter().any(|c| c.candidate.contains("map")),
            "Should include 'map' in completions for 'ma', got: {:?}",
            completions.iter().map(|c| &c.candidate).collect::<Vec<_>>()
        );
    }

    /// Test completions with specific namespace
    ///
    /// Verifies that completions can be scoped to a specific namespace.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_completions_with_namespace() {
        let (worker, session) = common::connect();

        let completions = common::completions(
            &worker,
            &session,
            "red",
            Some("clojure.core".to_string()),
            None,
        )
        .expect("Completions request failed");

        assert!(
            completions.iter().any(|c| c.candidate.contains("reduce")),
            "Should find 'reduce' in clojure.core, got: {:?}",
            completions.iter().map(|c| &c.candidate).collect::<Vec<_>>()
        );
    }

    /// Test completions with empty prefix
    ///
    /// Verifies that empty prefix returns many completions (all available symbols).
    ///
    /// Note: babashka returns nothing for an empty prefix, so this test only
    /// passes against a JVM Clojure nREPL server.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_completions_empty_prefix() {
        let (worker, session) = common::connect();

        let completions = common::completions(&worker, &session, "", None, None)
            .expect("Completions request failed");

        assert!(
            !completions.is_empty(),
            "Empty prefix should return completions"
        );
        // Should return many symbols from clojure.core
        assert!(
            completions.len() > 100,
            "Empty prefix should return many completions, got: {}",
            completions.len()
        );
    }

    /// Test basic lookup functionality
    ///
    /// Verifies that lookup returns symbol information for a known function.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_lookup_basic() {
        let (worker, session) = common::connect();

        let response =
            common::lookup(&worker, &session, "map", None, None).expect("Lookup request failed");

        assert!(response.info.is_some(), "Should return symbol info");

        let info = response.info.unwrap();
        assert!(
            info.contains_key("doc") || info.contains_key("arglists"),
            "Should include doc or arglists, got: {:?}",
            info.keys().collect::<Vec<_>>()
        );
    }

    /// Test lookup with qualified symbol
    ///
    /// Verifies that lookup works with fully-qualified symbols.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_lookup_qualified_symbol() {
        let (worker, session) = common::connect();

        let response = common::lookup(&worker, &session, "clojure.core/map", None, None)
            .expect("Lookup request failed");

        let info = response
            .info
            .expect("Should return symbol info for clojure.core/map");
        assert!(
            info.contains_key("ns"),
            "Should include namespace in info, got: {:?}",
            info.keys().collect::<Vec<_>>()
        );
        assert!(
            info.get("ns").is_some_and(|s| s.contains("clojure.core")),
            "Namespace should be clojure.core, got: {:?}",
            info.get("ns")
        );
    }

    /// Test lookup with unknown symbol
    ///
    /// Verifies graceful handling of unknown symbols.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_lookup_unknown_symbol() {
        let (worker, session) = common::connect();

        let response = common::lookup(
            &worker,
            &session,
            "definitely-not-a-real-symbol-12345",
            None,
            None,
        )
        .expect("Lookup request should succeed even for unknown symbols");

        // Server might return empty info or status indicating not found
        // This tests graceful handling - either way is acceptable
        if let Some(info) = response.info {
            assert!(
                info.is_empty() || !info.contains_key("doc"),
                "Unknown symbol should not have documentation"
            );
        }
    }

    /// Test that an in-flight eval can be interrupted
    ///
    /// This is the demux model's reason for existing: the control op is written
    /// while the eval is still parked accumulating responses.
    ///
    /// Note: babashka's nREPL server does not implement `interrupt`, so this
    /// test only passes against a JVM Clojure nREPL server.
    #[test]
    #[ignore = "requires a running nREPL server"]
    fn test_interrupt_running_eval() {
        use nrepl_rs::worker::WorkerCommand;
        use std::sync::mpsc::channel;

        let (mut worker, session) = common::connect();

        // Submit a long sleep with a timeout well beyond it, so anything that
        // ends the eval early must be the interrupt.
        let request_id = worker
            .submit_eval(
                session.clone(),
                "(Thread/sleep 30000)".to_string(),
                Some(Duration::from_mins(1)),
                None,
                None,
                None,
            )
            .expect("submit_eval failed");

        // Give the server a moment to actually start the eval
        std::thread::sleep(Duration::from_millis(500));

        let (reply_tx, reply_rx) = channel();
        worker
            .command_sender()
            .send(WorkerCommand::Interrupt {
                op_id: worker.next_id(),
                session: session.clone(),
                target: request_id,
                reply: reply_tx,
            })
            .expect("worker thread gone");
        reply_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("interrupt reply timed out")
            .expect("interrupt failed");

        // The eval should now finish well inside its 60s timeout
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if worker.try_recv_response(request_id).is_some() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "interrupted eval never completed"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
