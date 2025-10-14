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
//!
//! # Mutex Poisoning
//!
//! This module uses a global `Mutex`-protected registry. All public functions
//! use `.unwrap()` on the mutex lock, which means they will **panic if the mutex
//! is poisoned**.
//!
//! **When does poisoning occur?**
//! A mutex becomes poisoned when a thread panics while holding the lock. This
//! indicates that the registry may be in an inconsistent state.
//!
//! **Why not handle the poison?**
//! - Lock poisoning indicates serious corruption or a bug in the registry code
//! - The registry operations are simple CRUD - they shouldn't panic under normal circumstances
//! - Each worker thread is isolated - a panic in user code doesn't poison the registry
//! - Attempting to continue with corrupted state could cause worse bugs later
//! - Immediate panic makes debugging easier by clearly indicating the failure point
//!
//! **In practice:** Lock poisoning is extremely rare. The only way it occurs is if
//! there's a bug in the registry implementation itself (array bounds, unwrap on None, etc.).
//! In such cases, failing fast with a panic is preferable to silent data corruption.

use crate::worker::{EvalResponse, RequestId, SubmitError, Worker};
use lazy_static::lazy_static;
use nrepl_rs::{NReplError, Response, Session};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Newtype wrapper for connection IDs to prevent mixing with other ID types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ConnectionId(usize);

impl ConnectionId {
    /// Create a new ConnectionId from a usize
    pub fn new(id: usize) -> Self {
        ConnectionId(id)
    }

    /// Get the raw usize value (for FFI and serialization)
    pub fn as_usize(&self) -> usize {
        self.0
    }
}

/// Newtype wrapper for session IDs to prevent mixing with other ID types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(usize);

impl SessionId {
    /// Create a new SessionId from a usize
    pub fn new(id: usize) -> Self {
        SessionId(id)
    }

    /// Get the raw usize value (for FFI and serialization)
    pub fn as_usize(&self) -> usize {
        self.0
    }
}

/// Maximum number of concurrent connections to prevent resource exhaustion
const MAX_CONNECTIONS: usize = 100;

/// Connection entry storing worker thread and its sessions
struct ConnectionEntry {
    worker: Worker,
    sessions: HashMap<SessionId, Session>,
    next_session_id: usize,
}

/// Global registry of nREPL connections
pub struct Registry {
    connections: HashMap<ConnectionId, ConnectionEntry>,
    next_conn_id: usize,
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
        // Check connection limit
        if self.connections.len() >= MAX_CONNECTIONS {
            return Err(NReplError::protocol(format!(
                "Maximum connections ({}) exceeded. Close unused connections before creating new ones.",
                MAX_CONNECTIONS
            )));
        }

        // Create worker thread
        let worker = Worker::new();

        // Connect via worker thread (blocks until connected)
        // If this fails, worker will be dropped, shutting down the thread
        match worker.connect_blocking(address) {
            Ok(()) => {
                // Only allocate connection ID after successful connection
                let id = ConnectionId::new(self.next_conn_id);
                self.next_conn_id = self.next_conn_id
                    .checked_add(1)
                    .expect("Connection ID overflow");

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
            Err(e) => {
                // Worker will be dropped here, calling shutdown via Drop trait
                Err(e)
            }
        }
    }

    /// Submit an eval request to the worker thread (non-blocking)
    pub fn submit_eval(
        &mut self,
        conn_id: ConnectionId,
        session: Session,
        code: String,
        timeout: Option<Duration>,
    ) -> Option<Result<RequestId, SubmitError>> {
        let entry = self.connections.get_mut(&conn_id)?;
        Some(entry.worker.submit_eval(session, code, timeout))
    }

    /// Submit a load-file request to the worker thread (non-blocking)
    pub fn submit_load_file(
        &mut self,
        conn_id: ConnectionId,
        session: Session,
        file_contents: String,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> Option<Result<RequestId, SubmitError>> {
        let entry = self.connections.get_mut(&conn_id)?;
        Some(entry.worker.submit_load_file(session, file_contents, file_path, file_name))
    }

    /// Try to receive a completed eval response (non-blocking)
    pub fn try_recv_response(&mut self, conn_id: ConnectionId, request_id: RequestId) -> Option<EvalResponse> {
        self.connections
            .get_mut(&conn_id)?
            .worker
            .try_recv_response(request_id)
    }

    /// Clone a session from a connection (blocking)
    pub fn clone_session_blocking(&self, conn_id: ConnectionId) -> Result<Session, NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.clone_session_blocking()
    }

