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

use crate::error::{NReplError, Result};
use crate::message::{EvalResult, Response};
use crate::session::Session;
use std::collections::HashMap;
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
}
