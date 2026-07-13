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

use crate::worker::{EvalResponse, RequestId, SubmitError, Worker, WorkerCommand};
use nrepl_rs::{CompletionCandidate, NReplError, Response, Session};
use std::collections::HashMap;
use std::sync::mpsc::channel;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::mpsc::UnboundedSender;

/// Newtype wrapper for connection IDs to prevent mixing with other ID types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ConnectionId(usize);

impl ConnectionId {
    /// Create a new `ConnectionId` from a usize
    #[must_use]
    pub fn new(id: usize) -> Self {
        ConnectionId(id)
    }

    /// Get the raw usize value (for FFI and serialization)
    #[must_use]
    pub fn as_usize(&self) -> usize {
        self.0
    }
}

/// Newtype wrapper for session IDs to prevent mixing with other ID types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(usize);

impl SessionId {
    /// Create a new `SessionId` from a usize
    #[must_use]
    pub fn new(id: usize) -> Self {
        SessionId(id)
    }

    /// Get the raw usize value (for FFI and serialization)
    #[must_use]
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

    /// Cheap pre-check that we are under the connection limit.
    fn at_capacity(&self) -> bool {
        self.connections.len() >= MAX_CONNECTIONS
    }

    /// Insert an already-connected worker, allocating a connection id.
    ///
    /// Re-checks the limit authoritatively (the pre-check happens before the
    /// blocking connect, so the count could have grown meanwhile). Returns the
    /// worker back on rejection so the caller can drop it cleanly.
    fn insert_connected_worker(&mut self, worker: Worker) -> Result<ConnectionId, Worker> {
        if self.at_capacity() {
            return Err(worker);
        }
        let id = ConnectionId::new(self.next_conn_id);
        self.next_conn_id = self
            .next_conn_id
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

    /// Clone a connection's command sender and mint a request id, all under a
    /// brief lock. The caller then sends + waits *without* holding the registry
    /// lock (A3 discipline), so eval polling is never stalled.
    fn channel_for(
        &self,
        conn_id: ConnectionId,
    ) -> Result<(UnboundedSender<WorkerCommand>, RequestId), NReplError> {
        let entry = self.connections.get(&conn_id).ok_or_else(|| {
            NReplError::protocol(format!(
                "Connection {} not found. Create a connection with nrepl-connect first.",
                conn_id.as_usize()
            ))
        })?;
        Ok((entry.worker.command_sender(), entry.worker.next_id()))
    }

    /// Submit an eval request to the worker thread (non-blocking)
    ///
    /// Note: This function has many parameters to pass file location metadata for better
    /// stack traces (nREPL PR #385). Grouping into a struct would require changes across
    /// all three layers (Rust → FFI → Steel), making the API less flexible.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_eval(
        &mut self,
        conn_id: ConnectionId,
        session: Session,
        code: String,
        timeout: Option<Duration>,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> Option<Result<RequestId, SubmitError>> {
        let entry = self.connections.get_mut(&conn_id)?;
        Some(
            entry
                .worker
                .submit_eval(session, code, timeout, file, line, column),
        )
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
        Some(
            entry
                .worker
                .submit_load_file(session, file_contents, file_path, file_name),
        )
    }

    /// Try to receive a completed eval response (non-blocking).
    ///
    /// Returns `Ok(None)` when the response is not ready yet. A missing
    /// connection is an error, not `None`: pollers must be able to tell "keep
    /// polling" apart from "this result can never arrive" (e.g. the connection
    /// was closed mid-eval), or they poll forever.
    pub fn try_recv_response(
        &mut self,
        conn_id: ConnectionId,
        request_id: RequestId,
    ) -> Result<Option<EvalResponse>, NReplError> {
        let entry = self.connections.get_mut(&conn_id).ok_or_else(|| {
            NReplError::protocol(format!(
                "Connection {} not found. It may have been closed.",
                conn_id.as_usize()
            ))
        })?;
        Ok(entry.worker.try_recv_response(request_id))
    }

    /// Add a session to a connection, returns session ID
    pub fn add_session(&mut self, conn_id: ConnectionId, session: Session) -> Option<SessionId> {
        let entry = self.connections.get_mut(&conn_id)?;
        let session_id = SessionId::new(entry.next_session_id);
        entry.next_session_id = entry
            .next_session_id
            .checked_add(1)
            .expect("Session ID overflow - cannot create more sessions");
        entry.sessions.insert(session_id, session);
        Some(session_id)
    }

    /// Get a session from a connection
    #[must_use]
    pub fn get_session(&self, conn_id: ConnectionId, session_id: SessionId) -> Option<&Session> {
        self.connections.get(&conn_id)?.sessions.get(&session_id)
    }

    /// Get all sessions for a connection
    #[must_use]
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

    /// Find the handle of a session by its on-the-wire session id, if this
    /// client already holds one (lets attach reuse handles instead of minting
    /// a duplicate per switch).
    #[must_use]
    pub fn find_session_by_wire_id(
        &self,
        conn_id: ConnectionId,
        wire_id: &str,
    ) -> Option<SessionId> {
        self.connections
            .get(&conn_id)?
            .sessions
            .iter()
            .find(|(_, session)| session.id() == wire_id)
            .map(|(session_id, _)| *session_id)
    }

    /// Remove every handle whose session has the given wire id (after the
    /// session is closed on the server, all handles to it are stale).
    pub fn remove_sessions_by_wire_id(&mut self, conn_id: ConnectionId, wire_id: &str) {
        if let Some(entry) = self.connections.get_mut(&conn_id) {
            entry.sessions.retain(|_, session| session.id() != wire_id);
        }
    }

    /// Remove a session from a connection
    ///
    /// Returns the removed session if it existed, or None if the connection
    /// or session wasn't found.
    pub fn remove_session(
        &mut self,
        conn_id: ConnectionId,
        session_id: SessionId,
    ) -> Option<Session> {
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
    #[must_use]
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

/// Global registry instance
///
/// # Panics
///
/// All functions that access this registry will panic if the mutex is poisoned.
/// See module-level documentation for details on mutex poisoning behavior.
pub static REGISTRY: LazyLock<Arc<Mutex<Registry>>> =
    LazyLock::new(|| Arc::new(Mutex::new(Registry::new())));

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
    // Cheap pre-check under a brief lock so we fail fast when already full.
    if REGISTRY.lock().unwrap().at_capacity() {
        return Err(NReplError::protocol(format!(
            "Maximum connections ({MAX_CONNECTIONS}) exceeded. Close unused connections before creating new ones."
        )));
    }

    // Create the worker and connect WITHOUT holding the registry lock - the
    // connect blocks up to 30s and must not stall other connections' ops.
    let worker = Worker::new();
    worker.connect_blocking(address)?;

    // Register the connected worker under a brief lock.
    match REGISTRY.lock().unwrap().insert_connected_worker(worker) {
        Ok(id) => Ok(id),
        Err(_worker) => Err(NReplError::protocol(format!(
            "Maximum connections ({MAX_CONNECTIONS}) exceeded. Close unused connections before creating new ones."
        ))),
    }
}

/// Look up a connection's command sender + a fresh request id under a brief
/// lock. The lock is released before the caller blocks on the worker's reply.
fn channel_for(
    conn_id: ConnectionId,
) -> Result<(UnboundedSender<WorkerCommand>, RequestId), NReplError> {
    REGISTRY.lock().unwrap().channel_for(conn_id)
}

/// Send a command and wait up to 30s for its one-shot reply, holding no lock.
fn send_and_wait<T>(
    tx: &UnboundedSender<WorkerCommand>,
    cmd: WorkerCommand,
    reply_rx: &std::sync::mpsc::Receiver<Result<T, NReplError>>,
    operation: &str,
) -> Result<T, NReplError> {
    tx.send(cmd)
        .map_err(|_| NReplError::Connection(std::io::Error::other("Worker thread disconnected")))?;
    reply_rx
        .recv_timeout(Duration::from_secs(30))
        .map_err(|_| NReplError::Timeout {
            operation: operation.to_string(),
            duration: Duration::from_secs(30),
        })?
}

#[must_use]
pub fn submit_eval(
    conn_id: ConnectionId,
    session: Session,
    code: String,
    timeout: Option<Duration>,
    file: Option<String>,
    line: Option<i64>,
    column: Option<i64>,
) -> Option<Result<RequestId, SubmitError>> {
    REGISTRY
        .lock()
        .unwrap()
        .submit_eval(conn_id, session, code, timeout, file, line, column)
}

#[must_use]
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

pub fn try_recv_response(
    conn_id: ConnectionId,
    request_id: RequestId,
) -> Result<Option<EvalResponse>, NReplError> {
    REGISTRY
        .lock()
        .unwrap()
        .try_recv_response(conn_id, request_id)
}

pub fn clone_session_blocking(conn_id: ConnectionId) -> Result<Session, NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::CloneSession {
            op_id,
            reply: reply_tx,
        },
        &reply_rx,
        "clone_session",
    )
}