    /// Interrupt an ongoing evaluation (blocking)
    pub fn interrupt_blocking(&self, conn_id: ConnectionId, session: Session, interrupt_id: String) -> Result<(), NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.interrupt_blocking(session, interrupt_id)
    }

    /// Close a session on the server (blocking)
    pub fn close_session_blocking(&self, conn_id: ConnectionId, session: Session) -> Result<(), NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. It may have already been closed.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.close_session_blocking(session)
    }

    /// Send stdin data to a session (blocking)
    pub fn stdin_blocking(&self, conn_id: ConnectionId, session: Session, data: String) -> Result<(), NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.stdin_blocking(session, data)
    }

    /// Get code completions (blocking)
    pub fn completions_blocking(
        &self,
        conn_id: ConnectionId,
        session: Session,
        prefix: String,
        ns: Option<String>,
        complete_fn: Option<String>,
    ) -> Result<Vec<String>, NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.completions_blocking(session, prefix, ns, complete_fn)
    }

    /// Lookup symbol information (blocking)
    pub fn lookup_blocking(
        &self,
        conn_id: ConnectionId,
        session: Session,
        sym: String,
        ns: Option<String>,
        lookup_fn: Option<String>,
    ) -> Result<Response, NReplError> {
        let worker = &self.connections
            .get(&conn_id)
            .ok_or_else(|| NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            )))?
            .worker;
        worker.lookup_blocking(session, sym, ns, lookup_fn)
    }

    /// Add a session to a connection, returns session ID
    pub fn add_session(&mut self, conn_id: ConnectionId, session: Session) -> Option<SessionId> {
        let entry = self.connections.get_mut(&conn_id)?;
        let session_id = SessionId::new(entry.next_session_id);
        entry.next_session_id = entry.next_session_id
            .checked_add(1)
            .expect("Session ID overflow - cannot create more sessions");
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

    /// Remove a session from a connection
    ///
    /// Returns the removed session if it existed, or None if the connection
    /// or session wasn't found.
    pub fn remove_session(&mut self, conn_id: ConnectionId, session_id: SessionId) -> Option<Session> {
        self.connections
            .get_mut(&conn_id)?
            .sessions
            .remove(&session_id)
    }

    /// Remove a connection and all its sessions
    pub fn remove_connection(&mut self, conn_id: ConnectionId) -> bool {
        self.connections.remove(&conn_id).is_some()
    }

    /// Get registry statistics for observability
    ///
    /// Returns statistics about connections and sessions in the registry.
    /// Useful for debugging and monitoring resource usage.
    pub fn get_stats(&self) -> RegistryStats {
        let total_sessions: usize = self
            .connections
            .values()
            .map(|entry| entry.sessions.len())
            .sum();

        let connection_details: Vec<ConnectionStats> = self
            .connections
            .iter()
            .map(|(conn_id, entry)| ConnectionStats {
                connection_id: *conn_id,
                session_count: entry.sessions.len(),
            })
            .collect();

        RegistryStats {
            total_connections: self.connections.len(),
            total_sessions,
            max_connections: MAX_CONNECTIONS,
            next_conn_id: self.next_conn_id,
            connections: connection_details,
        }
    }
}

/// Statistics about a specific connection
#[derive(Debug, Clone)]
pub struct ConnectionStats {
    pub connection_id: ConnectionId,
    pub session_count: usize,
}

/// Registry statistics for observability
#[derive(Debug, Clone)]
pub struct RegistryStats {
    pub total_connections: usize,
    pub total_sessions: usize,
    pub max_connections: usize,
    pub next_conn_id: usize,
    pub connections: Vec<ConnectionStats>,
}

lazy_static! {
    /// Global registry instance
    ///
    /// # Panics
    ///
    /// All functions that access this registry will panic if the mutex is poisoned.
    /// See module-level documentation for details on mutex poisoning behavior.
    pub static ref REGISTRY: Arc<Mutex<Registry>> = Arc::new(Mutex::new(Registry::new()));
}

/// Helper functions for registry access
///
/// **Note:** All helper functions below will panic if the registry mutex is poisoned.
/// See module-level documentation for details.
/// Create a new connection and connect to an nREPL server
///
/// # Panics
///
/// Panics if the registry mutex is poisoned (see module documentation).
pub fn create_and_connect(address: String) -> Result<ConnectionId, NReplError> {
    REGISTRY.lock().unwrap().create_and_connect(address)
}

pub fn submit_eval(
    conn_id: ConnectionId,
    session: Session,
    code: String,
    timeout: Option<Duration>,
) -> Option<Result<RequestId, SubmitError>> {
    REGISTRY
        .lock()
        .unwrap()
        .submit_eval(conn_id, session, code, timeout)
}

pub fn submit_load_file(
    conn_id: ConnectionId,
    session: Session,
    file_contents: String,
    file_path: Option<String>,
    file_name: Option<String>,
) -> Option<Result<RequestId, SubmitError>> {
    REGISTRY
        .lock()
        .unwrap()
        .submit_load_file(conn_id, session, file_contents, file_path, file_name)
}

pub fn try_recv_response(conn_id: ConnectionId, request_id: RequestId) -> Option<EvalResponse> {
    REGISTRY.lock().unwrap().try_recv_response(conn_id, request_id)
}

pub fn clone_session_blocking(conn_id: ConnectionId) -> Result<Session, NReplError> {
    REGISTRY.lock().unwrap().clone_session_blocking(conn_id)
}

pub fn interrupt_blocking(conn_id: ConnectionId, session: Session, interrupt_id: String) -> Result<(), NReplError> {
    REGISTRY.lock().unwrap().interrupt_blocking(conn_id, session, interrupt_id)
}

