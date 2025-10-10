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
use crate::ops::{clone_request, eval_request};
use crate::session::Session;
use std::collections::HashMap;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, ToSocketAddrs};
use tokio::time::timeout;

/// Maximum size for a single nREPL response message (10MB)
/// This prevents OOM attacks from malicious servers sending infinite data
const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;

/// Default timeout for eval operations (60 seconds)
/// Can be overridden with eval_with_timeout
const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(60);

/// Main nREPL client
pub struct NReplClient {
    stream: TcpStream,
    sessions: HashMap<String, Session>,
}

impl NReplClient {
    /// Connect to an nREPL server
    pub async fn connect(addr: impl ToSocketAddrs) -> Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Self {
            stream,
            sessions: HashMap::new(),
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
    async fn eval_impl(&mut self, session: &Session, code: impl Into<String>) -> Result<EvalResult> {
        let request = eval_request(&session.id, code);

        // Send the request
        let encoded = encode_request(&request)?;
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;

        // Collect responses until we see "done" status
        let mut result = EvalResult::new();
        let mut done = false;

        while !done {
            let response = self.read_response().await?;

            // Check if this response is for our request
            if response.id != request.id {
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
                done = true;
            }
        }

        Ok(result)
    }

    /// Load a file in a session
    pub async fn load_file(
        &mut self,
        _session: &Session,
        _file: impl Into<String>,
    ) -> Result<EvalResult> {
        // TODO: Implement load_file
        todo!("Implement load_file")
    }

    /// Interrupt an ongoing evaluation
    pub async fn interrupt(&mut self, _session: &Session) -> Result<()> {
        // TODO: Implement interrupt
        todo!("Implement interrupt")
    }

    /// Close a session
    pub async fn close_session(&mut self, _session: Session) -> Result<()> {
        // TODO: Implement close_session
        todo!("Implement close_session")
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
        // Bencode messages are self-delimiting. We need to read until we have a complete message.
        // Strategy: Read into a buffer and try to decode. If incomplete, read more.

        let mut buffer = Vec::new();
        let mut temp_buf = [0u8; 4096];

        loop {
            let n = self.stream.read(&mut temp_buf).await?;

            if n == 0 {
                return Err(NReplError::Connection(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "connection closed",
                )));
            }

            buffer.extend_from_slice(&temp_buf[..n]);

            // Check buffer size to prevent OOM from malicious servers
            if buffer.len() > MAX_RESPONSE_SIZE {
                return Err(NReplError::Protocol(format!(
                    "Response exceeded maximum size of {} bytes",
                    MAX_RESPONSE_SIZE
                )));
            }

            // Try to decode what we have so far
            match decode_response(&buffer) {
                Ok(response) => return Ok(response),
                Err(NReplError::Codec(_)) => {
                    // Incomplete message, continue reading
                    continue;
                }
                Err(e) => return Err(e),
            }
        }
    }
}
