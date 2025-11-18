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

//! Background worker thread for async nREPL operations

use nrepl_rs::{CompletionCandidate, EvalResult, NReplClient, NReplError, Response, Session};
use std::collections::HashMap;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;
use std::time::Duration;

/// Newtype wrapper for request IDs to prevent mixing with other ID types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RequestId(usize);

impl RequestId {
    /// Create a new RequestId from a usize
    pub fn new(id: usize) -> Self {
        RequestId(id)
    }

    /// Get the raw usize value (for FFI and serialization)
    pub fn as_usize(&self) -> usize {
        self.0
    }
}

/// Maximum number of pending responses to buffer
/// Prevents unbounded memory growth if client doesn't retrieve responses
const MAX_PENDING_RESPONSES: usize = 1000;

/// Error type for submission operations (eval/load-file)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitError {
    /// Worker thread has died or disconnected
    WorkerDisconnected,
    /// Request ID overflow (billions of requests processed)
    RequestIdOverflow,
}

impl std::fmt::Display for SubmitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SubmitError::WorkerDisconnected => {
                write!(f, "Worker thread has died or disconnected")
            }
            SubmitError::RequestIdOverflow => {
                write!(
                    f,
                    "Request ID overflow - worker thread has processed billions of requests"
                )
            }
        }
    }
}

impl std::error::Error for SubmitError {}

/// Request to evaluate code
pub struct EvalRequest {
    pub request_id: RequestId,
    pub session: Session,
    pub code: String,
    pub timeout: Option<Duration>,
    pub file: Option<String>,
    pub line: Option<i64>,
    pub column: Option<i64>,
}

/// Request to load a file
pub struct LoadFileRequest {
    pub request_id: RequestId,
    pub session: Session,
    pub file_contents: String,
    pub file_path: Option<String>,
    pub file_name: Option<String>,
}

/// Response from evaluation or load-file
pub struct EvalResponse {
    pub request_id: RequestId,
    pub result: Result<EvalResult, NReplError>,
}

/// Commands that can be sent to the worker thread
pub enum WorkerCommand {
    Connect(String, Sender<Result<(), NReplError>>),
    Eval(EvalRequest),
    LoadFile(LoadFileRequest),
    Interrupt(Session, String, Sender<Result<(), NReplError>>),
    CloneSession(Sender<Result<Session, NReplError>>),
    CloseSession(Session, Sender<Result<(), NReplError>>),
    Stdin(Session, String, Sender<Result<(), NReplError>>),
    Completions(
        Session,
        String,
        Option<String>,
        Option<String>,
        Sender<Result<Vec<CompletionCandidate>, NReplError>>,
    ),
    Lookup(
        Session,
        String,
        Option<String>,
        Option<String>,
        Sender<Result<Response, NReplError>>,
    ),
    Shutdown(Sender<Result<(), NReplError>>),
}

/// Handle to a background worker thread
///
/// # Request ID Overflow
///
/// Request IDs are `usize` and increment with each `submit_eval` or `submit_load_file` call.
/// On 64-bit systems, this allows for 2^64 requests before overflow (~18 quintillion).
/// On 32-bit systems, overflow occurs after 2^32 requests (~4 billion).
///
/// **Overflow behavior:** Currently uses checked addition with panic on overflow.
/// This is acceptable because:
/// - Reaching overflow would require billions/quintillions of requests
/// - The worker and connection would typically be recreated long before overflow
/// - A panic here indicates an exceptional edge case requiring investigation
///
/// **Future improvement:** If needed, could use `wrapping_add` for wraparound behavior,
/// though this introduces risk of request ID collisions if old responses remain buffered.
pub struct Worker {
    command_tx: Sender<WorkerCommand>,
    response_rx: Receiver<EvalResponse>,
    next_request_id: usize,
    // Buffer for responses - allows concurrent evals without losing responses
    pending_responses: HashMap<RequestId, EvalResponse>,
}

impl Worker {
    /// Create a new worker thread (client will be connected later via Connect command)
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        let (command_tx, command_rx) = channel::<WorkerCommand>();
        let (response_tx, response_rx) = channel::<EvalResponse>();

