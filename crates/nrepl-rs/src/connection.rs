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
use crate::ops::{clone_request, close_request, eval_request, interrupt_request, load_file_request};
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

/// Default timeout for eval operations (5 seconds)
/// Can be overridden with eval_with_timeout
const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(5);

/// Main nREPL client
pub struct NReplClient {
    stream: TcpStream,
    sessions: HashMap<String, Session>,
    buffer: Vec<u8>, // Persistent buffer for handling multiple messages in one TCP read
}

impl NReplClient {
    /// Connect to an nREPL server
    pub async fn connect(addr: impl ToSocketAddrs) -> Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Self {
            stream,
            sessions: HashMap::new(),
            buffer: Vec::new(),
        })
    }

    /// Clone a new session from the server
    pub async fn clone_session(&mut self) -> Result<Session> {
        let request = clone_request();
        let response = self.send_request(&request).await?;

        // Extract new-session ID from response
        let session_id = response.new_session.ok_or_else(|| {
            NReplError::Protocol("Missing new-session in clone response".to_string())
        })?;

        let session = Session::new(session_id);
        self.sessions.insert(session.id.clone(), session.clone());

        Ok(session)
    }

    /// Evaluate code in a session with default timeout (60 seconds)
    ///
    /// For custom timeout, use `eval_with_timeout`.
    pub async fn eval(&mut self, session: &Session, code: impl Into<String>) -> Result<EvalResult> {
        self.eval_with_timeout(session, code, DEFAULT_EVAL_TIMEOUT)
            .await
    }

    /// Evaluate code in a session with custom timeout
    ///
    /// # Arguments
    /// * `session` - The session to evaluate in
    /// * `code` - The code to evaluate
    /// * `timeout_duration` - Maximum time to wait for evaluation
    ///
    /// # Errors
    /// Returns `NReplError::OperationFailed` if the timeout is exceeded
    pub async fn eval_with_timeout(
        &mut self,
        session: &Session,
        code: impl Into<String>,
        timeout_duration: Duration,
    ) -> Result<EvalResult> {
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
        debug_log!("[nREPL DEBUG] Sending request ID: {}", request.id);

        // Send the request
        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Collect responses until we see "done" status
        let mut result = EvalResult::new();
        let mut done = false;

        while !done {
            let response = self.read_response().await?;
            debug_log!(
                "[nREPL DEBUG] Received response ID: {}, status: {:?}",
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
                debug_log!("[nREPL DEBUG] Received 'done' status, completing eval");
                done = true;
            }
        }

        Ok(result)
    }

    /// Load a file in a session
    ///
    /// # Arguments
    /// * `session` - The session to load the file in
    /// * `file_contents` - The contents of the file to load
    /// * `file_path` - Optional file path (for error messages)
    /// * `file_name` - Optional file name (for error messages)
    pub async fn load_file(
        &mut self,
        session: &Session,
        file_contents: impl Into<String>,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> Result<EvalResult> {
        let file_str = file_contents.into();
        debug_log!(
            "[nREPL DEBUG] Loading file ({} bytes): path={:?}, name={:?}",
            file_str.len(),
            file_path,
            file_name
        );

        let request = load_file_request(&session.id, file_str, file_path, file_name);
        debug_log!("[nREPL DEBUG] Sending load-file request ID: {}", request.id);

        // Send the request
        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Collect responses until we see "done" status (same as eval)
        let mut result = EvalResult::new();
        let mut done = false;

        while !done {
            let response = self.read_response().await?;
            debug_log!(
                "[nREPL DEBUG] Received load-file response ID: {}, status: {:?}",
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
                debug_log!("[nREPL DEBUG] Received 'done' status, completing load-file");
                done = true;
            }
        }

        Ok(result)
    }

    /// Interrupt an ongoing evaluation
    ///
    /// # Arguments
    /// * `session` - The session containing the evaluation to interrupt
    /// * `interrupt_id` - The message ID of the evaluation to interrupt
    pub async fn interrupt(
        &mut self,
        session: &Session,
        interrupt_id: impl Into<String>,
    ) -> Result<()> {
        let interrupt_id_str = interrupt_id.into();
        debug_log!(
            "[nREPL DEBUG] Interrupting evaluation: session={}, interrupt-id={}",
            session.id,
            interrupt_id_str
        );

        let request = interrupt_request(&session.id, interrupt_id_str);
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
    /// # Arguments
    /// * `session` - The session to close
    pub async fn close_session(&mut self, session: Session) -> Result<()> {
        debug_log!(
            "[nREPL DEBUG] Closing session: id={}",
            session.id
        );

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
                    Err(NReplError::Codec(_)) => {
                        // Incomplete message, need to read more data
                        debug_log!(
                            "[nREPL DEBUG] Incomplete message in buffer ({} bytes), reading more...",
                            self.buffer.len()
                        );
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

            self.buffer.extend_from_slice(&temp_buf[..n]);

            // Check buffer size to prevent OOM from malicious servers
            if self.buffer.len() > MAX_RESPONSE_SIZE {
                return Err(NReplError::Protocol(format!(
                    "Response exceeded maximum size of {} bytes",
                    MAX_RESPONSE_SIZE
                )));
            }
        }
    }
}
