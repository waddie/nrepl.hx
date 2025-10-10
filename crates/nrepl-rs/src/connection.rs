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
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, ToSocketAddrs};

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
        // TODO: Implement session cloning
        todo!("Implement clone_session")
    }

    /// Evaluate code in a session
    pub async fn eval(
        &mut self,
        session: &Session,
        code: impl Into<String>,
    ) -> Result<EvalResult> {
        // TODO: Implement eval
        todo!("Implement eval")
    }

    /// Load a file in a session
    pub async fn load_file(
        &mut self,
        session: &Session,
        file: impl Into<String>,
    ) -> Result<EvalResult> {
        // TODO: Implement load_file
        todo!("Implement load_file")
    }

    /// Interrupt an ongoing evaluation
    pub async fn interrupt(&mut self, session: &Session) -> Result<()> {
        // TODO: Implement interrupt
        todo!("Implement interrupt")
    }

    /// Close a session
    pub async fn close_session(&mut self, session: Session) -> Result<()> {
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