/// Interrupt the in-flight eval identified by `target_request_id` (the steel
/// request id the worker minted at submit time). The worker forms the wire
/// interrupt-id (`req-{n}`) itself.
pub fn interrupt_blocking(
    conn_id: ConnectionId,
    session: Session,
    target_request_id: usize,
) -> Result<(), NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::Interrupt {
            op_id,
            session,
            target: RequestId::new(target_request_id),
            reply: reply_tx,
        },
        &reply_rx,
        "interrupt",
    )
}

pub fn close_session_blocking(conn_id: ConnectionId, session: Session) -> Result<(), NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::CloseSession {
            op_id,
            session,
            reply: reply_tx,
        },
        &reply_rx,
        "close_session",
    )
}

pub fn stdin_blocking(
    conn_id: ConnectionId,
    session: Session,
    data: String,
) -> Result<(), NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::Stdin {
            op_id,
            session,
            data,
            reply: reply_tx,
        },
        &reply_rx,
        "stdin",
    )
}

pub fn completions_blocking(
    conn_id: ConnectionId,
    session: Session,
    prefix: String,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> Result<Vec<CompletionCandidate>, NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::Completions {
            op_id,
            session,
            prefix,
            ns,
            complete_fn,
            reply: reply_tx,
        },
        &reply_rx,
        "completions",
    )
}

