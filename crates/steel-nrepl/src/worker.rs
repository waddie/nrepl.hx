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
//!
//! # Demux model
//!
//! Each connection has one worker thread running a single-threaded Tokio
//! runtime. The thread connects, splits the client into an [`NReplWriter`] and
//! [`NReplReader`], then runs an event loop that `select!`s over:
//!
//! - the command channel (eval / load-file / interrupt / stdin / control ops),
//! - the socket reader (responses, routed by request id),
//! - the active eval's deadline.
//!
//! The command channel is *always* able to receive, so an interrupt or stdin
//! can be written while an eval is parked accumulating responses. Evals are
//! serialized through a single `active_eval` + queue; control ops bypass the
//! queue and are written immediately, so completions/lookup can run during a
//! long eval. This is what makes `interrupt` actually work.

use nrepl_rs::{
    CompletionCandidate, EvalAccumulator, EvalResult, NReplClient, NReplError, NReplReader,
    NReplWriter, Response, Session, classify, ops,
};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;
use std::time::Duration;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::time::Instant;

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

    /// The on-the-wire id this request uses (`req-{n}`).
    fn wire(&self) -> String {
        ops::wire_id(self.0)
    }
}

/// Maximum number of pending responses to buffer
/// Prevents unbounded memory growth if client doesn't retrieve responses
const MAX_PENDING_RESPONSES: usize = 1000;

/// Default eval timeout when a submission does not specify one (60 seconds).
const DEFAULT_EVAL_TIMEOUT: Duration = Duration::from_secs(60);

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

/// Outcome of an eval/load-file delivered to the polling main thread.
pub enum EvalOutcome {
    /// The evaluation finished (successfully or with an error/timeout).
    Done(Result<EvalResult, NReplError>),
    /// The evaluation is blocked waiting for `stdin` (`need-input`). The caller
    /// should prompt and send a `stdin` command targeting this request id, then
    /// keep polling for the eventual `Done`.
    NeedInput,
}

/// Response from evaluation or load-file
pub struct EvalResponse {
    pub request_id: RequestId,
    pub outcome: EvalOutcome,
}

/// Commands that can be sent to the worker thread
pub enum WorkerCommand {
    Connect(String, Sender<Result<(), NReplError>>),
    Eval(EvalRequest),
    LoadFile(LoadFileRequest),
    /// Interrupt the eval whose request id is `target`. `op_id` is this
    /// interrupt request's own id.
    Interrupt {
        op_id: RequestId,
        session: Session,
        target: RequestId,
        reply: Sender<Result<(), NReplError>>,
    },
    CloneSession {
        op_id: RequestId,
        reply: Sender<Result<Session, NReplError>>,
    },
    CloseSession {
        op_id: RequestId,
        session: Session,
        reply: Sender<Result<(), NReplError>>,
    },
    /// Send stdin input targeting an in-flight eval. Fire-and-forget: nREPL does
    /// not ack stdin, so we reply Ok once the request is written.
    Stdin {
        op_id: RequestId,
        session: Session,
        data: String,
        reply: Sender<Result<(), NReplError>>,
    },
    Completions {
        op_id: RequestId,
        session: Session,
        prefix: String,
        ns: Option<String>,
        complete_fn: Option<String>,
        reply: Sender<Result<Vec<CompletionCandidate>, NReplError>>,
    },
    Lookup {
        op_id: RequestId,
        session: Session,
        sym: String,
        ns: Option<String>,
        lookup_fn: Option<String>,
        reply: Sender<Result<Response, NReplError>>,
    },
    Shutdown(Sender<Result<(), NReplError>>),
}

/// A queued eval/load-file awaiting its turn behind the active eval.
struct QueuedEval {
    request_id: RequestId,
    /// Pre-built request (already carries its wire id).
    request: nrepl_rs::Request,
    timeout: Duration,
}

/// In-flight eval state tracked in the demux loop.
struct EvalState {
    request_id: RequestId,
    acc: EvalAccumulator,
    timeout: Duration,
    deadline: Instant,
    /// True while parked on `need-input` (deadline suspended).
    parked: bool,
}

