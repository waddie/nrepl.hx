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

//! Blocking test helpers over the demux [`Worker`].
//!
//! The worker owns its own runtime and delivers eval results by submit/poll, so
//! these tests are plain `#[test]` functions. Each helper mirrors one
//! [`WorkerCommand`]: send it with a one-shot reply channel, then block on the
//! reply.

#![allow(dead_code)] // each test file uses a different subset of the helpers

use nrepl_rs::worker::{EvalOutcome, Worker, WorkerCommand};
use nrepl_rs::{CompletionCandidate, EvalResult, NReplError, Response, Session};
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

/// How long a control op may take before the helper gives up.
const OP_TIMEOUT: Duration = Duration::from_secs(30);

/// How long to keep polling for an eval result.
const POLL_BUDGET: Duration = Duration::from_mins(1);

/// The address of the nREPL server to test against.
///
/// Defaults to localhost:7888; set `NREPL_TEST_ADDR` to point elsewhere (e.g.
/// a babashka server on another port).
pub fn test_server_addr() -> String {
    std::env::var("NREPL_TEST_ADDR").unwrap_or_else(|_| "localhost:7888".to_string())
}

/// Connect a worker to the test server. No session is cloned.
pub fn connect_worker() -> Worker {
    let worker = Worker::new();
    worker
        .connect_blocking(test_server_addr())
        .expect("Failed to connect");
    worker
}

/// Connect a worker and clone one session on it.
pub fn connect() -> (Worker, Session) {
    let worker = connect_worker();
    let session = clone_session(&worker).expect("Failed to clone session");
    (worker, session)
}

/// Send `command` (built around a fresh reply channel) and block for its reply.
fn send_and_wait<T>(
    worker: &Worker,
    operation: &str,
    build: impl FnOnce(
        nrepl_rs::worker::RequestId,
        std::sync::mpsc::Sender<Result<T, NReplError>>,
    ) -> WorkerCommand,
) -> Result<T, NReplError> {
    let (reply_tx, reply_rx) = channel();
    worker
        .command_sender()
        .send(build(worker.next_id(), reply_tx))
        .expect("worker thread gone");
    reply_rx
        .recv_timeout(OP_TIMEOUT)
        .unwrap_or_else(|_| panic!("{operation} timed out after {OP_TIMEOUT:?}"))
}

pub fn clone_session(worker: &Worker) -> Result<Session, NReplError> {
    send_and_wait(worker, "clone-session", |op_id, reply| {
        WorkerCommand::CloneSession { op_id, reply }
    })
}

pub fn close_session(worker: &Worker, session: Session) -> Result<(), NReplError> {
    send_and_wait(worker, "close-session", |op_id, reply| {
        WorkerCommand::CloseSession {
            op_id,
            session,
            reply,
        }
    })
}

pub fn describe(worker: &Worker, verbose: bool) -> Result<Response, NReplError> {
    send_and_wait(worker, "describe", |op_id, reply| WorkerCommand::Describe {
        op_id,
        verbose,
        reply,
    })
}

pub fn ls_sessions(worker: &Worker) -> Result<Vec<String>, NReplError> {
    send_and_wait(worker, "ls-sessions", |op_id, reply| {
        WorkerCommand::LsSessions { op_id, reply }
    })
}

pub fn completions(
    worker: &Worker,
    session: &Session,
    prefix: &str,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> Result<Vec<CompletionCandidate>, NReplError> {
    send_and_wait(worker, "completions", |op_id, reply| {
        WorkerCommand::Completions {
            op_id,
            session: session.clone(),
            prefix: prefix.to_string(),
            ns,
            complete_fn,
            reply,
        }
    })
}

pub fn lookup(
    worker: &Worker,
    session: &Session,
    sym: &str,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> Result<Response, NReplError> {
    send_and_wait(worker, "lookup", |op_id, reply| WorkerCommand::Lookup {
        op_id,
        session: session.clone(),
        sym: sym.to_string(),
        ns,
        lookup_fn,
        reply,
    })
}

/// Poll `request_id` until it completes, then return its result.
///
/// Panics on `need-input` (no test here drives an interactive eval) or if the
/// poll budget runs out.
fn poll_result(
    worker: &mut Worker,
    request_id: nrepl_rs::worker::RequestId,
) -> Result<EvalResult, NReplError> {
    let deadline = Instant::now() + POLL_BUDGET;
    loop {
        if let Some(response) = worker.try_recv_response(request_id) {
            match response.outcome {
                EvalOutcome::Done(result) => return result,
                EvalOutcome::NeedInput { .. } => {
                    panic!("unexpected need-input while polling {request_id:?}")
                }
            }
        }
        assert!(
            Instant::now() < deadline,
            "eval did not complete within {POLL_BUDGET:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Evaluate `code` with the worker's default (60s) eval timeout.
pub fn eval(
    worker: &mut Worker,
    session: &Session,
    code: impl Into<String>,
) -> Result<EvalResult, NReplError> {
    eval_inner(worker, session, code.into(), None)
}

/// Evaluate `code` with an explicit eval timeout.
pub fn eval_with_timeout(
    worker: &mut Worker,
    session: &Session,
    code: impl Into<String>,
    timeout: Duration,
) -> Result<EvalResult, NReplError> {
    eval_inner(worker, session, code.into(), Some(timeout))
}

fn eval_inner(
    worker: &mut Worker,
    session: &Session,
    code: String,
    timeout: Option<Duration>,
) -> Result<EvalResult, NReplError> {
    let request_id = worker
        .submit_eval(session.clone(), code, timeout, None, None, None)
        .expect("submit_eval failed");
    poll_result(worker, request_id)
}

/// Load `contents` into the session, with optional path and name context.
pub fn load_file(
    worker: &mut Worker,
    session: &Session,
    contents: impl Into<String>,
    path: Option<String>,
    name: Option<String>,
) -> Result<EvalResult, NReplError> {
    let request_id = worker
        .submit_load_file(session.clone(), contents.into(), path, name)
        .expect("submit_load_file failed");
    poll_result(worker, request_id)
}
