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

/// nREPL client connection and operations
use crate::codec::{decode_response, encode_request};
use crate::error::{NReplError, Result};
use crate::message::{EvalResult, Request, Response};
use crate::ops::{
    add_middleware_request, clone_request, close_request, completions_request, describe_request,
    eval_request, interrupt_request, load_file_request, lookup_request, ls_middleware_request,
    ls_sessions_request, stdin_request, swap_middleware_request,
};
use crate::session::Session;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, ToSocketAddrs};
use tokio::time::timeout;

/// Check if debug logging is enabled via NREPL_DEBUG environment variable
fn debug_enabled() -> bool {
    static DEBUG: OnceLock<bool> = OnceLock::new();
    *DEBUG.get_or_init(|| std::env::var("NREPL_DEBUG").is_ok())
}

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if debug_enabled() {
            eprintln!($($arg)*);
        }
    };
}

/// Maximum size for a single nREPL response message (10MB)
/// This prevents OOM attacks from malicious servers sending infinite data
const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;

/// Default timeout for eval operations (60 seconds)
/// Can be overridden with eval_with_timeout
const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(60);

/// Main nREPL client
///
/// This client provides async access to an nREPL server over TCP. It handles bencode
/// serialization, response buffering, and session management.
///
/// # Sequential Operation Requirement
///
/// **IMPORTANT**: This client is designed for sequential operations only. All methods
/// take `&mut self`, which means you can only perform one operation at a time on a
/// single client instance.
///
/// ## Why Sequential?
///
/// Operations share a single TCP stream and internal buffer. When an operation like
/// `eval()` sends a request, it enters a loop reading responses until it receives
/// the "done" status for its specific message ID. During this time:
/// - The client continuously reads from the TCP stream
/// - Responses for other message IDs are skipped
/// - The internal buffer may contain partial or multiple messages
///
/// If multiple operations ran concurrently, they would compete for responses from
/// the shared stream, leading to:
/// - Lost responses (one operation consuming another's data)
/// - Timeouts (operations waiting for responses that were already consumed)
/// - Incorrect results (mismatched message IDs)
///
/// ## The `&mut self` Signature
///
/// The `&mut self` signature **enforces** this limitation at compile time. You cannot
/// accidentally run concurrent operations on the same client:
///
/// ```compile_fail
/// # use nrepl_rs::NReplClient;
/// # async fn example(client: &mut NReplClient, session: &nrepl_rs::Session) {
/// let eval1 = client.eval(session, "code1");  // Borrows client mutably
/// let eval2 = client.eval(session, "code2");  // ERROR: client already borrowed
/// # }
/// ```
///
/// ## Concurrent Operations
///
/// If you need to run multiple operations concurrently, you have two options:
///
/// ### Option 1: Multiple Connections
///
/// Create separate client instances, each with its own TCP connection:
///
/// ```no_run
/// # use nrepl_rs::NReplClient;
/// # #[tokio::main]
/// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
/// let mut client1 = NReplClient::connect("localhost:7888").await?;
/// let mut client2 = NReplClient::connect("localhost:7888").await?;
///
/// let session1 = client1.clone_session().await?;
/// let session2 = client2.clone_session().await?;
///
/// // Now you can run operations concurrently on different clients
/// let (result1, result2) = tokio::join!(
///     client1.eval(&session1, "(+ 1 2)"),
///     client2.eval(&session2, "(* 3 4)")
/// );
/// # Ok(())
/// # }
/// ```
///
/// ### Option 2: Worker Thread Pattern
///
/// Use a dedicated worker thread with message passing (see `steel-nrepl` crate for
/// an example implementation):
/// - Worker thread owns the client and processes requests sequentially
/// - Main thread submits requests via channels and polls for results
/// - This prevents blocking the main thread during long evaluations
///
/// ## Session Management
///
/// Note that sessions are server-side resources. Multiple client connections can
/// share the same session by using the same session ID, but be aware that:
/// - Session state (namespace, bindings) is shared
/// - Evaluations in the same session affect each other
/// - For true isolation, use separate sessions
pub struct NReplClient {
    stream: TcpStream,
    sessions: HashMap<String, Session>,
    buffer: Vec<u8>, // Persistent buffer for handling multiple messages in one TCP read
}

