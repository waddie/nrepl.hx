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

//! Thread-safe registry for nREPL connections and sessions

use crate::worker::{EvalResponse, RequestId, Worker};
use lazy_static::lazy_static;
use nrepl_rs::{NReplError, Session};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub type ConnectionId = usize;
pub type SessionId = usize;

/// Connection entry storing worker thread and its sessions
struct ConnectionEntry {
    worker: Worker,
    sessions: HashMap<SessionId, Session>,
    next_session_id: SessionId,
}

/// Global registry of nREPL connections
pub struct Registry {
    connections: HashMap<ConnectionId, ConnectionEntry>,
    next_conn_id: ConnectionId,
}

impl Registry {
    fn new() -> Self {
        Self {
            connections: HashMap::new(),
            next_conn_id: 1,
        }
    }

    /// Create a new connection worker and connect to the server
    pub fn create_and_connect(&mut self, address: String) -> Result<ConnectionId, NReplError> {
        let id = self.next_conn_id;
        self.next_conn_id += 1;

        // Create worker thread
        let worker = Worker::new();

        // Connect via worker thread (blocks until connected)
        worker.connect_blocking(address)?;

        self.connections.insert(
            id,
            ConnectionEntry {
                worker,
                sessions: HashMap::new(),
                next_session_id: 1,
            },
        );

        Ok(id)
    }

    /// Submit an eval request to the worker thread (non-blocking)
    pub fn submit_eval(
        &mut self,
        conn_id: ConnectionId,
        session: Session,
        code: String,
        timeout: Option<Duration>,
    ) -> Option<RequestId> {
        let entry = self.connections.get_mut(&conn_id)?;
        Some(entry.worker.submit_eval(session, code, timeout))
    }

    /// Try to receive a completed eval response (non-blocking)
    pub fn try_recv_response(&self, conn_id: ConnectionId, request_id: RequestId) -> Option<EvalResponse> {
        self.connections
            .get(&conn_id)?
            .worker
            .try_recv_response(request_id)
    }

    /// Clone a session from a connection (blocking)
    pub fn clone_session_blocking(&self, conn_id: ConnectionId) -> Option<Result<Session, NReplError>> {
        Some(self.connections.get(&conn_id)?.worker.clone_session_blocking())
    }

    /// Close a session on the server (blocking)
    pub fn close_session_blocking(&self, conn_id: ConnectionId, session: Session) -> Option<Result<(), NReplError>> {
        Some(self.connections.get(&conn_id)?.worker.close_session_blocking(session))
    }

    /// Add a session to a connection, returns session ID
    pub fn add_session(&mut self, conn_id: ConnectionId, session: Session) -> Option<SessionId> {
        let entry = self.connections.get_mut(&conn_id)?;
        let session_id = entry.next_session_id;
        entry.next_session_id += 1;
        entry.sessions.insert(session_id, session);
        Some(session_id)
    }

    /// Get a session from a connection
    pub fn get_session(&self, conn_id: ConnectionId, session_id: SessionId) -> Option<&Session> {
        self.connections.get(&conn_id)?.sessions.get(&session_id)
    }

    /// Get all sessions for a connection
    pub fn get_all_sessions(&self, conn_id: ConnectionId) -> Option<Vec<Session>> {
        Some(
            self.connections
                .get(&conn_id)?
                .sessions
                .values()
                .cloned()
                .collect(),
        )
    }

    /// Remove a connection and all its sessions
    pub fn remove_connection(&mut self, conn_id: ConnectionId) -> bool {
        self.connections.remove(&conn_id).is_some()
    }
}

lazy_static! {
    pub static ref REGISTRY: Arc<Mutex<Registry>> = Arc::new(Mutex::new(Registry::new()));
}

/// Helper functions for registry access
pub fn create_and_connect(address: String) -> Result<ConnectionId, NReplError> {
    REGISTRY.lock().unwrap().create_and_connect(address)
}

pub fn submit_eval(
    conn_id: ConnectionId,
    session: Session,
    code: String,
    timeout: Option<Duration>,
) -> Option<RequestId> {
    REGISTRY
        .lock()
        .unwrap()
        .submit_eval(conn_id, session, code, timeout)
}

pub fn try_recv_response(conn_id: ConnectionId, request_id: RequestId) -> Option<EvalResponse> {
    REGISTRY.lock().unwrap().try_recv_response(conn_id, request_id)
}

pub fn clone_session_blocking(conn_id: ConnectionId) -> Option<Result<Session, NReplError>> {
    REGISTRY.lock().unwrap().clone_session_blocking(conn_id)
}

pub fn close_session_blocking(conn_id: ConnectionId, session: Session) -> Option<Result<(), NReplError>> {
    REGISTRY.lock().unwrap().close_session_blocking(conn_id, session)
}

pub fn add_session(conn_id: ConnectionId, session: Session) -> Option<SessionId> {
    REGISTRY.lock().unwrap().add_session(conn_id, session)
}

pub fn get_session(conn_id: ConnectionId, session_id: SessionId) -> Option<Session> {
    REGISTRY
        .lock()
        .unwrap()
        .get_session(conn_id, session_id)
        .cloned()
}

pub fn get_all_sessions(conn_id: ConnectionId) -> Option<Vec<Session>> {
    REGISTRY.lock().unwrap().get_all_sessions(conn_id)
}

pub fn remove_connection(conn_id: ConnectionId) -> bool {
    REGISTRY.lock().unwrap().remove_connection(conn_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_registry_id_generation() {
        let registry = Registry::new();

        // Test that IDs are generated sequentially starting from 1
        assert_eq!(registry.next_conn_id, 1);

        // We can't test with real connections in unit tests,
        // but we can verify the ID allocation logic would work
        // The actual connection tests are in integration tests
    }

    #[test]
    fn test_registry_remove_nonexistent() {
        let mut registry = Registry::new();

        // Removing non-existent connection should return false
        assert_eq!(registry.remove_connection(999), false);
    }

    #[test]
    fn test_registry_get_nonexistent() {
        let registry = Registry::new();

        // Getting non-existent session should return None
        assert!(registry.get_session(999, 1).is_none());
        // Getting non-existent sessions list should return None
        assert!(registry.get_all_sessions(999).is_none());
    }
}
