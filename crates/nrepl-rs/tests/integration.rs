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
}