impl NReplClient {
    /// Connect to an nREPL server
    ///
    /// Establishes a TCP connection to an nREPL server at the specified address.
    ///
    /// # Arguments
    ///
    /// * `addr` - The server address (e.g., "localhost:7888" or "127.0.0.1:7888")
    ///
    /// # Returns
    ///
    /// Returns a new `NReplClient` instance if the connection succeeds.
    ///
    /// # Errors
    ///
    /// Returns `NReplError::Connection` if the connection fails (e.g., server not running,
    /// invalid address, network error).
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// // Connect to local nREPL server
    /// let client = NReplClient::connect("localhost:7888").await?;
    /// println!("Connected to nREPL server");
    /// # Ok(())
    /// # }
    /// ```
    pub async fn connect(addr: impl ToSocketAddrs) -> Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Self {
            stream,
            sessions: HashMap::new(),
            buffer: Vec::new(),
        })
    }

    /// Clone a new session from the server
    ///
    /// Creates a new nREPL session on the server. Sessions maintain independent evaluation
    /// contexts, including namespace, defined vars, and REPL state.
    ///
    /// # Returns
    ///
    /// Returns a `Session` object that can be used with evaluation operations.
    ///
    /// # Errors
    ///
    /// Returns `NReplError::OperationFailed` if the operation times out (30 seconds).
    /// Returns `NReplError::Protocol` if the server's response is malformed.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // Create a new session for evaluation
    /// let session = client.clone_session().await?;
    /// println!("Created session: {}", session.id);
    ///
    /// // You can create multiple independent sessions
    /// let session2 = client.clone_session().await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn clone_session(&mut self) -> Result<Session> {
        debug_log!("[nREPL DEBUG] Cloning new session...");
        let request = clone_request();
        debug_log!("[nREPL DEBUG] Sending clone request ID: {}", request.id);

        // Add timeout to clone operation (30 seconds should be plenty)
        let response = match timeout(Duration::from_secs(30), self.send_request(&request)).await {
            Ok(result) => result?,
            Err(_) => {
                return Err(NReplError::OperationFailed(
                    "Clone session timed out after 30s".to_string(),
                ));
            }
        };

        debug_log!("[nREPL DEBUG] Received clone response: {:?}", response);

        // Extract new-session ID from response
        let session_id = {
            let response_debug = format!("{:?}", response);
            response.new_session.ok_or_else(|| {
                NReplError::protocol_with_response(
                    "Missing new-session in clone response",
                    response_debug,
                )
            })?
        };

        debug_log!("[nREPL DEBUG] Successfully cloned session: {}", session_id);

        let session = Session::new(session_id.clone());
        self.sessions.insert(session_id, session.clone());

        Ok(session)
    }

    /// Validate that a session is still active
    ///
    /// Returns an error if the session has been closed or was never created by this client.
    fn validate_session(&self, session: &Session) -> Result<()> {
        if !self.sessions.contains_key(&session.id) {
            return Err(NReplError::SessionNotFound(session.id.clone()));
        }
        Ok(())
    }

    /// Evaluate code in a session with default timeout (60 seconds)
    ///
    /// Evaluates Clojure (or other nREPL language) code in the specified session and returns
    /// the result, including the value, stdout/stderr output, errors, and namespace.
    ///
    /// For custom timeout, use `eval_with_timeout`.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to evaluate in
    /// * `code` - The code to evaluate (any type that converts to `String`)
    ///
    /// # Returns
    ///
    /// Returns an `EvalResult` containing:
    /// - `value`: The return value as a string (if any)
    /// - `output`: List of stdout/stderr output strings
    /// - `error`: Error message (if evaluation failed)
    /// - `ns`: The namespace after evaluation
    ///
    /// # Errors
    ///
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    /// Returns `NReplError::OperationFailed` if the evaluation times out (60 seconds).
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Evaluate simple expression
    /// let result = client.eval(&session, "(+ 1 2)").await?;
    /// println!("Result: {:?}", result.value); // Some("3")
    ///
    /// // Evaluate with side effects
    /// let result = client.eval(&session, r#"(do (println "hello") 42)"#).await?;
    /// println!("Output: {:?}", result.output); // ["hello\n"]
    /// println!("Value: {:?}", result.value);   // Some("42")
    /// # Ok(())
    /// # }
    /// ```
    pub async fn eval(&mut self, session: &Session, code: impl Into<String>) -> Result<EvalResult> {
        self.eval_with_timeout(session, code, DEFAULT_EVAL_TIMEOUT)
            .await
    }

    /// Evaluate code in a session with custom timeout
    ///
    /// Like `eval()`, but allows specifying a custom timeout duration. Useful for
    /// long-running computations or when you need tighter control over timeouts.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to evaluate in
    /// * `code` - The code to evaluate
    /// * `timeout_duration` - Maximum time to wait for evaluation
    ///
    /// # Returns
    ///
    /// Returns an `EvalResult` with the same structure as `eval()`.
    ///
    /// # Errors
    ///
    /// Returns `NReplError::OperationFailed` if the timeout is exceeded.
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    /// use std::time::Duration;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Quick evaluation with 5 second timeout
    /// let result = client.eval_with_timeout(
    ///     &session,
    ///     "(+ 1 2)",
    ///     Duration::from_secs(5)
    /// ).await?;
    ///
    /// // Long-running task with extended timeout
    /// let result = client.eval_with_timeout(
    ///     &session,
    ///     "(Thread/sleep 30000)",
    ///     Duration::from_secs(60)
    /// ).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn eval_with_timeout(
        &mut self,
        session: &Session,
        code: impl Into<String>,
        timeout_duration: Duration,
    ) -> Result<EvalResult> {
        self.validate_session(session)?;
        let eval_future = self.eval_impl(session, code);

        match timeout(timeout_duration, eval_future).await {
            Ok(result) => result,
            Err(_) => Err(NReplError::OperationFailed(format!(
                "Evaluation timed out after {:?}",
                timeout_duration
            ))),
        }
    }

    /// Internal implementation of eval (without timeout wrapper)
    async fn eval_impl(
        &mut self,
        session: &Session,
        code: impl Into<String>,
    ) -> Result<EvalResult> {
        let code_str = code.into();
        debug_log!(
            "[nREPL DEBUG] Code to evaluate ({} bytes): {:?}",
            code_str.len(),
            code_str
        );
        debug_log!(
            "[nREPL DEBUG] Has trailing newline: {}",
            code_str.ends_with('\n')
        );

        let request = eval_request(&session.id, code_str);
        self.send_and_accumulate_responses(&request, "eval").await
    }

    /// Load a file in a session
    ///
    /// Evaluates the contents of a file in the specified session. This is similar to `eval()`
    /// but provides additional context (file path and name) that helps with error reporting
    /// and debugging on the server side.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to load the file in
    /// * `file_contents` - The contents of the file to load
    /// * `file_path` - Optional file path (for error messages and stack traces)
    /// * `file_name` - Optional file name (for error messages and stack traces)
    ///
    /// # Returns
    ///
    /// Returns an `EvalResult` with the same structure as `eval()`.
    ///
    /// # Errors
    ///
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Load a file with full context for better error messages
    /// let file_contents = std::fs::read_to_string("src/core.clj")?;
    /// let result = client.load_file(
    ///     &session,
    ///     file_contents,
    ///     Some("/path/to/project/src/core.clj".to_string()),
    ///     Some("core.clj".to_string())
    /// ).await?;
    ///
    /// if let Some(error) = result.error {
    ///     eprintln!("Error loading file: {}", error);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub async fn load_file(
        &mut self,
        session: &Session,
        file_contents: impl Into<String>,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> Result<EvalResult> {
        self.validate_session(session)?;
        let file_str = file_contents.into();
        debug_log!(
            "[nREPL DEBUG] Loading file ({} bytes): path={:?}, name={:?}",
            file_str.len(),
            file_path,
            file_name
        );

        let request = load_file_request(&session.id, file_str, file_path, file_name);
        self.send_and_accumulate_responses(&request, "load-file")
            .await
    }

    /// Interrupt an ongoing evaluation
    ///
    /// # Arguments
    /// * `session` - The session containing the evaluation to interrupt
    /// * `interrupt_id` - The message ID of the evaluation to interrupt
    ///
    /// # Errors
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    /// Returns `NReplError::Timeout` if the operation times out after 10 seconds.
    pub async fn interrupt(
        &mut self,
        session: &Session,
        interrupt_id: impl Into<String>,
    ) -> Result<()> {
        self.validate_session(session)?;
        let interrupt_id_str = interrupt_id.into();

        let interrupt_future = self.interrupt_impl(session, interrupt_id_str);

        match timeout(Duration::from_secs(10), interrupt_future).await {
            Ok(result) => result,
            Err(_) => Err(NReplError::Timeout {
                operation: "interrupt".to_string(),
                duration: Duration::from_secs(10),
            }),
        }
    }

    /// Internal implementation of interrupt (without timeout wrapper)
    async fn interrupt_impl(
        &mut self,
        session: &Session,
        interrupt_id: String,
    ) -> Result<()> {
        debug_log!(
            "[nREPL DEBUG] Interrupting evaluation: session={}, interrupt-id={}",
            session.id,
            interrupt_id
        );

        let request = interrupt_request(&session.id, interrupt_id);
        debug_log!("[nREPL DEBUG] Sending interrupt request ID: {}", request.id);

        // Send the request
        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Wait for acknowledgment (done status)
        loop {
            let response = self.read_response().await?;
            debug_log!(
                "[nREPL DEBUG] Received interrupt response ID: {}, status: {:?}",
                response.id,
                response.status
            );

            // Check if this response is for our request
            if response.id != request.id {
                debug_log!(
                    "[nREPL DEBUG] Skipping response - ID mismatch (expected: {}, got: {})",
                    request.id,
                    response.id
                );
                continue;
            }

            // Check for errors
            if let Some(err) = response.err {
                return Err(NReplError::OperationFailed(format!(
                    "Interrupt failed: {}",
                    err
                )));
            }

            // Check if we're done
            if response.status.iter().any(|s| s == "done") {
                debug_log!("[nREPL DEBUG] Interrupt completed successfully");
                return Ok(());
            }
        }
    }

    /// Close a session
    ///
    /// Closes an nREPL session and removes it from the server. After closing, the session
    /// can no longer be used for evaluation. The session is also removed from internal
    /// client tracking.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to close (consumes the session)
    ///
    /// # Errors
    ///
    /// Returns `NReplError::Timeout` if the operation times out after 10 seconds.
    /// Returns `NReplError::OperationFailed` if the server reports an error.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Use the session
    /// let result = client.eval(&session, "(+ 1 2)").await?;
    ///
    /// // Close when done
    /// client.close_session(session).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn close_session(&mut self, session: Session) -> Result<()> {
        let close_future = self.close_session_impl(session);

        match timeout(Duration::from_secs(10), close_future).await {
            Ok(result) => result,
            Err(_) => Err(NReplError::Timeout {
                operation: "close_session".to_string(),
                duration: Duration::from_secs(10),
            }),
        }
    }

    /// Internal implementation of close_session (without timeout wrapper)
    async fn close_session_impl(&mut self, session: Session) -> Result<()> {
        debug_log!("[nREPL DEBUG] Closing session: id={}", session.id);

        let request = close_request(&session.id);
        debug_log!("[nREPL DEBUG] Sending close request ID: {}", request.id);

        // Send the request
        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Wait for acknowledgment (done status)
        loop {
            let response = self.read_response().await?;
            debug_log!(
                "[nREPL DEBUG] Received close response ID: {}, status: {:?}",
                response.id,
                response.status
            );

            // Check if this response is for our request
            if response.id != request.id {
                debug_log!(
                    "[nREPL DEBUG] Skipping response - ID mismatch (expected: {}, got: {})",
                    request.id,
                    response.id
                );
                continue;
            }

            // Check for errors
            if let Some(err) = response.err {
                return Err(NReplError::OperationFailed(format!(
                    "Close session failed: {}",
                    err
                )));
            }

            // Check if we're done
            if response.status.iter().any(|s| s == "done") {
                debug_log!("[nREPL DEBUG] Session closed successfully");
                // Remove session from internal tracking
                self.sessions.remove(&session.id);
                return Ok(());
            }
        }
    }

    /// Gracefully shutdown the connection
    ///
    /// This method should be called before dropping the client to ensure proper cleanup.
    /// It will:
    /// 1. Close all active sessions
    /// 2. Shutdown the TCP stream
    ///
    /// Connections dropped without calling shutdown will still close the TCP stream,
    /// but sessions will not be gracefully closed on the server side.
    ///
    /// # Example
    /// ```no_run
    /// # use nrepl_rs::NReplClient;
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    /// // ... use the client ...
    /// client.shutdown().await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn shutdown(mut self) -> Result<()> {
        debug_log!("[nREPL DEBUG] Shutting down connection...");

        // Collect all sessions to close (avoid borrow issues with iterator)
        let sessions: Vec<Session> = self.sessions.values().cloned().collect();

        debug_log!("[nREPL DEBUG] Closing {} active sessions", sessions.len());

        // Close all sessions (ignore errors during shutdown)
        for session in sessions {
            if let Err(e) = self.close_session(session).await {
                debug_log!("[nREPL DEBUG] Warning: Failed to close session during shutdown: {}", e);
            }
        }

        // Shutdown the TCP stream
        debug_log!("[nREPL DEBUG] Shutting down TCP stream");
        self.stream.shutdown().await?;

        debug_log!("[nREPL DEBUG] Connection shutdown complete");
        Ok(())
    }

    /// Describe the server capabilities
    ///
    /// Queries the nREPL server for information about supported operations, versions,
    /// and auxiliary data. This is useful for feature detection and debugging server
    /// configuration.
    ///
    /// # Arguments
    ///
    /// * `verbose` - If true, includes detailed documentation for each operation
    ///
    /// # Returns
    ///
    /// Returns a `Response` containing:
    /// - `ops`: Map of operation names to their metadata
    /// - `versions`: Version information for nREPL and server implementation
    /// - `aux`: Auxiliary server-specific data
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // Get basic server info
    /// let info = client.describe(false).await?;
    /// println!("Server info: {:?}", info);
    ///
    /// // Get detailed info including operation docs
    /// let detailed_info = client.describe(true).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn describe(&mut self, verbose: bool) -> Result<Response> {
        debug_log!("[nREPL DEBUG] Describing server (verbose={})", verbose);

        let request = describe_request(Some(verbose));
        debug_log!("[nREPL DEBUG] Sending describe request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received describe response");

        Ok(response)
    }

    /// List all active sessions on the server
    ///
    /// Returns the IDs of all currently active nREPL sessions on the server, including
    /// sessions created by other clients. This is useful for debugging and monitoring
    /// server state.
    ///
    /// # Returns
    ///
    /// Returns a vector of session ID strings.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // Create some sessions
    /// let session1 = client.clone_session().await?;
    /// let session2 = client.clone_session().await?;
    ///
    /// // List all active sessions
    /// let sessions = client.ls_sessions().await?;
    /// println!("Active sessions: {:?}", sessions);
    /// # Ok(())
    /// # }
    /// ```
    pub async fn ls_sessions(&mut self) -> Result<Vec<String>> {
        debug_log!("[nREPL DEBUG] Listing sessions");

        let request = ls_sessions_request();
        debug_log!("[nREPL DEBUG] Sending ls-sessions request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received ls-sessions response");

        Ok(response.sessions.unwrap_or_default())
    }

    /// Send stdin data to a session
    ///
    /// Provides input data to code that's waiting for stdin (e.g., `(read-line)` in Clojure).
    /// This is useful for interactive programs that expect user input.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to send input to
    /// * `data` - The input data (typically a line of text with newline)
    ///
    /// # Errors
    ///
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Start code that reads from stdin
    /// // In another context: client.eval(&session, "(println (read-line))").await?;
    ///
    /// // Send input to the waiting evaluation
    /// client.stdin(&session, "Hello, world!\n").await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn stdin(&mut self, session: &Session, data: impl Into<String>) -> Result<()> {
        self.validate_session(session)?;
        let data_str = data.into();
        debug_log!(
            "[nREPL DEBUG] Sending stdin to session {}: {:?}",
            session.id,
            data_str
        );

        let request = stdin_request(&session.id, data_str);
        debug_log!("[nREPL DEBUG] Sending stdin request ID: {}", request.id);

        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        debug_log!("[nREPL DEBUG] Stdin sent successfully");
        Ok(())
    }

    /// Request code completions
    ///
    /// Returns a list of possible completions for the given prefix. Completions are context-aware
    /// and take the current namespace and available symbols into account.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to use for completion context (namespace, defined vars)
    /// * `prefix` - The prefix string to complete (e.g., "map-")
    /// * `ns` - Optional namespace to search in (defaults to current session namespace)
    /// * `complete_fn` - Optional custom completion function symbol
    ///
    /// # Returns
    ///
    /// Returns a vector of completion strings (e.g., ["map-indexed", "mapcat", "mapv"]).
    ///
    /// # Errors
    ///
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Get completions for "map-"
    /// let completions = client.completions(&session, "map-", None, None).await?;
    /// for completion in completions {
    ///     println!("  {}", completion);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub async fn completions(
        &mut self,
        session: &Session,
        prefix: impl Into<String>,
        ns: Option<String>,
        complete_fn: Option<String>,
    ) -> Result<Vec<String>> {
        self.validate_session(session)?;
        let prefix_str = prefix.into();
        debug_log!(
            "[nREPL DEBUG] Requesting completions for prefix: {:?}",
            prefix_str
        );

        let request = completions_request(&session.id, prefix_str, ns, complete_fn);
        debug_log!("[nREPL DEBUG] Sending completions request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received completions response");

        Ok(response.completions.unwrap_or_default())
    }

    /// Look up information about a symbol
    ///
    /// Returns detailed information about a symbol, including its documentation, arglists,
    /// file location, and other metadata. This is used for IDE features like "go to definition"
    /// and inline documentation.
    ///
    /// # Arguments
    ///
    /// * `session` - The session to use for lookup context (namespace)
    /// * `sym` - The symbol to look up (e.g., "map", "clojure.core/reduce")
    /// * `ns` - Optional namespace to search in (defaults to current session namespace)
    /// * `lookup_fn` - Optional custom lookup function symbol
    ///
    /// # Returns
    ///
    /// Returns a `Response` containing symbol metadata (doc, arglists, file, line, etc.).
    ///
    /// # Errors
    ///
    /// Returns `NReplError::SessionNotFound` if the session has been closed or is invalid.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    /// let session = client.clone_session().await?;
    ///
    /// // Look up information about the 'map' function
    /// let info = client.lookup(&session, "map", None, None).await?;
    /// println!("Symbol info: {:?}", info);
    /// # Ok(())
    /// # }
    /// ```
    pub async fn lookup(
        &mut self,
        session: &Session,
        sym: impl Into<String>,
        ns: Option<String>,
        lookup_fn: Option<String>,
    ) -> Result<Response> {
        self.validate_session(session)?;
        let sym_str = sym.into();
        debug_log!("[nREPL DEBUG] Looking up symbol: {:?}", sym_str);

        let request = lookup_request(&session.id, sym_str, ns, lookup_fn);
        debug_log!("[nREPL DEBUG] Sending lookup request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received lookup response");

        Ok(response)
    }

    /// List loaded middleware
    ///
    /// Returns a list of all nREPL middleware currently loaded on the server. Middleware
    /// components extend the server's functionality with additional operations and features.
    ///
    /// # Returns
    ///
    /// Returns a vector of middleware names (symbols as strings).
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // List all loaded middleware
    /// let middleware = client.ls_middleware().await?;
    /// for mw in middleware {
    ///     println!("  {}", mw);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub async fn ls_middleware(&mut self) -> Result<Vec<String>> {
        debug_log!("[nREPL DEBUG] Listing middleware");

        let request = ls_middleware_request();
        debug_log!("[nREPL DEBUG] Sending ls-middleware request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received ls-middleware response");

        Ok(response.middleware.unwrap_or_default())
    }

    /// Add middleware to the server
    ///
    /// Dynamically adds middleware to the nREPL server's middleware stack. The middleware
    /// symbols must refer to valid middleware that can be resolved and loaded by the server.
    ///
    /// # Arguments
    ///
    /// * `middleware` - List of middleware symbols to add (e.g., ["cider.nrepl/cider-middleware"])
    /// * `extra_namespaces` - Optional list of extra namespaces to require before loading middleware
    ///
    /// # Returns
    ///
    /// Returns a `Response` with the result of the operation.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // Add custom middleware
    /// let response = client.add_middleware(
    ///     vec!["my.custom/middleware".to_string()],
    ///     Some(vec!["my.custom".to_string()])
    /// ).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn add_middleware(
        &mut self,
        middleware: Vec<String>,
        extra_namespaces: Option<Vec<String>>,
    ) -> Result<Response> {
        debug_log!("[nREPL DEBUG] Adding middleware: {:?}", middleware);

        let request = add_middleware_request(middleware, extra_namespaces);
        debug_log!("[nREPL DEBUG] Sending add-middleware request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received add-middleware response");

        Ok(response)
    }

    /// Replace the entire middleware stack
    ///
    /// Replaces the entire nREPL server middleware stack with a new list of middleware.
    /// This is more aggressive than `add_middleware()` - it completely replaces the existing
    /// stack rather than appending to it.
    ///
    /// **Warning:** This can break server functionality if essential middleware is removed.
    /// Use with caution and ensure all necessary middleware is included in the new stack.
    ///
    /// # Arguments
    ///
    /// * `middleware` - Complete list of middleware symbols to use (e.g., ["nrepl.middleware.session/session"])
    /// * `extra_namespaces` - Optional list of extra namespaces to require before loading middleware
    ///
    /// # Returns
    ///
    /// Returns a `Response` with the result of the operation.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use nrepl_rs::NReplClient;
    ///
    /// # #[tokio::main]
    /// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// let mut client = NReplClient::connect("localhost:7888").await?;
    ///
    /// // Replace middleware stack (use with caution!)
    /// let response = client.swap_middleware(
    ///     vec![
    ///         "nrepl.middleware.session/session".to_string(),
    ///         "my.custom/middleware".to_string()
    ///     ],
    ///     Some(vec!["my.custom".to_string()])
    /// ).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn swap_middleware(
        &mut self,
        middleware: Vec<String>,
        extra_namespaces: Option<Vec<String>>,
    ) -> Result<Response> {
        debug_log!("[nREPL DEBUG] Swapping middleware: {:?}", middleware);

        let request = swap_middleware_request(middleware, extra_namespaces);
        debug_log!("[nREPL DEBUG] Sending swap-middleware request ID: {}", request.id);

        let response = self.send_request(&request).await?;
        debug_log!("[nREPL DEBUG] Received swap-middleware response");

        Ok(response)
    }

    /// Send a request and accumulate responses until "done" status
    ///
    /// This is a helper method used by operations that return EvalResult (eval, load-file).
    /// It sends the request, then collects all responses until receiving the "done" status,
    /// accumulating output, errors, values, and namespace information.
    ///
    /// # Arguments
    ///
    /// * `request` - The request to send
    /// * `operation` - Operation name for debug logging (e.g., "eval", "load-file")
    async fn send_and_accumulate_responses(
        &mut self,
        request: &Request,
        operation: &str,
    ) -> Result<EvalResult> {
        debug_log!("[nREPL DEBUG] Sending {} request ID: {}", operation, request.id);

        // Send the request
        let encoded = encode_request(request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Collect responses until we see "done" status
        let mut result = EvalResult::new();
        let mut done = false;

        while !done {
            let response = self.read_response().await?;
            debug_log!(
                "[nREPL DEBUG] Received {} response ID: {}, status: {:?}",
                operation,
                response.id,
                response.status
            );

            // Check if this response is for our request
            if response.id != request.id {
                debug_log!(
                    "[nREPL DEBUG] Skipping response - ID mismatch (expected: {}, got: {})",
                    request.id,
                    response.id
                );
                continue;
            }

            // Accumulate output
            if let Some(out) = response.out {
                result.output.push(out);
            }

            // Accumulate errors
            if let Some(err) = response.err {
                if let Some(existing) = &mut result.error {
                    existing.push_str(&err);
                } else {
                    result.error = Some(err);
                }
            }

            // Capture value (last one wins)
            if let Some(value) = response.value {
                result.value = Some(value);
            }

            // Capture namespace (last one wins)
            if let Some(ns) = response.ns {
                result.ns = Some(ns);
            }

            // Check if we're done
            if response.status.iter().any(|s| s == "done") {
                debug_log!("[nREPL DEBUG] Received 'done' status, completing {}", operation);
                done = true;
            }
        }

        Ok(result)
    }

    /// Send a request and receive a single response
    async fn send_request(&mut self, request: &Request) -> Result<Response> {
        // Encode the request
        let encoded = encode_request(request)?;

        // Send the request
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Read the response
        self.read_response().await
    }

    /// Read a single bencode response from the stream
    async fn read_response(&mut self) -> Result<Response> {
        // Bencode messages are self-delimiting. We use a persistent buffer to handle
        // cases where multiple messages arrive in a single TCP read.

        let mut temp_buf = [0u8; 4096];

        loop {
            // First, try to decode from existing buffer data
            if !self.buffer.is_empty() {
                match decode_response(&self.buffer) {
                    Ok((response, consumed)) => {
                        debug_log!(
                            "[nREPL DEBUG] Successfully decoded response (consumed {} of {} bytes in buffer)",
                            consumed,
                            self.buffer.len()
                        );
                        // Remove the consumed bytes, keep the rest for next read
                        self.buffer.drain(..consumed);
                        debug_log!(
                            "[nREPL DEBUG] Buffer now has {} bytes remaining",
                            self.buffer.len()
                        );
                        return Ok(response);
                    }
                    Err(NReplError::Codec { ref message, .. }) => {
                        // Incomplete message, need to read more data
                        debug_log!(
                            "[nREPL DEBUG] Incomplete message in buffer ({} bytes), reading more...",
                            self.buffer.len()
                        );
                        debug_log!("[nREPL DEBUG] Codec error: {}", message);

                        // Only format buffer contents if debug logging is enabled
                        if debug_enabled() {
                            // Show first 200 bytes as hex for debugging
                            let preview_len = self.buffer.len().min(200);
                            let hex: String = self.buffer[..preview_len]
                                .iter()
                                .map(|b| format!("{:02x}", b))
                                .collect::<Vec<_>>()
                                .join(" ");
                            eprintln!(
                                "[nREPL DEBUG] Buffer hex (first {} bytes): {}",
                                preview_len,
                                hex
                            );
                            // Also show as string (replacing non-printable with .)
                            let ascii: String = self.buffer[..preview_len]
                                .iter()
                                .map(|&b| if (32..127).contains(&b) { b as char } else { '.' })
                                .collect();
                            eprintln!(
                                "[nREPL DEBUG] Buffer ASCII (first {} bytes): {}",
                                preview_len,
                                ascii
                            );
                        }
                    }
                    Err(e) => return Err(e),
                }
            }

            // Read more data from the stream
            debug_log!("[nREPL DEBUG] Waiting for data from stream...");
            let n = self.stream.read(&mut temp_buf).await?;
            debug_log!("[nREPL DEBUG] Read {} bytes from stream", n);

            if n == 0 {
                return Err(NReplError::Connection(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "connection closed",
                )));
            }

            // Check buffer size BEFORE appending to prevent exceeding MAX_RESPONSE_SIZE
            if self.buffer.len() + n > MAX_RESPONSE_SIZE {
                return Err(NReplError::protocol(format!(
                    "Response would exceed maximum size of {} bytes (current: {}, adding: {})",
                    MAX_RESPONSE_SIZE,
                    self.buffer.len(),
                    n
                )));
            }

            self.buffer.extend_from_slice(&temp_buf[..n]);
        }
    }
}