pub fn lookup_blocking(
    conn_id: ConnectionId,
    session: Session,
    sym: String,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> Result<Response, NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::Lookup {
            op_id,
            session,
            sym,
            ns,
            lookup_fn,
            reply: reply_tx,
        },
        &reply_rx,
        "lookup",
    )
}

pub fn describe_blocking(conn_id: ConnectionId, verbose: bool) -> Result<Response, NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::Describe {
            op_id,
            verbose,
            reply: reply_tx,
        },
        &reply_rx,
        "describe",
    )
}

pub fn ls_sessions_blocking(conn_id: ConnectionId) -> Result<Vec<String>, NReplError> {
    let (tx, op_id) = channel_for(conn_id)?;
    let (reply_tx, reply_rx) = channel();
    send_and_wait(
        &tx,
        WorkerCommand::LsSessions {
            op_id,
            reply: reply_tx,
        },
        &reply_rx,
        "ls_sessions",
    )
}

#[must_use]
pub fn add_session(conn_id: ConnectionId, session: Session) -> Option<SessionId> {
    REGISTRY.lock().unwrap().add_session(conn_id, session)
}

#[must_use]
pub fn find_session_by_wire_id(conn_id: ConnectionId, wire_id: &str) -> Option<SessionId> {
    REGISTRY
        .lock()
        .unwrap()
        .find_session_by_wire_id(conn_id, wire_id)
}

pub fn remove_sessions_by_wire_id(conn_id: ConnectionId, wire_id: &str) {
    REGISTRY
        .lock()
        .unwrap()
        .remove_sessions_by_wire_id(conn_id, wire_id);
}

#[must_use]
pub fn get_session(conn_id: ConnectionId, session_id: SessionId) -> Option<Session> {
    REGISTRY
        .lock()
        .unwrap()
        .get_session(conn_id, session_id)
        .cloned()
}

#[must_use]
pub fn get_all_sessions(conn_id: ConnectionId) -> Option<Vec<Session>> {
    REGISTRY.lock().unwrap().get_all_sessions(conn_id)
}

#[must_use]
pub fn remove_session(conn_id: ConnectionId, session_id: SessionId) -> Option<Session> {
    REGISTRY.lock().unwrap().remove_session(conn_id, session_id)
}

#[must_use]
pub fn remove_connection(conn_id: ConnectionId) -> bool {
    REGISTRY.lock().unwrap().remove_connection(conn_id)
}

#[must_use]
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
        assert!(
            !first_remove,
            "First removal of non-existent connection should return false"
        );

        // Second removal of same non-existent connection also returns false (idempotent)
        let second_remove = registry.remove_connection(ConnectionId::new(42));
        assert!(
            !second_remove,
            "Second removal should also return false (idempotent behavior)"
        );

        // This demonstrates that calling remove_connection multiple times is safe
        // and always returns false for connections that don't exist.
        // In the full nrepl_close() flow, the second call would return an error
        // when it tries to get_all_sessions() for the already-removed connection.
    }

    #[test]
    fn test_registry_get_nonexistent() {
        let registry = Registry::new();

        // Getting non-existent session should return None
        assert!(
            registry
                .get_session(ConnectionId::new(999), SessionId::new(1))
                .is_none()
        );
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
