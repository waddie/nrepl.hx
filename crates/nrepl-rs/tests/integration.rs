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
//! These tests require a running nREPL server.
//!
//! To run:
//! 1. Start nREPL server (example using Clojure):
//!    clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//!
//! 2. Run tests:
//!    cargo test -p nrepl-rs --test integration -- --test-threads=1

// These tests are ignored by default since they require external setup
// Run with: cargo test -p nrepl-rs -- --ignored

#[cfg(test)]
mod real_server_tests {
    use nrepl_rs::{NReplClient, NReplError};

    /// Helper to connect to test server
    async fn connect_test_server() -> Result<NReplClient, NReplError> {
        NReplClient::connect("localhost:7888").await
    }

    #[tokio::test]
    #[ignore]
    async fn test_connect_to_real_server() {
        let client = connect_test_server().await;
        assert!(client.is_ok(), "Failed to connect to nREPL server");
    }

    #[tokio::test]
    #[ignore]
    async fn test_clone_session() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client.clone_session().await;
        assert!(session.is_ok(), "Failed to clone session");
        let session = session.unwrap();
        assert!(!session.id().is_empty(), "Session ID should not be empty");
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_simple_expression() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        let result = client.eval(&session, "(+ 1 2)").await;
        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()), "Expected value 3");
        assert!(result.error.is_empty(), "Should have no errors");
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_with_output() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        let result = client
            .eval(&session, r#"(do (println "hello") (+ 1 2))"#)
            .await;
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

    #[tokio::test]
    #[ignore]
    async fn test_eval_multiple_expressions() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // First eval
        let result1 = client.eval(&session, "(def x 42)").await;
        assert!(result1.is_ok(), "First eval failed");

        // Second eval should see the def from first
        let result2 = client.eval(&session, "x").await;
        assert!(result2.is_ok(), "Second eval failed");
        assert_eq!(result2.unwrap().value, Some("42".to_string()));
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_error() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Try to evaluate invalid code
        let result = client.eval(&session, "(/ 1 0)").await;

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

    #[tokio::test]
    #[ignore]
    async fn test_eval_with_namespace() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        let result = client.eval(&session, "(ns test.ns) (+ 1 2)").await;
        assert!(result.is_ok(), "Eval with ns failed");

        let result = result.unwrap();
        assert_eq!(result.value, Some("3".to_string()));
        assert_eq!(
            result.ns,
            Some("test.ns".to_string()),
            "Should switch to test.ns namespace"
        );
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_with_default_timeout_succeeds() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Quick operation should complete within default 60s timeout
        let result = client.eval(&session, "(+ 1 2)").await;
        assert!(
            result.is_ok(),
            "Quick eval should succeed with default timeout"
        );
        assert_eq!(result.unwrap().value, Some("3".to_string()));
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_with_custom_timeout_succeeds() {
        use std::time::Duration;

        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Quick operation should complete within 5 second timeout
        let result = client
            .eval_with_timeout(&session, "(+ 1 2)", Duration::from_secs(5))
            .await;
        assert!(
            result.is_ok(),
            "Quick eval should succeed with custom timeout"
        );
        assert_eq!(result.unwrap().value, Some("3".to_string()));
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_timeout_fires() {
        use std::time::Duration;

        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Try to sleep for 5 seconds with a 1 second timeout
        // This should timeout
        let result = client
            .eval_with_timeout(&session, "(Thread/sleep 5000)", Duration::from_secs(1))
            .await;

        assert!(result.is_err(), "Long-running eval should timeout");

        let err = result.unwrap_err();
        match err {
            NReplError::Timeout { operation, duration } => {
                assert_eq!(operation, "eval", "Error should be for eval operation");
                assert_eq!(duration, Duration::from_secs(1), "Error should report correct timeout duration");
            }
            other => panic!("Expected Timeout error, got: {:?}", other),
        }
    }

    #[tokio::test]
    #[ignore]
    async fn test_eval_timeout_boundary() {
        use std::time::Duration;

        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Sleep for 100ms with a 5 second timeout - should succeed
        // Note: We use a generous timeout to account for network and processing overhead
        let result = client
            .eval_with_timeout(&session, "(Thread/sleep 100)", Duration::from_secs(5))
            .await;

        assert!(
            result.is_ok(),
            "Eval completing within timeout should succeed: {:?}",
            result.err()
        );
    }

    /// Test persistent buffer handling with multiple output chunks
    ///
    /// This test verifies that NReplClient's persistent buffer correctly handles
    /// multiple bencode messages that may arrive in rapid succession or within
    /// a single TCP read. The server typically sends multiple responses:
    /// - One or more messages with output/errors (status: [])
    /// - A final message with value and "done" status
    ///
    /// The persistent buffer ensures no messages are lost when multiple arrive
    /// in one TCP packet, and correctly handles partial messages split across reads.
    #[tokio::test]
    #[ignore]
    async fn test_buffer_handles_multiple_output_chunks() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Evaluate code that produces multiple output chunks
        // This will cause the server to send multiple response messages:
        // - Message with "chunk 1" output
        // - Message with "chunk 2" output
        // - Message with "chunk 3" output
        // - Final message with value and "done" status
        let result = client
            .eval(
                &session,
                r#"(do
                     (println "chunk 1")
                     (println "chunk 2")
                     (println "chunk 3")
                     (+ 1 2))"#,
            )
            .await;

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
    #[tokio::test]
    #[ignore]
    async fn test_buffer_handles_large_output() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Generate a large string (10KB) which may be split across multiple messages
        let result = client
            .eval(
                &session,
                r#"(apply str (repeat 10000 "x"))"#,
            )
            .await;

        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        assert!(result.value.is_some(), "Should have a value");
        let value = result.value.unwrap();
        assert_eq!(
            value.len(),
            10000,
            "Should return string of exactly 10000 characters"
        );
        assert!(
            value.chars().all(|c| c == 'x'),
            "String should contain only 'x' characters"
        );
    }

    /// Test persistent buffer with rapid sequential evaluations
    ///
    /// This tests that the buffer correctly handles back-to-back evaluations
    /// where responses might arrive in rapid succession or overlap.
    #[tokio::test]
    #[ignore]
    async fn test_buffer_handles_rapid_evaluations() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Perform multiple rapid evaluations
        for i in 1..=10 {
            let result = client
                .eval(&session, format!("(+ {} {})", i, i))
                .await;

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
    #[tokio::test]
    #[ignore]
    async fn test_buffer_handles_partial_messages() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Create a large code string (with comments to increase size)
        // The response will be large enough to likely span multiple TCP reads
        let large_code = format!(
            r#"(do
                 ;; Comment: {}
                 (let [data (apply str (repeat 1000 "test data "))]
                   (count data)))"#,
            "x".repeat(1000)
        );

        let result = client.eval(&session, large_code).await;

        assert!(result.is_ok(), "Eval failed: {:?}", result.err());

        let result = result.unwrap();
        // "test data " is 10 chars, repeated 1000 times = 10000
        assert_eq!(
            result.value,
            Some("10000".to_string()),
            "Should return correct count"
        );
    }

    /// Test MAX_OUTPUT_ENTRIES DoS protection
    ///
    /// Verifies that the client protects against DoS attacks via excessive output
    /// flooding. The limit is 10,000 output entries per evaluation.
    ///
    /// This prevents a malicious or buggy server from exhausting client memory
    /// by sending unlimited output responses.
    #[tokio::test]
    #[ignore]
    async fn test_max_output_entries_protection() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Try to generate more than 10,000 output entries
        // Each println creates one output entry
        // We use 10,100 to exceed the limit
        let result = client
            .eval(
                &session,
                r#"(dotimes [i 10100] (println i))"#,
            )
            .await;

        // The evaluation should fail with a protocol error about exceeding the limit
        assert!(
            result.is_err(),
            "Should fail when exceeding MAX_OUTPUT_ENTRIES (10,000)"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Protocol { ref message } => {
                assert!(
                    message.contains("maximum entries limit") || message.contains("10000") || message.contains("10,000"),
                    "Error should mention entries limit, got: {}",
                    message
                );
            }
            other => panic!("Expected Protocol error about entries limit, got: {:?}", other),
        }
    }

    /// Test that output under the limit works fine
    ///
    /// This verifies that evaluations producing output close to but under the
    /// MAX_OUTPUT_ENTRIES limit (10,000) complete successfully.
    #[tokio::test]
    #[ignore]
    async fn test_output_entries_under_limit() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Generate 1,000 output entries (well under the 10,000 limit)
        let result = client
            .eval(
                &session,
                r#"(dotimes [i 1000] (println i))"#,
            )
            .await;

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

    /// Test MAX_RESPONSE_SIZE DoS protection
    ///
    /// Verifies that the client protects against DoS attacks via extremely large
    /// responses. The limit is 10MB (10,485,760 bytes) for any single response.
    ///
    /// This prevents a malicious server from exhausting client memory by sending
    /// unlimited response data.
    #[tokio::test]
    #[ignore]
    async fn test_max_response_size_protection() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Try to generate a response larger than 10MB
        // 11MB = 11 * 1024 * 1024 = 11,534,336 bytes
        // We create a string of this size which will be sent back in the response
        let result = client
            .eval(
                &session,
                r#"(apply str (repeat 11534336 "x"))"#,
            )
            .await;

        // The evaluation should fail with a protocol error about exceeding size
        assert!(
            result.is_err(),
            "Should fail when response exceeds MAX_RESPONSE_SIZE (10MB)"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Protocol { ref message } => {
                assert!(
                    message.contains("maximum size") || message.contains("10") || message.contains("MB"),
                    "Error should mention size limit, got: {}",
                    message
                );
            }
            other => panic!("Expected Protocol error about size limit, got: {:?}", other),
        }
    }

    /// Test MAX_OUTPUT_TOTAL_SIZE DoS protection
    ///
    /// Verifies protection against excessive combined stdout+stderr output size.
    /// The limit is 10MB total for all output accumulated during an evaluation.
    ///
    /// This is separate from MAX_OUTPUT_ENTRIES (which limits number of entries)
    /// and prevents a few very large output strings from exhausting memory.
    #[tokio::test]
    #[ignore]
    async fn test_max_output_total_size_protection() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Try to print more than 10MB of output
        // Print 100 strings of 120KB each = 12MB total
        let result = client
            .eval(
                &session,
                r#"(dotimes [i 100]
                     (println (apply str (repeat 122880 "x"))))"#,
            )
            .await;

        // The evaluation should fail with a protocol error about total size
        assert!(
            result.is_err(),
            "Should fail when output exceeds MAX_OUTPUT_TOTAL_SIZE (10MB)"
        );

        let err = result.unwrap_err();
        match err {
            NReplError::Protocol { ref message } => {
                assert!(
                    message.contains("maximum total size") || message.contains("10") || message.contains("MB"),
                    "Error should mention total size limit, got: {}",
                    message
                );
            }
            other => panic!("Expected Protocol error about total size limit, got: {:?}", other),
        }
    }

    /// Test that large but acceptable responses work
    ///
    /// This verifies that responses close to but under the 10MB limit
    /// complete successfully.
    #[tokio::test]
    #[ignore]
    async fn test_response_size_under_limit() {
        let mut client = connect_test_server().await.expect("Failed to connect");
        let session = client
            .clone_session()
            .await
            .expect("Failed to clone session");

        // Generate a 1MB string (well under the 10MB limit)
        let result = client
            .eval(
                &session,
                r#"(apply str (repeat 1048576 "x"))"#,
            )
            .await;

        assert!(
            result.is_ok(),
            "Should succeed with 1MB response (under 10MB limit): {:?}",
            result.err()
        );

        let result = result.unwrap();
        assert!(result.value.is_some(), "Should have a value");
        let value = result.value.unwrap();
        assert_eq!(
            value.len(),
            1048576,
            "Should return 1MB string"
        );
    }

    /// Test session isolation
    ///
    /// Verifies that multiple sessions maintain independent evaluation contexts.
    /// Variables, namespaces, and state defined in one session should not be
    /// visible in another session.
    #[tokio::test]
    #[ignore]
    async fn test_session_isolation() {
        let mut client = connect_test_server().await.expect("Failed to connect");

        // Create two independent sessions
        let session1 = client
            .clone_session()
            .await
            .expect("Failed to clone session 1");
        let session2 = client
            .clone_session()
            .await
            .expect("Failed to clone session 2");

        // Verify sessions have different IDs
        assert_ne!(
            session1.id(),
            session2.id(),
            "Sessions should have different IDs"
        );

        // Define a variable in session 1
        let result = client.eval(&session1, "(def session1-var 42)").await;
        assert!(result.is_ok(), "Failed to define var in session 1");

        // Verify session 1 can see its own variable
        let result = client.eval(&session1, "session1-var").await;
        assert!(result.is_ok(), "Failed to eval var in session 1");
        assert_eq!(
            result.unwrap().value,
            Some("42".to_string()),
            "Session 1 should see its own variable"
        );

        // Verify session 2 CANNOT see session 1's variable
        let result = client.eval(&session2, "session1-var").await;
        // This should either fail or return an error in the result
        // (depending on server behavior - some return errors, some throw exceptions)
        if let Ok(result) = result {
            assert!(
                !result.error.is_empty() || result.value.is_none(),
                "Session 2 should not see session 1's variable"
            );
        }

        // Define a different variable in session 2
        let result = client.eval(&session2, "(def session2-var 99)").await;
        assert!(result.is_ok(), "Failed to define var in session 2");

        // Verify session 2 can see its own variable
        let result = client.eval(&session2, "session2-var").await;
        assert!(result.is_ok(), "Failed to eval var in session 2");
        assert_eq!(
            result.unwrap().value,
            Some("99".to_string()),
            "Session 2 should see its own variable"
        );

        // Verify session 1 CANNOT see session 2's variable
        let result = client.eval(&session1, "session2-var").await;
        if let Ok(result) = result {
            assert!(
                !result.error.is_empty() || result.value.is_none(),
                "Session 1 should not see session 2's variable"
            );
        }

        // Verify session 1 still has its original variable
        let result = client.eval(&session1, "session1-var").await;
        assert!(result.is_ok(), "Session 1 should still have its variable");
        assert_eq!(
            result.unwrap().value,
            Some("42".to_string()),
            "Session 1's variable should be unchanged"
        );
    }

    /// Test session namespace isolation
    ///
    /// Verifies that namespace changes in one session don't affect other sessions.
    #[tokio::test]
    #[ignore]
    async fn test_session_namespace_isolation() {
        let mut client = connect_test_server().await.expect("Failed to connect");

        // Create two independent sessions
        let session1 = client.clone_session().await.expect("Failed to clone session 1");
        let session2 = client.clone_session().await.expect("Failed to clone session 2");

        // Switch session 1 to a custom namespace
        let result = client.eval(&session1, "(ns test.session1)").await;
        assert!(result.is_ok(), "Failed to switch namespace in session 1");
        assert_eq!(
            result.unwrap().ns,
            Some("test.session1".to_string()),
            "Session 1 should be in test.session1 namespace"
        );

        // Verify session 2 is still in default namespace (user)
        let result = client.eval(&session2, "(str *ns*)").await;
        assert!(result.is_ok(), "Failed to check namespace in session 2");
        let ns = result.unwrap().value.unwrap();
        assert!(
            ns.contains("user") || ns.contains("default"),
            "Session 2 should still be in default namespace, got: {}",
            ns
        );

        // Switch session 2 to a different namespace
        let result = client.eval(&session2, "(ns test.session2)").await;
        assert!(result.is_ok(), "Failed to switch namespace in session 2");
        assert_eq!(
            result.unwrap().ns,
            Some("test.session2".to_string()),
            "Session 2 should be in test.session2 namespace"
        );

        // Verify session 1 is still in its original namespace
        let result = client.eval(&session1, "(str *ns*)").await;
        assert!(result.is_ok(), "Failed to check namespace in session 1");
        let ns = result.unwrap().value.unwrap();
        assert!(
            ns.contains("test.session1"),
            "Session 1 should still be in test.session1, got: {}",
            ns
        );
    }

    /// Test close_session removes from tracking
    ///
    /// Verifies that when a session is closed, it's properly removed from the
    /// client's internal session tracking. This prevents memory leaks and ensures
    /// operations fail appropriately on closed sessions.
    #[tokio::test]
    #[ignore]
    async fn test_close_session_removes_from_tracking() {
        let mut client = connect_test_server().await.expect("Failed to connect");

        // Verify we start with no sessions
        assert_eq!(
            client.sessions().len(),
            0,
            "Client should start with no sessions"
        );

        // Create a session
        let session1 = client
            .clone_session()
            .await
            .expect("Failed to clone session 1");
        let session1_id = session1.id().to_string();

        // Verify the session is tracked
        assert_eq!(
            client.sessions().len(),
            1,
            "Client should track 1 session"
        );
        assert!(
            client
                .sessions()
                .iter()
                .any(|s| s.id() == &session1_id),
            "Client should track session1"
        );

        // Create a second session
        let session2 = client
            .clone_session()
            .await
            .expect("Failed to clone session 2");
        let session2_id = session2.id().to_string();

        // Verify both sessions are tracked
        assert_eq!(
            client.sessions().len(),
            2,
            "Client should track 2 sessions"
        );

        // Close session1
        let close_result = client.close_session(session1).await;
        assert!(close_result.is_ok(), "Failed to close session1");

        // Verify session1 is no longer tracked
        assert_eq!(
            client.sessions().len(),
            1,
            "Client should track 1 session after closing one"
        );
        assert!(
            !client
                .sessions()
                .iter()
                .any(|s| s.id() == &session1_id),
            "Client should not track session1 after closing"
        );
        assert!(
            client
                .sessions()
                .iter()
                .any(|s| s.id() == &session2_id),
            "Client should still track session2"
        );

        // Verify session1 cannot be used after closing (by checking it's not in tracking)
        // Note: We can't actually eval on session1 because close_session() consumes it
        // The tracking check above is sufficient

        // Close session2
        let close_result = client.close_session(session2).await;
        assert!(close_result.is_ok(), "Failed to close session2");

        // Verify no sessions are tracked
        assert_eq!(
            client.sessions().len(),
            0,
            "Client should track 0 sessions after closing all"
        );
    }

    /// Test register_session and session tracking
    ///
    /// Verifies that register_session() properly adds a session to the client's
    /// internal tracking, enabling it to be used with operations like eval().
    #[tokio::test]
    #[ignore]
    async fn test_register_session_tracking() {
        let mut client1 = connect_test_server().await.expect("Failed to connect client1");
        let mut client2 = connect_test_server().await.expect("Failed to connect client2");

        // Client 1 creates a session
        let session = client1
            .clone_session()
            .await
            .expect("Failed to clone session");
        let session_id = session.id().to_string();

        // Verify client1 tracks the session
        assert_eq!(
            client1.sessions().len(),
            1,
            "Client1 should track 1 session"
        );

        // Verify client2 does NOT track the session yet
        assert_eq!(
            client2.sessions().len(),
            0,
            "Client2 should not track any sessions yet"
        );

        // Register the session with client2
        use nrepl_rs::Session;
        let shared_session = Session::new(session_id.clone());
        client2.register_session(shared_session.clone());

        // Verify client2 now tracks the session
        assert_eq!(
            client2.sessions().len(),
            1,
            "Client2 should track 1 session after registration"
        );
        assert!(
            client2
                .sessions()
                .iter()
                .any(|s| s.id() == &session_id),
            "Client2 should track the registered session"
        );

        // Verify both clients can use the session
        let result1 = client1.eval(&session, "(def shared-var 42)").await;
        assert!(result1.is_ok(), "Client1 should be able to eval on session");

        let result2 = client2.eval(&shared_session, "shared-var").await;
        assert!(result2.is_ok(), "Client2 should be able to eval on registered session");
        assert_eq!(
            result2.unwrap().value,
            Some("42".to_string()),
            "Client2 should see variable defined by client1 (same session)"
        );
    }
}