        // Spawn worker thread - it will run until shutdown command or channel closes
        let _worker_thread = thread::spawn(move || {
            // Create a single-threaded Tokio runtime for this worker thread
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create Tokio runtime for worker");

            // Client will be set when Connect command is received
            let mut client: Option<NReplClient> = None;

            loop {
                match command_rx.recv() {
                    Ok(WorkerCommand::Connect(address, response_tx)) => {
                        // Establish connection within this worker's runtime
                        let result = rt.block_on(NReplClient::connect(&address));

                        match result {
                            Ok(c) => {
                                client = Some(c);
                                let _ = response_tx.send(Ok(()));
                            }
                            Err(e) => {
                                let _ = response_tx.send(Err(e));
                            }
                        }
                    }
                    Ok(WorkerCommand::Eval(req)) => {
                        let Some(ref mut c) = client else {
                            // No client connected yet, send error
                            let response = EvalResponse {
                                request_id: req.request_id,
                                result: Err(NReplError::protocol("Not connected")),
                            };
                            let _ = response_tx.send(response);
                            continue;
                        };
                        // Block on async eval - this is fine because we're on a background thread
                        // Use eval_with_location to pass file metadata
                        let timeout = req.timeout.unwrap_or(Duration::from_secs(120));
                        let result = rt.block_on(c.eval_with_location(
                            &req.session,
                            req.code,
                            req.file,
                            req.line,
                            req.column,
                            timeout,
                        ));

                        // Send response back
                        let response = EvalResponse {
                            request_id: req.request_id,
                            result,
                        };

                        if response_tx.send(response).is_err() {
                            // Main thread disconnected, exit
                            break;
                        }
                    }
                    Ok(WorkerCommand::LoadFile(req)) => {
                        let Some(ref mut c) = client else {
                            // No client connected yet, send error
                            let response = EvalResponse {
                                request_id: req.request_id,
                                result: Err(NReplError::protocol("Not connected")),
                            };
                            let _ = response_tx.send(response);
                            continue;
                        };
                        // Block on async load_file
                        let result = rt.block_on(c.load_file(
                            &req.session,
                            req.file_contents,
                            req.file_path,
                            req.file_name,
                        ));

                        // Send response back
                        let response = EvalResponse {
                            request_id: req.request_id,
                            result,
                        };

                        if response_tx.send(response).is_err() {
                            // Main thread disconnected, exit
                            break;
                        }
                    }
                    Ok(WorkerCommand::Interrupt(session, interrupt_id, response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async interrupt
                        let result = rt.block_on(c.interrupt(&session, interrupt_id));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::CloneSession(response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async clone_session
                        let result = rt.block_on(c.clone_session());

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::CloseSession(session, response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async close_session
                        let result = rt.block_on(c.close_session(session));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::Stdin(session, data, response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async stdin
                        let result = rt.block_on(c.stdin(&session, data));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::Completions(
                        session,
                        prefix,
                        ns,
                        complete_fn,
                        response_tx,
                    )) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async completions
                        let result = rt.block_on(c.completions(&session, prefix, ns, complete_fn));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::Lookup(session, sym, ns, lookup_fn, response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::protocol("Not connected")));
                            continue;
                        };

                        // Block on async lookup
                        let result = rt.block_on(c.lookup(&session, sym, ns, lookup_fn));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::Shutdown(response_tx)) => {
                        // Gracefully shutdown client if connected
                        if let Some(c) = client.take() {
                            let shutdown_result = rt.block_on(c.shutdown());
                            let _ = response_tx.send(shutdown_result);
                        } else {
                            let _ = response_tx.send(Ok(()));
                        }
                        break;
                    }
                    Err(_) => {
                        // Channel closed, exit
                        break;
                    }
                }
            }
        });

        Self {
            command_tx,
            response_rx,
            next_request_id: 1,
            pending_responses: HashMap::new(),
        }
    }

