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

//! # nREPL Client Library
//!
//! A fully-featured async [nREPL](https://nrepl.org/) client implementation for Rust.
//!
//! ## Overview
//!
//! nREPL (Network REPL) is a network protocol for interacting with Read-Eval-Print Loop (REPL)
//! servers. While originally created for Clojure, nREPL implementations exist for many languages
//! including ClojureScript, Babashka, Python (nrepl-python), and others.
//!
//! This library provides an async Rust client that can connect to any nREPL server and perform
//! common operations like code evaluation, session management, code completion, symbol lookup,
//! and middleware management.
//!
//! ## Features
//!
//! - **Async/await support** - Built on Tokio for non-blocking I/O
//! - **Session management** - Create, clone, and close isolated evaluation sessions
//! - **Code evaluation** - Execute code with configurable timeouts and rich result metadata
//! - **File loading** - Load files with proper path context for better error reporting
//! - **Interactive operations** - Code completion, symbol lookup, stdin support
//! - **Middleware management** - Query, add, and swap nREPL middleware dynamically
//! - **Error handling** - Comprehensive error types with context and debugging info
//! - **Bencode protocol** - Efficient binary protocol for message serialization
//!
//! ## Quick Start
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     // Connect to an nREPL server
//!     let mut client = NReplClient::connect("localhost:7888").await?;
//!
//!     // Create a session for evaluation
//!     let session = client.clone_session().await?;
//!
//!     // Evaluate code and get the result
//!     let result = client.eval(&session, "(+ 1 2)").await?;
//!     println!("Result: {:?}", result.value); // Some("3")
//!
//!     // Clean up
//!     client.close_session(session).await?;
//!     Ok(())
//! }
//! ```
//!
//! ## Examples
//!
//! ### Basic Evaluation
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//! let session = client.clone_session().await?;
//!
//! // Simple expression
//! let result = client.eval(&session, "(* 6 7)").await?;
//! assert_eq!(result.value, Some("42".to_string()));
//!
//! // Expression with side effects
//! let result = client.eval(&session, r#"(do (println "Hello!") :done)"#).await?;
//! assert_eq!(result.output, vec!["Hello!\n"]);
//! assert_eq!(result.value, Some(":done".to_string()));
//! # Ok(())
//! # }
//! ```
//!
//! ### Custom Timeouts
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//! use std::time::Duration;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//! let session = client.clone_session().await?;
//!
//! // Quick operation with short timeout
//! let result = client.eval_with_timeout(
//!     &session,
//!     "(+ 1 2)",
//!     Duration::from_secs(5)
//! ).await?;
//!
//! // Long-running operation with extended timeout
//! let result = client.eval_with_timeout(
//!     &session,
//!     "(Thread/sleep 10000)", // Sleep for 10 seconds
//!     Duration::from_secs(15)
//! ).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ### Error Handling
//!
//! ```no_run
//! use nrepl_rs::{NReplClient, NReplError};
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//! let session = client.clone_session().await?;
//!
//! // Handle evaluation errors
//! match client.eval(&session, "(/ 1 0)").await {
//!     Ok(result) => {
//!         if let Some(error) = result.error {
//!             eprintln!("Evaluation error: {}", error);
//!         }
//!     }
//!     Err(NReplError::Timeout { operation, duration }) => {
//!         eprintln!("Operation {} timed out after {:?}", operation, duration);
//!     }
//!     Err(e) => {
//!         eprintln!("Connection error: {}", e);
//!     }
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ### Loading Files
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//! let session = client.clone_session().await?;
//!
//! // Load a file with path context for better error messages
//! let code = std::fs::read_to_string("src/core.clj")?;
//! let result = client.load_file(
//!     &session,
//!     code,
//!     Some("/full/path/to/src/core.clj".to_string()),
//!     Some("core.clj".to_string())
//! ).await?;
//!
//! if let Some(error) = result.error {
//!     eprintln!("Error loading file: {}", error);
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ### Multiple Sessions
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//!
//! // Create independent sessions with isolated state
//! let session1 = client.clone_session().await?;
//! let session2 = client.clone_session().await?;
//!
//! // Each session has its own namespace and bindings
//! client.eval(&session1, "(def x 10)").await?;
//! client.eval(&session2, "(def x 20)").await?;
//!
//! let result1 = client.eval(&session1, "x").await?;
//! let result2 = client.eval(&session2, "x").await?;
//!
//! assert_eq!(result1.value, Some("10".to_string()));
//! assert_eq!(result2.value, Some("20".to_string()));
//! # Ok(())
//! # }
//! ```
//!
//! ### Code Completion
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut client = NReplClient::connect("localhost:7888").await?;
//! let session = client.clone_session().await?;
//!
//! // Get completions for a prefix
//! let completions = client.completions(&session, "map-", None, None).await?;
//! for completion in completions {
//!     println!("  {}", completion); // map-indexed, mapcat, mapv, etc.
//! }
//! # Ok(())
//! # }
//! ```
//!
//! ## Architecture
//!
//! ### Connection Model
//!
//! The [`NReplClient`] maintains a single TCP connection to the nREPL server. All operations
//! are performed sequentially over this connection (see "Sequential Operations" below).
//!
//! ### Message Protocol
//!
//! nREPL uses [bencode](https://en.wikipedia.org/wiki/Bencode) for message serialization.
//! Each message contains:
//! - An `op` field specifying the operation (e.g., "eval", "clone", "close")
//! - An `id` field for correlating requests with responses
//! - Operation-specific fields (code, session, etc.)
//!
//! Responses may arrive as multiple messages (for streaming output), all sharing the same
//! message ID. The client collects these until receiving a "done" status.
//!
//! ### Session Management
//!
//! Sessions are server-side resources that maintain evaluation state:
//! - **Namespace**: Each session tracks its current namespace
//! - **Bindings**: Variables defined in a session are isolated from other sessions
//! - **REPL State**: Line numbers, *1/*2/*3 values, etc.
//!
//! Sessions must be explicitly closed to free server resources. The client tracks active
//! sessions and validates them before use.
//!
//! ### Sequential Operations
//!
//! **IMPORTANT**: The client performs operations sequentially, not concurrently. All methods
//! take `&mut self`, preventing concurrent calls at compile time.
//!
//! This design is necessary because:
//! - Operations share a single TCP stream and internal buffer
//! - Responses are matched to requests by message ID
//! - Concurrent operations would compete for responses, causing timeouts and data loss
//!
//! For concurrent evaluation, use multiple client instances (one per connection) or
//! implement a worker thread pattern (see [`NReplClient`] documentation).
//!
//! ### Error Handling
//!
//! The [`NReplError`] enum provides detailed error information:
//! - **Connection errors**: Network failures, server disconnects
//! - **Codec errors**: Malformed bencode messages (with position and buffer preview)
//! - **Protocol errors**: Invalid responses, missing required fields
//! - **Timeout errors**: Operations exceeding their timeout duration
//! - **Session errors**: Invalid or closed sessions
//! - **Operation errors**: Server-reported failures
//!
//! ## Supported Operations
//!
//! - [`eval`](NReplClient::eval) - Evaluate code in a session
//! - [`eval_with_timeout`](NReplClient::eval_with_timeout) - Evaluate with custom timeout
//! - [`load_file`](NReplClient::load_file) - Load file contents with path context
//! - [`clone_session`](NReplClient::clone_session) - Create a new session
//! - [`close_session`](NReplClient::close_session) - Close a session
//! - [`interrupt`](NReplClient::interrupt) - Interrupt an ongoing evaluation
//! - [`describe`](NReplClient::describe) - Query server capabilities
//! - [`ls_sessions`](NReplClient::ls_sessions) - List active sessions
//! - [`stdin`](NReplClient::stdin) - Send stdin data to a session
//! - [`completions`](NReplClient::completions) - Request code completions
//! - [`lookup`](NReplClient::lookup) - Look up symbol information
//! - [`ls_middleware`](NReplClient::ls_middleware) - List loaded middleware
//! - [`add_middleware`](NReplClient::add_middleware) - Add middleware dynamically
//! - [`swap_middleware`](NReplClient::swap_middleware) - Replace middleware stack
//!
//! ## Debug Logging
//!
//! Set the `NREPL_DEBUG` environment variable to enable detailed debug logging:
//!
//! ```bash
//! NREPL_DEBUG=1 cargo run 2> nrepl-debug.log
//! ```
//!
//! Debug logs include:
//! - Code being evaluated (with byte counts)
//! - Request/response IDs for correlation
//! - Response status messages
//! - Buffer management operations
//! - Stream read activity
//!
//! ## License
//!
//! This library is licensed under the GNU Affero General Public License v3.0 or later.
//! See the LICENSE file for details.

mod connection;
mod error;
mod message;
mod ops;
mod session;

// Expose codec module for testing
#[doc(hidden)]
pub mod codec;

pub use connection::NReplClient;
pub use error::{NReplError, Result};
pub use message::{EvalResult, Request, Response};
pub use session::Session;

#[cfg(test)]
mod tests {
    #[test]
    fn it_compiles() {
        // Basic compilation test
        assert!(true);
    }
}