pub fn close_session_blocking(conn_id: ConnectionId, session: Session) -> Result<(), NReplError> {
    REGISTRY.lock().unwrap().close_session_blocking(conn_id, session)
}

pub fn stdin_blocking(conn_id: ConnectionId, session: Session, data: String) -> Result<(), NReplError> {
    REGISTRY.lock().unwrap().stdin_blocking(conn_id, session, data)
}

pub fn completions_blocking(
    conn_id: ConnectionId,
    session: Session,
    prefix: String,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> Result<Vec<String>, NReplError> {
    REGISTRY.lock().unwrap().completions_blocking(conn_id, session, prefix, ns, complete_fn)
}

pub fn lookup_blocking(
    conn_id: ConnectionId,
    session: Session,
    sym: String,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> Result<Response, NReplError> {
    REGISTRY.lock().unwrap().lookup_blocking(conn_id, session, sym, ns, lookup_fn)
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

pub fn remove_session(conn_id: ConnectionId, session_id: SessionId) -> Option<Session> {
    REGISTRY.lock().unwrap().remove_session(conn_id, session_id)
}

pub fn remove_connection(conn_id: ConnectionId) -> bool {
    REGISTRY.lock().unwrap().remove_connection(conn_id)
}

pub fn get_stats() -> RegistryStats {
    REGISTRY.lock().unwrap().get_stats()
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
        assert!(!registry.remove_connection(ConnectionId::new(999)));
    }

    #[test]
    fn test_registry_double_close_idempotent() {
        let mut registry = Registry::new();

        // This tests the expected behavior for double-close at the registry level
        // In practice, nrepl_close() first attempts to close all sessions,
        // then calls remove_connection() which removes the connection from the registry.

        // Simulate a connection being in the registry (we can't create real connections in unit tests)
        // The actual double-close behavior is tested in integration tests with real connections.

        // First removal of non-existent connection returns false
        let first_remove = registry.remove_connection(ConnectionId::new(42));
        assert!(!first_remove, "First removal of non-existent connection should return false");

        // Second removal of same non-existent connection also returns false (idempotent)
        let second_remove = registry.remove_connection(ConnectionId::new(42));
        assert!(!second_remove, "Second removal should also return false (idempotent behavior)");

        // This demonstrates that calling remove_connection multiple times is safe
        // and always returns false for connections that don't exist.
        // In the full nrepl_close() flow, the second call would return an error
        // when it tries to get_all_sessions() for the already-removed connection.
    }

    #[test]
    fn test_registry_get_nonexistent() {
        let registry = Registry::new();

        // Getting non-existent session should return None
        assert!(registry.get_session(ConnectionId::new(999), SessionId::new(1)).is_none());
        // Getting non-existent sessions list should return None
        assert!(registry.get_all_sessions(ConnectionId::new(999)).is_none());
    }

    #[test]
    fn test_max_connections_constant() {
        // Verify MAX_CONNECTIONS constant is set to expected value
        assert_eq!(MAX_CONNECTIONS, 100, "MAX_CONNECTIONS should be 100");
    }

    #[test]
    fn test_session_id_generation() {
        // Create two mock session entries to test session ID allocation
        // Note: We can't create real connections in unit tests,
        // but we can test the session ID logic would work correctly

        // Verify session IDs start at 1 (same as connection IDs)
        // This is tested implicitly through the integration tests,
        // but the logic is in add_session which increments next_session_id

        // The actual session isolation is tested in integration tests
        // where real connections and sessions are created
    }

    #[test]
    fn test_empty_registry() {
        let registry = Registry::new();

        // New registry should have no connections
        assert_eq!(registry.connections.len(), 0);
        // Next connection ID should be 1
        assert_eq!(registry.next_conn_id, 1);
    }

    #[test]
    fn test_failed_connection_preserves_id_allocation() {
        // This test documents the important behavior that failed connections
        // don't waste connection IDs.
        //
        // Looking at create_and_connect() implementation (lines 71-109):
        // 1. Worker is created
        // 2. Connection is attempted via worker.connect_blocking(address)
        // 3. ONLY on success:
        //    - next_conn_id is read (line 88)
        //    - next_conn_id is incremented (lines 89-91)
        //    - Connection entry is inserted with the ID
        // 4. On failure:
        //    - Worker is dropped (shuts down thread)
        //    - Error is returned
        //    - next_conn_id is NOT incremented
        //
        // This means:
        // - Failed connections don't waste IDs
        // - IDs remain sequential for successful connections
        // - No gaps in ID sequence from failed connection attempts
        //
        // This behavior is important for:
        // - Predictable ID allocation (IDs 1,2,3... for successful connections)
        // - No ID exhaustion from repeated connection failures
        // - Clean error recovery without side effects
        //
        // The actual behavior is tested in integration tests where
        // we can attempt real connections that may succeed or fail.

        let registry = Registry::new();

        // Verify initial state
        assert_eq!(registry.next_conn_id, 1, "Registry starts with ID 1");
        assert_eq!(registry.connections.len(), 0, "Registry starts empty");

        // Note: We can't test the actual failure path in unit tests
        // because it requires a real server connection attempt.
        // See integration tests for the full behavior.
    }
}
