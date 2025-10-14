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
//!         if !result.error.is_empty() {
//!             eprintln!("Evaluation error: {}", result.error.join("\n"));
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
//! if !result.error.is_empty() {
//!     eprintln!("Error loading file: {}", result.error.join("\n"));
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
//! ## Troubleshooting
//!
//! ### Connection Errors
//!
//! **Problem**: `Connection error: Connection refused`
//!
//! - **Check server is running**: Ensure an nREPL server is listening on the specified port
//! - **Check firewall**: Make sure the port is not blocked by a firewall
//! - **Verify address**: Double-check the host and port (e.g., `localhost:7888`)
//!
//! **Problem**: `Connection error: Connection reset by peer`
//!
//! - **Server crash**: The nREPL server may have crashed or been terminated
//! - **Network issues**: Check for network connectivity problems
//! - **Resource limits**: Server may have hit resource limits (file descriptors, memory)
//!
//! ### Timeout Errors
//!
//! **Problem**: `Operation timed out after 60s`
//!
//! - **Long-running code**: Increase timeout with `eval_with_timeout()`
//! - **Server hang**: Check if the server process is frozen or deadlocked
//! - **Network latency**: High network latency may require longer timeouts
//! - **Debug**: Enable `NREPL_DEBUG=1` to see if responses are being received
//!
//! ### Session Errors
//!
//! **Problem**: `Session not found: <session-id>`
//!
//! - **Session closed**: The session was closed with `close_session()`
//! - **Server restart**: The server restarted and lost session state
//! - **Wrong client**: Using a session from a different client instance
//!
//! ### Codec/Protocol Errors
//!
//! **Problem**: `Codec error at byte X: Invalid bencode`
//!
//! - **Server incompatibility**: Server may not be sending valid bencode
//! - **Network corruption**: Data may be corrupted in transit
//! - **Enable debug logging**: Set `NREPL_DEBUG=1` to inspect the raw data
//!
//! **Problem**: `Protocol error: Missing field in response`
//!
//! - **Old server version**: Server may be using an older nREPL protocol
//! - **Custom middleware**: Server middleware may be altering responses
//!
//! ### Performance Issues
//!
//! **Problem**: Operations are slower than expected
//!
//! - **Sequential operations**: Client processes requests sequentially (see docs)
//! - **Use connection pooling**: For concurrent operations, use multiple clients
//! - **Network latency**: Add caching or batch operations when possible
//! - **Server performance**: Check if the server itself is slow
//!
//! ### Memory Issues
//!
//! **Problem**: High memory usage or OOM errors
//!
//! - **Large responses**: Results/output may exceed 10MB limits
//! - **Session cleanup**: Remember to close sessions with `close_session()`
//! - **Connection cleanup**: Call `shutdown()` before dropping clients
//! - **Check output size**: Large print statements can consume significant memory
//!
//! ## Security Considerations
//!
//! ### Arbitrary Code Execution
//!
//! **WARNING**: nREPL allows arbitrary code execution on the server. When you evaluate
//! code using this client, it will be executed with the full privileges of the nREPL
//! server process.
//!
//! - **Never connect to untrusted servers** - Malicious servers could execute arbitrary
//!   code on your machine through response manipulation
//! - **Never evaluate untrusted input** - User-provided code will be executed on the
//!   server with full access to the server's environment
//! - **Use authentication** - nREPL servers should be protected by network firewalls
//!   or authentication mechanisms
//! - **Principle of least privilege** - Run nREPL servers with minimal privileges
//!
//! ### Network Security
//!
//! - nREPL uses **unencrypted TCP connections** by default
//! - Data (including code and results) is transmitted in plaintext
//! - Use SSH tunneling or VPNs when connecting over untrusted networks
//! - Bind nREPL servers to localhost (`127.0.0.1`) only when possible
//!
//! ### DoS Protection
//!
//! This client includes several protections against denial-of-service attacks:
//! - Maximum response size limits (10MB per message)
//! - Maximum output accumulation limits (10,000 entries, 10MB total)
//! - Incomplete read detection (prevents infinite loops on malformed messages)
//! - Configurable timeouts for all operations
//!
//! However, you should still:
//! - Only connect to trusted servers
//! - Set appropriate timeouts for long-running operations
//! - Monitor resource usage when evaluating untrusted code
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

/// Bencode codec implementation (internal)
///
/// This module is public only to allow access from integration tests and benchmarks.
/// It is hidden from documentation and should not be used by external code.
/// The codec functionality is used internally by NReplClient for message serialization.
///
/// **Note**: This is not part of the public API and may change without notice.
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
