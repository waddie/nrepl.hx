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

use lazy_static::lazy_static;
use nrepl_rs::{NReplClient, Session};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub type ConnectionId = usize;
pub type SessionId = usize;

/// Connection entry storing client and its sessions
struct ConnectionEntry {
    client: NReplClient,
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

    /// Add a new connection, returns connection ID
    pub fn add_connection(&mut self, client: NReplClient) -> ConnectionId {
        let id = self.next_conn_id;
        self.next_conn_id += 1;

        self.connections.insert(
            id,
            ConnectionEntry {
                client,
                sessions: HashMap::new(),
                next_session_id: 1,
            },
        );

        id
    }

    /// Get mutable reference to a connection
    pub fn get_connection_mut(&mut self, conn_id: ConnectionId) -> Option<&mut NReplClient> {
        self.connections
            .get_mut(&conn_id)
            .map(|entry| &mut entry.client)
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

    /// Remove a connection and all its sessions
    pub fn remove_connection(&mut self, conn_id: ConnectionId) -> bool {
        self.connections.remove(&conn_id).is_some()
    }
}

lazy_static! {
    pub static ref REGISTRY: Arc<Mutex<Registry>> = Arc::new(Mutex::new(Registry::new()));
}

/// Helper functions for registry access
pub fn add_connection(client: NReplClient) -> ConnectionId {
    REGISTRY.lock().unwrap().add_connection(client)
}

pub fn get_connection_mut<F, R>(conn_id: ConnectionId, f: F) -> Option<R>
where
    F: FnOnce(&mut NReplClient) -> R,
{
    let mut registry = REGISTRY.lock().unwrap();
    registry.get_connection_mut(conn_id).map(f)
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
        let mut registry = Registry::new();

        // Getting non-existent connection should return None
        assert!(registry.get_connection_mut(999).is_none());
        assert!(registry.get_session(999, 1).is_none());
    }
}