    /// Connect to an nREPL server (blocking call with 30s timeout)
    pub fn connect_blocking(&self, address: String) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Connect(address, response_tx))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "connect".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Submit an eval request and return the request ID
    ///
    /// Returns an error if the worker thread has died or disconnected, or if
    /// request ID overflow occurs (after billions of requests).
    pub fn submit_eval(
        &mut self,
        session: Session,
        code: String,
        timeout: Option<Duration>,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> Result<RequestId, SubmitError> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or(SubmitError::RequestIdOverflow)?;

        let request = EvalRequest {
            request_id: RequestId::new(request_id),
            session,
            code,
            timeout,
            file,
            line,
            column,
        };

        // Send request to worker thread (non-blocking)
        self.command_tx
            .send(WorkerCommand::Eval(request))
            .map_err(|_| SubmitError::WorkerDisconnected)?;

        Ok(RequestId::new(request_id))
    }

    /// Submit a load-file request and return the request ID
    ///
    /// Returns an error if the worker thread has died or disconnected, or if
    /// request ID overflow occurs (after billions of requests).
    pub fn submit_load_file(
        &mut self,
        session: Session,
        file_contents: String,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> Result<RequestId, SubmitError> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or(SubmitError::RequestIdOverflow)?;

        let request = LoadFileRequest {
            request_id: RequestId::new(request_id),
            session,
            file_contents,
            file_path,
            file_name,
        };

        // Send request to worker thread (non-blocking)
        self.command_tx
            .send(WorkerCommand::LoadFile(request))
            .map_err(|_| SubmitError::WorkerDisconnected)?;

        Ok(RequestId::new(request_id))
    }

    /// Try to receive a completed eval response for a specific request (non-blocking)
    ///
    /// Buffers responses to support multiple concurrent evals without losing responses.
    /// Enforces MAX_PENDING_RESPONSES limit to prevent unbounded memory growth.
    pub fn try_recv_response(&mut self, request_id: RequestId) -> Option<EvalResponse> {
        // First check if response is already buffered
        if let Some(response) = self.pending_responses.remove(&request_id) {
            return Some(response);
        }

        // Not buffered yet - drain available responses from channel into buffer
        // Stop at MAX_PENDING_RESPONSES limit to prevent unbounded growth
        while self.pending_responses.len() < MAX_PENDING_RESPONSES {
            match self.response_rx.try_recv() {
                Ok(response) => {
                    self.pending_responses.insert(response.request_id, response);
                }
                Err(_) => break, // Channel empty or disconnected
            }
        }

        // Check again if our response arrived
        self.pending_responses.remove(&request_id)
    }

    /// Clone a session (blocking call with 30s timeout)
    pub fn clone_session_blocking(&self) -> Result<Session, NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::CloneSession(response_tx))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "clone_session".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Interrupt an ongoing evaluation (blocking call with 30s timeout)
    pub fn interrupt_blocking(
        &self,
        session: Session,
        interrupt_id: String,
    ) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Interrupt(session, interrupt_id, response_tx))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "interrupt".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Close a session (blocking call with 30s timeout)
    pub fn close_session_blocking(&self, session: Session) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::CloseSession(session, response_tx))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "close_session".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Send stdin data to a session (blocking call with 30s timeout)
    pub fn stdin_blocking(&self, session: Session, data: String) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Stdin(session, data, response_tx))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "stdin".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Get code completions (blocking call with 30s timeout)
    pub fn completions_blocking(
        &self,
        session: Session,
        prefix: String,
        ns: Option<String>,
        complete_fn: Option<String>,
    ) -> Result<Vec<CompletionCandidate>, NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Completions(
                session,
                prefix,
                ns,
                complete_fn,
                response_tx,
            ))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "completions".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Lookup symbol information (blocking call with 30s timeout)
    pub fn lookup_blocking(
        &self,
        session: Session,
        sym: String,
        ns: Option<String>,
        lookup_fn: Option<String>,
    ) -> Result<Response, NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Lookup(
                session,
                sym,
                ns,
                lookup_fn,
                response_tx,
            ))
            .map_err(|_| {
                NReplError::Connection(std::io::Error::other("Worker thread disconnected"))
            })?;

        response_rx
            .recv_timeout(Duration::from_secs(30))
            .map_err(|_| NReplError::Timeout {
                operation: "lookup".to_string(),
                duration: Duration::from_secs(30),
            })?
    }

    /// Shutdown the worker thread
    ///
    /// Sends a shutdown command to the worker thread and returns immediately.
    /// The worker thread will close all sessions and the TCP connection in the background.
    ///
    /// **Non-blocking:** This function does not wait for the worker thread to finish.
    /// The thread will complete shutdown asynchronously and exit cleanly.
    pub fn shutdown(&mut self) {
        // Send shutdown command (non-blocking - just sends message to channel)
        // The worker thread will process it and exit cleanly
        let _ = self.command_tx.send(WorkerCommand::Shutdown(channel().0));

        // Don't join the thread - let it finish in the background
        // This prevents blocking when called from Drop during disconnect
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_worker_construction() {
        // Worker should construct successfully
        let worker = Worker::new();

        // Verify initial state
        assert_eq!(worker.next_request_id, 1, "Request ID should start at 1");
        assert_eq!(
            worker.pending_responses.len(),
            0,
            "Should have no pending responses initially"
        );

        // Drop worker to cleanup (thread will shutdown via Drop trait)
    }

    #[test]
    fn test_request_id_generation() {
        let worker = Worker::new();

        // Request IDs should increment sequentially
        assert_eq!(worker.next_request_id, 1);

        // Note: We can't actually call submit_eval without a real connection,
        // but the ID increment logic is visible: next_request_id is incremented
        // in submit_eval (line 239) and submit_load_file (line 267)

        // The actual request ID generation is tested in integration tests
    }

    #[test]
    fn test_pending_responses_initially_empty() {
        let worker = Worker::new();

        // Pending responses map should be empty at construction
        assert!(
            worker.pending_responses.is_empty(),
            "New worker should have no pending responses"
        );
    }

    #[test]
    fn test_worker_spawns_thread() {
        // This test documents that Worker::new() spawns a background thread
        // The thread runs until shutdown or channel closes
        //
        // The thread is not joined when Worker is dropped - it finishes in the background
        // This prevents blocking the calling thread during disconnect

        let worker = Worker::new();

        // Worker should be constructed successfully
        assert_eq!(
            worker.next_request_id, 1,
            "Worker should initialize with request ID 1"
        );
    }

    #[test]
    fn test_max_pending_responses_limit_exists() {
        // This test documents the protection against unbounded response buffer growth
        //
        // Background:
        // The worker maintains a pending_responses HashMap that buffers responses
        // from the worker thread. This allows multiple concurrent evaluations without
        // losing responses that arrive before the client polls for them.
        //
        // Problem without limit:
        // If a client submits many evaluations but never retrieves results,
        // the HashMap would grow without bound, causing memory exhaustion.
        //
        // Solution:
        // MAX_PENDING_RESPONSES (line 26) limits the buffer to 1000 entries.
        // In try_recv_response (line 362), we stop draining responses from the
        // channel once we hit this limit:
        //
        //   while self.pending_responses.len() < MAX_PENDING_RESPONSES {
        //       match self.response_rx.try_recv() { ... }
        //   }
        //
        // This means:
        // - First 1000 responses are buffered for later retrieval
        // - Additional responses remain in the mpsc channel (which has its own memory)
        // - Once buffered responses are retrieved, more can be drained from the channel
        // - Normal usage (retrieve results promptly) never hits this limit
        //
        // The actual buffer limit behavior is tested in integration tests where
        // we can submit many evaluations and observe the buffering behavior.

        // Verify the limit constant is set to a reasonable value
        assert_eq!(
            MAX_PENDING_RESPONSES, 1000,
            "MAX_PENDING_RESPONSES should be 1000"
        );

        // Verify a new worker has no pending responses initially
        let worker = Worker::new();
        assert_eq!(
            worker.pending_responses.len(),
            0,
            "New worker should have empty buffer"
        );
    }
}
