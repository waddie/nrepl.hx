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

use nrepl_rs::{EvalResult, NReplClient, NReplError, Session};
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use tokio::runtime::Runtime;

/// Request ID for tracking async eval operations
pub type RequestId = usize;

/// Request to evaluate code
pub struct EvalRequest {
    pub request_id: RequestId,
    pub session: Session,
    pub code: String,
    pub timeout: Option<Duration>,
}

/// Response from evaluation
pub struct EvalResponse {
    pub request_id: RequestId,
    pub result: Result<EvalResult, NReplError>,
}

/// Commands that can be sent to the worker thread
pub enum WorkerCommand {
    Connect(String, Sender<Result<(), NReplError>>),
    Eval(EvalRequest),
    CloneSession(Sender<Result<Session, NReplError>>),
    CloseSession(Session, Sender<Result<(), NReplError>>),
    Shutdown,
}

/// Handle to a background worker thread
pub struct Worker {
    command_tx: Sender<WorkerCommand>,
    response_rx: Receiver<EvalResponse>,
    thread_handle: Option<JoinHandle<()>>,
    next_request_id: RequestId,
    // Buffer for responses - allows concurrent evals without losing responses
    pending_responses: RefCell<HashMap<RequestId, EvalResponse>>,
}

impl Worker {
    /// Create a new worker thread (client will be connected later via Connect command)
    pub fn new() -> Self {
        let (command_tx, command_rx) = channel::<WorkerCommand>();
        let (response_tx, response_rx) = channel::<EvalResponse>();

        let thread_handle = thread::spawn(move || {
            // Create a Tokio runtime for this worker thread
            let rt = Runtime::new().expect("Failed to create Tokio runtime for worker");

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
                                result: Err(NReplError::Protocol("Not connected".to_string())),
                            };
                            let _ = response_tx.send(response);
                            continue;
                        };
                        // Block on async eval - this is fine because we're on a background thread
                        let result = if let Some(timeout) = req.timeout {
                            rt.block_on(
                                c.eval_with_timeout(&req.session, req.code, timeout),
                            )
                        } else {
                            rt.block_on(c.eval(&req.session, req.code))
                        };

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
                    Ok(WorkerCommand::CloneSession(response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::Protocol("Not connected".to_string())));
                            continue;
                        };

                        // Block on async clone_session
                        let result = rt.block_on(c.clone_session());

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::CloseSession(session, response_tx)) => {
                        let Some(ref mut c) = client else {
                            let _ = response_tx.send(Err(NReplError::Protocol("Not connected".to_string())));
                            continue;
                        };

                        // Block on async close_session
                        let result = rt.block_on(c.close_session(session));

                        // Send response back (one-shot)
                        let _ = response_tx.send(result);
                    }
                    Ok(WorkerCommand::Shutdown) => {
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
            thread_handle: Some(thread_handle),
            next_request_id: 1,
            pending_responses: RefCell::new(HashMap::new()),
        }
    }

    /// Connect to an nREPL server (blocking call)
    pub fn connect_blocking(&self, address: String) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::Connect(address, response_tx))
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?;

        response_rx
            .recv()
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?
    }

    /// Submit an eval request and return the request ID
    pub fn submit_eval(&mut self, session: Session, code: String, timeout: Option<Duration>) -> RequestId {
        let request_id = self.next_request_id;
        self.next_request_id += 1;

        let request = EvalRequest {
            request_id,
            session,
            code,
            timeout,
        };

        // Send request to worker thread (non-blocking)
        let _ = self.command_tx.send(WorkerCommand::Eval(request));

        request_id
    }

    /// Try to receive a completed eval response for a specific request (non-blocking)
    ///
    /// Buffers responses to support multiple concurrent evals without losing responses.
    pub fn try_recv_response(&self, request_id: RequestId) -> Option<EvalResponse> {
        let mut pending = self.pending_responses.borrow_mut();

        // First check if response is already buffered
        if let Some(response) = pending.remove(&request_id) {
            return Some(response);
        }

        // Not buffered yet - drain all available responses from channel into buffer
        while let Ok(response) = self.response_rx.try_recv() {
            pending.insert(response.request_id, response);
        }

        // Check again if our response arrived
        pending.remove(&request_id)
    }

    /// Clone a session (blocking call)
    pub fn clone_session_blocking(&self) -> Result<Session, NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::CloneSession(response_tx))
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?;

        response_rx
            .recv()
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?
    }

    /// Close a session (blocking call)
    pub fn close_session_blocking(&self, session: Session) -> Result<(), NReplError> {
        let (response_tx, response_rx) = channel();

        self.command_tx
            .send(WorkerCommand::CloseSession(session, response_tx))
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?;

        response_rx
            .recv()
            .map_err(|_| NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::Other,
                "Worker thread disconnected",
            )))?
    }

    /// Shutdown the worker thread
    pub fn shutdown(&mut self) {
        let _ = self.command_tx.send(WorkerCommand::Shutdown);
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.shutdown();
    }
}