/// A control op awaiting its response, keyed in the pending map by wire id.
///
/// `Eval` is the large, common variant; boxing it to shrink the rarely-used
/// control variants would add an allocation on the hot eval path, so we accept
/// the size difference.
#[allow(clippy::large_enum_variant)]
enum Pending {
    Eval(EvalState),
    CloneSession {
        reply: Sender<Result<Session, NReplError>>,
        new_session: Option<String>,
    },
    CloseSession {
        reply: Sender<Result<(), NReplError>>,
    },
    Interrupt {
        reply: Sender<Result<(), NReplError>>,
    },
    Completions {
        reply: Sender<Result<Vec<CompletionCandidate>, NReplError>>,
        candidates: Vec<CompletionCandidate>,
    },
    Lookup {
        reply: Sender<Result<Response, NReplError>>,
        last: Option<Response>,
    },
}

/// Handle to a background worker thread.
///
/// Request ids are minted from a per-connection atomic counter ([`id_source`]).
/// This is the single id source for the connection (evals and control ops
/// alike), so wire ids never collide and the demux loop can route responses
/// unambiguously.
pub struct Worker {
    command_tx: UnboundedSender<WorkerCommand>,
    response_rx: Receiver<EvalResponse>,
    /// Per-connection request id source (atomic so blocking `&self` ops can mint
    /// without taking the registry lock).
    id_source: Arc<AtomicUsize>,
    // Buffer for responses - allows concurrent evals without losing responses
    pending_responses: HashMap<RequestId, EvalResponse>,
}

impl Worker {
    /// Create a new worker thread (client will be connected later via Connect command)
    #[allow(clippy::new_without_default)]
    pub fn new() -> Self {
        let (command_tx, command_rx) = unbounded_channel::<WorkerCommand>();
        let (response_tx, response_rx) = channel::<EvalResponse>();
        let id_source = Arc::new(AtomicUsize::new(1));

        // Spawn worker thread - it will run until shutdown command or channel closes
        let _worker_thread = thread::spawn(move || {
            // Create a single-threaded Tokio runtime for this worker thread
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("Failed to create Tokio runtime for worker");

            rt.block_on(worker_main(command_rx, response_tx));
        });

        Self {
            command_tx,
            response_rx,
            id_source,
            pending_responses: HashMap::new(),
        }
    }

    /// Clone the command sender (so a blocking op can send + wait without
    /// holding the registry lock - see registry A3 discipline).
    pub fn command_sender(&self) -> UnboundedSender<WorkerCommand> {
        self.command_tx.clone()
    }

