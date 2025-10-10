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
//! These tests require a running Clojure nREPL server.
//!
//! To run:
//! 1. Start nREPL server:
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
        assert!(!session.id.is_empty(), "Session ID should not be empty");
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
        assert!(result.error.is_none(), "Should have no errors");
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
            result.error.is_some() || result.value.is_none(),
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
}
