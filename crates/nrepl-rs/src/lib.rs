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
//! ## The client is [`worker::Worker`]
//!
//! [`worker::Worker`] owns a background thread running a single-threaded Tokio
//! runtime. That thread connects, splits the socket into a writer and a reader,
//! and then runs one `select!` loop over the command channel, the socket, and
//! the active eval's deadline.
//!
//! Two consequences follow, and they are the whole point of the design:
//!
//! - **Control ops work during an eval.** Responses are demultiplexed by
//!   request id, so an `interrupt` or `stdin` is written immediately rather
//!   than queueing behind the eval it is meant to affect. A sequential client
//!   cannot do this: its interrupt would not go out until the eval it was
//!   cancelling had already finished.
//! - **Synchronous hosts can drive it.** Evals are submitted with
//!   [`submit_eval`](worker::Worker::submit_eval), which returns a request id
//!   immediately, and collected with
//!   [`try_recv_response`](worker::Worker::try_recv_response), which never
//!   blocks. This is what lets the Steel/Helix plugin poll from its main
//!   thread.
//!
//! The connection type behind it is crate-internal: it is only `connect` plus
//! `into_split`, and has no op methods.
//!
//! ## Quick Start
//!
//! ```no_run
//! use nrepl_rs::worker::{EvalOutcome, Worker, WorkerCommand};
//! use std::sync::mpsc::channel;
//! use std::time::Duration;
//!
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! // Connect (spawns the worker thread)
//! let mut worker = Worker::new();
//! worker.connect_blocking("localhost:7888".to_string())?;
//!
//! // Clone a session: send the command with a one-shot reply channel
//! let (reply_tx, reply_rx) = channel();
//! worker.command_sender().send(WorkerCommand::CloneSession {
//!     op_id: worker.next_id(),
//!     reply: reply_tx,
//! })?;
//! let session = reply_rx.recv_timeout(Duration::from_secs(30))??;
//!
//! // Submit an eval, then poll for its result
//! let request_id = worker.submit_eval(
//!     session,
//!     "(+ 1 2)".to_string(),
//!     Some(Duration::from_secs(30)),
//!     None, None, None,
//! )?;
//!
//! loop {
//!     if let Some(response) = worker.try_recv_response(request_id) {
//!         if let EvalOutcome::Done(result) = response.outcome {
//!             println!("Result: {:?}", result?.value); // Some("3")
//!         }
//!         break;
//!     }
//!     std::thread::sleep(Duration::from_millis(10));
//! }
//! # Ok(())
//! # }
//! ```
//!
//! See `examples/simple_eval.rs` for a runnable version, and `tests/common` for
//! blocking helpers wrapping each [`worker::WorkerCommand`].
//!
//! ## Architecture
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
//! message ID. The worker routes each response to that id's pending entry and
//! folds it in until a "done" status arrives.
//!
//! ### Session Management
//!
//! Sessions are server-side resources that maintain evaluation state:
//! - **Namespace**: Each session tracks its current namespace
//! - **Bindings**: Variables defined in a session are isolated from other sessions
//! - **REPL State**: Line numbers, *1/*2/*3 values, etc.
//!
//! A [`Session`] is just a wire id, and the server is the authority on which
//! ids are live: the worker keeps no client-side session registry. Sessions
//! must be explicitly closed to free server resources. Evaluating against a
//! session the server has retired yields an empty result rather than an error,
//! so track liveness with `close-session` or `ls-sessions` if you need it.
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
//! A read error is terminal for the connection: the worker fails every pending
//! op with a [`NReplError::Connection`] carrying the underlying message.
//!
//! ## Supported Operations
//!
//! Evals are submitted with [`submit_eval`](worker::Worker::submit_eval) and
//! [`submit_load_file`](worker::Worker::submit_load_file). Everything else is a
//! [`worker::WorkerCommand`] variant carrying a reply channel:
//!
//! - [`Interrupt`](worker::WorkerCommand::Interrupt) - Interrupt an ongoing evaluation
//! - [`Stdin`](worker::WorkerCommand::Stdin) - Answer an eval's `need-input`
//! - [`CloneSession`](worker::WorkerCommand::CloneSession) - Create a new session
//! - [`CloseSession`](worker::WorkerCommand::CloseSession) - Close a session
//! - [`Describe`](worker::WorkerCommand::Describe) - Query server capabilities
//! - [`LsSessions`](worker::WorkerCommand::LsSessions) - List the server's sessions
//! - [`Completions`](worker::WorkerCommand::Completions) - Request code completions
//! - [`Lookup`](worker::WorkerCommand::Lookup) - Look up symbol information
//!
//! ## Debug Logging
//!
//! Set the `NREPL_DEBUG` environment variable to enable detailed debug logging:
//!
//! ```sh
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
//! ### Security Warning
//!
//! **⚠️ Debug logs may contain sensitive information:**
//! - Source code being evaluated (may include secrets, credentials, API keys)
//! - Evaluation results and output
//! - Session IDs
//! - Buffer contents in hexadecimal format
//!
//! **Never enable debug logging in production environments.** Only use it during
//! development and debugging, and ensure debug logs are not committed to version
//! control or exposed to unauthorized users.
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
//! - **Long-running code**: pass a larger `timeout` to `submit_eval`
//! - **Server hang**: Check if the server process is frozen or deadlocked
//! - **Network latency**: High network latency may require longer timeouts
//! - **Debug**: Enable `NREPL_DEBUG=1` to see if responses are being received
//!
//! ### Session Errors
//!
//! **Problem**: `Session not found: <session-id>`
//!
//! - **Session closed**: The session was closed with `CloseSession`
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
//! - **Evals are serialized**: one eval runs at a time per worker; control ops
//!   (interrupt, stdin, completions, lookup) bypass that queue
//! - **Use more connections**: for parallel evaluation, run a worker per connection
//! - **Network latency**: Add caching or batch operations when possible
//! - **Server performance**: Check if the server itself is slow
//!
//! ### Memory Issues
//!
//! **Problem**: High memory usage or OOM errors
//!
//! - **Large responses**: Results/output may exceed 10MB limits
//! - **Session cleanup**: Remember to close sessions with `CloseSession`
//! - **Connection cleanup**: Call [`shutdown`](worker::Worker::shutdown) before dropping a worker
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
//! ### `DoS` Protection
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
mod session;

/// nREPL operation request builders, used by [`worker`] to construct requests
/// with explicit ids.
pub(crate) mod ops;

/// Demux worker: the client. Owns the socket halves and all protocol
/// operations, so interrupt and stdin can be written while an eval is in
/// flight.
pub mod worker;

/// Bencode codec implementation (internal)
///
/// This module is public only to allow access from integration tests and benchmarks.
/// It is hidden from documentation and should not be used by external code.
/// The codec functionality is used internally for message serialization.
///
/// **Note**: This is not part of the public API and may change without notice.
#[doc(hidden)]
pub mod codec;

pub use error::{NReplError, Result};
pub use message::{CompletionCandidate, EvalResult, Response};
pub use session::Session;

#[cfg(test)]
mod tests {
    #[test]
    fn it_compiles() {
        // Basic compilation test - passes if it compiles
    }
}