    /// Mint the next request id for this connection.
    pub fn next_id(&self) -> RequestId {
        RequestId::new(self.id_source.fetch_add(1, Ordering::Relaxed))
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

    /// Submit an eval request and return the request ID (non-blocking).
    pub fn submit_eval(
        &mut self,
        session: Session,
        code: String,
        timeout: Option<Duration>,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> Result<RequestId, SubmitError> {
        let request_id = self.next_id();

        let request = EvalRequest {
            request_id,
            session,
            code,
            timeout,
            file,
            line,
            column,
        };

        self.command_tx
            .send(WorkerCommand::Eval(request))
            .map_err(|_| SubmitError::WorkerDisconnected)?;

        Ok(request_id)
    }

    /// Submit a load-file request and return the request ID (non-blocking).
    pub fn submit_load_file(
        &mut self,
        session: Session,
        file_contents: String,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> Result<RequestId, SubmitError> {
        let request_id = self.next_id();

        let request = LoadFileRequest {
            request_id,
            session,
            file_contents,
            file_path,
            file_name,
        };

        self.command_tx
            .send(WorkerCommand::LoadFile(request))
            .map_err(|_| SubmitError::WorkerDisconnected)?;

        Ok(request_id)
    }

    /// Try to receive a completed eval response for a specific request (non-blocking).
    ///
    /// Buffers responses to support multiple concurrent evals without losing
    /// responses. Enforces MAX_PENDING_RESPONSES to prevent unbounded growth.
    pub fn try_recv_response(&mut self, request_id: RequestId) -> Option<EvalResponse> {
        if let Some(response) = self.pending_responses.remove(&request_id) {
            return Some(response);
        }

        while self.pending_responses.len() < MAX_PENDING_RESPONSES {
            match self.response_rx.try_recv() {
                Ok(response) => {
                    self.pending_responses.insert(response.request_id, response);
                }
                Err(_) => break,
            }
        }

        self.pending_responses.remove(&request_id)
    }

    /// Shutdown the worker thread (non-blocking).
    pub fn shutdown(&mut self) {
        let _ = self.command_tx.send(WorkerCommand::Shutdown(channel().0));
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Worker thread entry: wait for the initial Connect, then run the demux loop.
async fn worker_main(
    mut command_rx: UnboundedReceiver<WorkerCommand>,
    response_tx: Sender<EvalResponse>,
) {
    // Phase 1: wait for a Connect command before we have a stream to demux.
    loop {
        match command_rx.recv().await {
            Some(WorkerCommand::Connect(address, reply)) => {
                match NReplClient::connect(&address).await {
                    Ok(client) => {
                        let (writer, reader) = client.into_split();
                        let _ = reply.send(Ok(()));
                        // Phase 2: run the demux event loop until shutdown/disconnect.
                        event_loop(writer, reader, &mut command_rx, &response_tx).await;
                        return;
                    }
                    Err(e) => {
                        // Connection failed; let the caller retry with a new worker.
                        let _ = reply.send(Err(e));
                    }
                }
            }
            Some(WorkerCommand::Shutdown(reply)) => {
                let _ = reply.send(Ok(()));
                return;
            }
            Some(other) => {
                // Not connected yet - reply to any waiting one-shot with an error.
                reply_not_connected(other);
            }
            None => return,
        }
    }
}

/// Reply to a command's one-shot channel with a "Not connected" error.
fn reply_not_connected(cmd: WorkerCommand) {
    let err = || NReplError::protocol("Not connected");
    match cmd {
        WorkerCommand::Eval(req) => {
            // No response channel here; main thread polls try_recv_response and
            // would get nothing. This path shouldn't happen in practice because
            // connect happens before any eval, but be safe and drop it.
            let _ = req;
        }
        WorkerCommand::LoadFile(req) => {
            let _ = req;
        }
        WorkerCommand::Interrupt { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::CloneSession { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::CloseSession { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::Stdin { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::Completions { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::Lookup { reply, .. } => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::Connect(_, reply) => {
            let _ = reply.send(Err(err()));
        }
        WorkerCommand::Shutdown(reply) => {
            let _ = reply.send(Ok(()));
        }
    }
}

/// The demux event loop. Owns the writer/reader and all in-flight state.
async fn event_loop(
    mut writer: NReplWriter,
    mut reader: NReplReader,
    command_rx: &mut UnboundedReceiver<WorkerCommand>,
    response_tx: &Sender<EvalResponse>,
) {
    let mut pending: HashMap<String, Pending> = HashMap::new();
    let mut eval_queue: VecDeque<QueuedEval> = VecDeque::new();
    // Wire id of the currently running eval, if any.
    let mut active_eval: Option<String> = None;

    loop {
        // Deadline arm: only the active, non-parked eval has a live deadline.
        let deadline = active_eval
            .as_ref()
            .and_then(|id| pending.get(id))
            .and_then(|p| match p {
                Pending::Eval(s) if !s.parked => Some(s.deadline),
                _ => None,
            })
            .unwrap_or_else(|| Instant::now() + Duration::from_secs(3600));

        tokio::select! {
            cmd = command_rx.recv() => {
                match cmd {
                    Some(WorkerCommand::Shutdown(reply)) => {
                        // Best-effort: fail any pending ops, then exit.
                        fail_all_pending(&mut pending, &mut eval_queue, response_tx,
                            || NReplError::protocol("Worker shutting down"));
                        let _ = reply.send(Ok(()));
                        return;
                    }
                    Some(cmd) => {
                        dispatch_command(
                            cmd, &mut writer, &mut pending, &mut eval_queue,
                            &mut active_eval, response_tx,
                        ).await;
                    }
                    None => {
                        // All command senders dropped - shut down.
                        return;
                    }
                }
            }
            resp = reader.next_response() => {
                match resp {
                    Ok(r) => {
                        route_response(
                            r, &mut writer, &mut pending, &mut eval_queue,
                            &mut active_eval, response_tx,
                        ).await;
                    }
                    Err(e) => {
                        // Reader EOF / connection error: fail everything and stop.
                        fail_all_pending(&mut pending, &mut eval_queue, response_tx,
                            || NReplError::Connection(std::io::Error::new(
                                std::io::ErrorKind::UnexpectedEof,
                                format!("connection closed: {}", e),
                            )));
                        return;
                    }
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                // Active eval deadline expired.
                if let Some(id) = active_eval.clone() {
                    if let Some(Pending::Eval(state)) = pending.remove(&id) {
                        let _ = response_tx.send(EvalResponse {
                            request_id: state.request_id,
                            outcome: EvalOutcome::Done(Err(NReplError::Timeout {
                                operation: "eval".to_string(),
                                duration: state.timeout,
                            })),
                        });
                    }
                    active_eval = None;
                    start_next_eval(&mut writer, &mut pending, &mut eval_queue, &mut active_eval).await;
                }
            }
        }
    }
}

/// Dispatch a command: queue evals/load-files; write control ops immediately.
async fn dispatch_command(
    cmd: WorkerCommand,
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
    response_tx: &Sender<EvalResponse>,
) {
    match cmd {
        WorkerCommand::Eval(req) => {
            let timeout = req.timeout.unwrap_or(DEFAULT_EVAL_TIMEOUT);
            let request = ops::eval_request_with_location(
                req.request_id.wire(),
                req.session.id(),
                req.code,
                req.file,
                req.line,
                req.column,
            );
            enqueue_eval(
                QueuedEval {
                    request_id: req.request_id,
                    request,
                    timeout,
                },
                writer,
                pending,
                eval_queue,
                active_eval,
                response_tx,
            )
            .await;
        }
        WorkerCommand::LoadFile(req) => {
            let request = ops::load_file_request(
                req.request_id.wire(),
                req.session.id(),
                req.file_contents,
                req.file_path,
                req.file_name,
            );
            enqueue_eval(
                QueuedEval {
                    request_id: req.request_id,
                    request,
                    timeout: DEFAULT_EVAL_TIMEOUT,
                },
                writer,
                pending,
                eval_queue,
                active_eval,
                response_tx,
            )
            .await;
        }
        WorkerCommand::Interrupt {
            op_id,
            session,
            target,
            reply,
        } => {
            let target_wire = target.wire();
            // If the target eval is still queued (not yet sent), cancel it locally.
            if let Some(pos) = eval_queue.iter().position(|q| q.request_id == target) {
                let cancelled = eval_queue.remove(pos).expect("position valid");
                let _ = response_tx.send(EvalResponse {
                    request_id: cancelled.request_id,
                    outcome: EvalOutcome::Done(Ok(interrupted_result())),
                });
                let _ = reply.send(Ok(()));
                return;
            }
            // If the target isn't active/pending, the eval already finished:
            // harmless no-op.
            if !pending.contains_key(&target_wire) {
                let _ = reply.send(Ok(()));
                return;
            }
            let request = ops::interrupt_request(op_id.wire(), session.id(), target_wire);
            match writer.send(&request).await {
                Ok(()) => {
                    pending.insert(op_id.wire(), Pending::Interrupt { reply });
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        WorkerCommand::CloneSession { op_id, reply } => {
            let request = ops::clone_request(op_id.wire());
            match writer.send(&request).await {
                Ok(()) => {
                    pending.insert(
                        op_id.wire(),
                        Pending::CloneSession {
                            reply,
                            new_session: None,
                        },
                    );
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        WorkerCommand::CloseSession {
            op_id,
            session,
            reply,
        } => {
            let request = ops::close_request(op_id.wire(), session.id());
            match writer.send(&request).await {
                Ok(()) => {
                    pending.insert(op_id.wire(), Pending::CloseSession { reply });
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        WorkerCommand::Stdin {
            op_id,
            session,
            data,
            reply,
        } => {
            // Fire-and-forget: nREPL does not ack stdin.
            let request = ops::stdin_request(op_id.wire(), session.id(), data);
            let _ = reply.send(writer.send(&request).await);
        }
        WorkerCommand::Completions {
            op_id,
            session,
            prefix,
            ns,
            complete_fn,
            reply,
        } => {
            let request =
                ops::completions_request(op_id.wire(), session.id(), prefix, ns, complete_fn);
            match writer.send(&request).await {
                Ok(()) => {
                    pending.insert(
                        op_id.wire(),
                        Pending::Completions {
                            reply,
                            candidates: Vec::new(),
                        },
                    );
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        WorkerCommand::Lookup {
            op_id,
            session,
            sym,
            ns,
            lookup_fn,
            reply,
        } => {
            let request = ops::lookup_request(op_id.wire(), session.id(), sym, ns, lookup_fn);
            match writer.send(&request).await {
                Ok(()) => {
                    pending.insert(op_id.wire(), Pending::Lookup { reply, last: None });
                }
                Err(e) => {
                    let _ = reply.send(Err(e));
                }
            }
        }
        WorkerCommand::Connect(_, reply) => {
            // Already connected.
            let _ = reply.send(Err(NReplError::protocol("Already connected")));
        }
        WorkerCommand::Shutdown(reply) => {
            // Handled in the select loop; reply here defensively.
            let _ = reply.send(Ok(()));
        }
    }
}

/// Queue an eval; if nothing is running, send it now and make it active.
async fn enqueue_eval(
    queued: QueuedEval,
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
    response_tx: &Sender<EvalResponse>,
) {
    eval_queue.push_back(queued);
    if active_eval.is_none() {
        start_next_eval_inner(writer, pending, eval_queue, active_eval, response_tx).await;
    }
}

/// Pop and start the next queued eval (if any).
async fn start_next_eval(
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
) {
    // Separate fn so the deadline arm can call it without a response_tx for the
    // start failure path; route failures through pending instead.
    start_next_eval_inner_no_txfail(writer, pending, eval_queue, active_eval).await;
}

/// Start the next queued eval, reporting an immediate write failure via the
/// response channel.
async fn start_next_eval_inner(
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
    response_tx: &Sender<EvalResponse>,
) {
    while let Some(queued) = eval_queue.pop_front() {
        let wire = queued.request_id.wire();
        match writer.send(&queued.request).await {
            Ok(()) => {
                pending.insert(
                    wire.clone(),
                    Pending::Eval(EvalState {
                        request_id: queued.request_id,
                        acc: EvalAccumulator::new(),
                        timeout: queued.timeout,
                        deadline: Instant::now() + queued.timeout,
                        parked: false,
                    }),
                );
                *active_eval = Some(wire);
                return;
            }
            Err(e) => {
                // Failed to send; report and try the next queued eval.
                let _ = response_tx.send(EvalResponse {
                    request_id: queued.request_id,
                    outcome: EvalOutcome::Done(Err(e)),
                });
            }
        }
    }
}

/// Variant used when we don't have a response_tx handy (deadline path): on a
/// write failure the eval is dropped from the queue and its caller will time
/// out on the polling side.
async fn start_next_eval_inner_no_txfail(
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
) {
    while let Some(queued) = eval_queue.pop_front() {
        let wire = queued.request_id.wire();
        if writer.send(&queued.request).await.is_ok() {
            pending.insert(
                wire.clone(),
                Pending::Eval(EvalState {
                    request_id: queued.request_id,
                    acc: EvalAccumulator::new(),
                    timeout: queued.timeout,
                    deadline: Instant::now() + queued.timeout,
                    parked: false,
                }),
            );
            *active_eval = Some(wire);
            return;
        }
    }
}

/// Route one decoded response to its pending op by request id.
async fn route_response(
    response: Response,
    writer: &mut NReplWriter,
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    active_eval: &mut Option<String>,
    response_tx: &Sender<EvalResponse>,
) {
    let id = response.id.clone();
    let Some(entry) = pending.get_mut(&id) else {
        // Unknown / timed-out id - discard.
        return;
    };

    let flags = classify(&response.status);

    match entry {
        Pending::Eval(state) => {
            // Unknown-op on an eval shouldn't happen, but treat as an error.
            if flags.unknown_op {
                let request_id = state.request_id;
                pending.remove(&id);
                let _ = response_tx.send(EvalResponse {
                    request_id,
                    outcome: EvalOutcome::Done(Err(NReplError::OperationFailed(
                        "server does not support eval".to_string(),
                    ))),
                });
                if active_eval.as_deref() == Some(id.as_str()) {
                    *active_eval = None;
                    start_next_eval_inner(writer, pending, eval_queue, active_eval, response_tx)
                        .await;
                }
                return;
            }

            // A response means the server is making progress: if we were parked
            // on need-input, resume (reset the deadline).
            if state.parked {
                state.parked = false;
                state.deadline = Instant::now() + state.timeout;
            }

            let request_id = state.request_id;
            let need_input = flags.need_input;
            let done = flags.done;

            if let Err(e) = state.acc.push(response) {
                // Backpressure limit exceeded - fail the eval.
                pending.remove(&id);
                let _ = response_tx.send(EvalResponse {
                    request_id,
                    outcome: EvalOutcome::Done(Err(e)),
                });
                if active_eval.as_deref() == Some(id.as_str()) {
                    *active_eval = None;
                    start_next_eval_inner(writer, pending, eval_queue, active_eval, response_tx)
                        .await;
                }
                return;
            }

            if need_input && !done {
                // Park the eval; keep it active and do not advance the queue.
                if let Some(Pending::Eval(state)) = pending.get_mut(&id) {
                    state.parked = true;
                }
                let _ = response_tx.send(EvalResponse {
                    request_id,
                    outcome: EvalOutcome::NeedInput,
                });
                return;
            }

            if done {
                if let Some(Pending::Eval(state)) = pending.remove(&id) {
                    let _ = response_tx.send(EvalResponse {
                        request_id,
                        outcome: EvalOutcome::Done(Ok(state.acc.finish())),
                    });
                }
                if active_eval.as_deref() == Some(id.as_str()) {
                    *active_eval = None;
                    start_next_eval_inner(writer, pending, eval_queue, active_eval, response_tx)
                        .await;
                }
            }
        }
        Pending::CloneSession { new_session, .. } => {
            if let Some(s) = response.new_session.clone() {
                *new_session = Some(s);
            }
            if (flags.done || flags.error || flags.unknown_op)
                && let Some(Pending::CloneSession { reply, new_session }) = pending.remove(&id)
            {
                let result = match new_session {
                    Some(s) => Ok(Session::from_server_id(s)),
                    None => Err(NReplError::protocol(
                        "Missing new-session in clone response",
                    )),
                };
                let _ = reply.send(result);
            }
        }
        Pending::CloseSession { .. } => {
            if (flags.done || flags.error || flags.unknown_op)
                && let Some(Pending::CloseSession { reply }) = pending.remove(&id)
            {
                let _ = reply.send(op_unit_result(&response, flags, "close"));
            }
        }
        Pending::Interrupt { .. } => {
            if (flags.done || flags.error || flags.unknown_op)
                && let Some(Pending::Interrupt { reply }) = pending.remove(&id)
            {
                let _ = reply.send(op_unit_result(&response, flags, "interrupt"));
            }
        }
        Pending::Completions { candidates, .. } => {
            if let Some(c) = response.completions.clone() {
                candidates.extend(c);
            }
            if (flags.done || flags.error || flags.unknown_op)
                && let Some(Pending::Completions { reply, candidates }) = pending.remove(&id)
            {
                let result = if flags.unknown_op {
                    Err(NReplError::OperationFailed(
                        "server does not support completions".to_string(),
                    ))
                } else {
                    Ok(candidates)
                };
                let _ = reply.send(result);
            }
        }
        Pending::Lookup { last, .. } => {
            *last = Some(response.clone());
            if (flags.done || flags.error || flags.unknown_op)
                && let Some(Pending::Lookup { reply, last }) = pending.remove(&id)
            {
                let result = if flags.unknown_op {
                    Err(NReplError::OperationFailed(
                        "server does not support lookup".to_string(),
                    ))
                } else {
                    last.ok_or_else(|| NReplError::protocol("No lookup response"))
                };
                let _ = reply.send(result);
            }
        }
    }
}

/// Build the unit result for a control op that completed, honouring `err`,
/// `unknown-op` and `error` status (conformance #3).
fn op_unit_result(
    response: &Response,
    flags: nrepl_rs::StatusFlags,
    op: &str,
) -> Result<(), NReplError> {
    if flags.unknown_op {
        return Err(NReplError::OperationFailed(format!(
            "server does not support {}",
            op
        )));
    }
    if let Some(err) = &response.err {
        return Err(NReplError::OperationFailed(format!(
            "{} failed: {}",
            op, err
        )));
    }
    if flags.error {
        return Err(NReplError::OperationFailed(format!("{} failed", op)));
    }
    Ok(())
}

/// Result delivered when a queued eval is cancelled by an interrupt.
fn interrupted_result() -> EvalResult {
    let mut r = EvalResult::new();
    r.interrupted = true;
    r
}

/// Fail every pending op and queued eval with the given error (connection lost
/// / shutdown).
fn fail_all_pending(
    pending: &mut HashMap<String, Pending>,
    eval_queue: &mut VecDeque<QueuedEval>,
    response_tx: &Sender<EvalResponse>,
    make_err: impl Fn() -> NReplError,
) {
    for (_id, p) in pending.drain() {
        match p {
            Pending::Eval(state) => {
                let _ = response_tx.send(EvalResponse {
                    request_id: state.request_id,
                    outcome: EvalOutcome::Done(Err(make_err())),
                });
            }
            Pending::CloneSession { reply, .. } => {
                let _ = reply.send(Err(make_err()));
            }
            Pending::CloseSession { reply } => {
                let _ = reply.send(Err(make_err()));
            }
            Pending::Interrupt { reply } => {
                let _ = reply.send(Err(make_err()));
            }
            Pending::Completions { reply, .. } => {
                let _ = reply.send(Err(make_err()));
            }
            Pending::Lookup { reply, .. } => {
                let _ = reply.send(Err(make_err()));
            }
        }
    }
    for queued in eval_queue.drain(..) {
        let _ = response_tx.send(EvalResponse {
            request_id: queued.request_id,
            outcome: EvalOutcome::Done(Err(make_err())),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_worker_construction() {
        let worker = Worker::new();
        assert_eq!(
            worker.pending_responses.len(),
            0,
            "Should have no pending responses initially"
        );
        // id source starts at 1
        assert_eq!(worker.next_id().as_usize(), 1);
    }

    #[test]
    fn test_request_id_minting_is_sequential() {
        let worker = Worker::new();
        assert_eq!(worker.next_id().as_usize(), 1);
        assert_eq!(worker.next_id().as_usize(), 2);
        assert_eq!(worker.next_id().as_usize(), 3);
    }

    #[test]
    fn test_request_id_wire_format() {
        assert_eq!(RequestId::new(7).wire(), "req-7");
    }

    #[test]
    fn test_max_pending_responses_constant() {
        assert_eq!(
            MAX_PENDING_RESPONSES, 1000,
            "MAX_PENDING_RESPONSES should be 1000"
        );
    }
}
