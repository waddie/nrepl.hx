// Copyright (C) 2026 Tom Waddington
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

//! Tests against `proof serve`, which imitates other servers' quirks one
//! scenario at a time (<https://github.com/nrepl/proof>).
//!
//! Every test here must pass under every scenario: the client has to show the
//! same output and values however the replies are split, batched or padded,
//! and must not hang when a server lacks an op. `tests/proof-serve.sh` runs
//! them once per scenario. To run them by hand:
//!
//! ```sh
//! proof serve -listen 127.0.0.1:7888 split-output
//! cargo test -p nrepl-rs --test proof_serve -- --ignored --skip hang_up
//! ```
//!
//! `hang_up` is for the `hang-up` scenario only, where every other test fails.

mod common;

use nrepl_rs::worker::{EvalOutcome, RequestId, Worker, WorkerCommand};
use nrepl_rs::{EvalResult, NReplError, Session};
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

const REPLY_TIMEOUT: Duration = Duration::from_secs(10);

/// Whether the server's `describe` lists `op`.
fn supports(worker: &Worker, op: &str) -> bool {
    common::describe(worker, false)
        .expect("describe failed")
        .ops
        .is_some_and(|ops| ops.contains_key(op))
}

/// Poll `request_id` until it finishes or asks for input.
fn wait_outcome(worker: &mut Worker, request_id: RequestId) -> EvalOutcome {
    let deadline = Instant::now() + REPLY_TIMEOUT;
    loop {
        if let Some(response) = worker.try_recv_response(request_id) {
            return response.outcome;
        }
        assert!(Instant::now() < deadline, "eval never finished");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn wait_done(worker: &mut Worker, request_id: RequestId) -> Result<EvalResult, NReplError> {
    match wait_outcome(worker, request_id) {
        EvalOutcome::Done(result) => result,
        EvalOutcome::NeedInput { .. } => panic!("unexpected need-input"),
    }
}

fn submit(worker: &mut Worker, session: &Session, code: &str) -> RequestId {
    worker
        .submit_eval(session.clone(), code.to_string(), None, None, None, None)
        .expect("submit_eval failed")
}

fn eval(worker: &mut Worker, session: &Session, code: &str) -> EvalResult {
    let request_id = submit(worker, session, code);
    wait_done(worker, request_id).expect("eval failed")
}

/// Connect, run `test` in a fresh session, and close the session afterwards so
/// proof doesn't report it as left behind.
fn with_session(test: impl FnOnce(&mut Worker, &Session)) {
    let (mut worker, session) = common::connect();
    test(&mut worker, &session);
    common::close_session(&worker, session).expect("close failed");
}

#[test]
#[ignore = "requires proof serve"]
fn value() {
    with_session(|worker, session| {
        let result = eval(worker, session, "(+ 1 2)");
        assert_eq!(result.value.as_deref(), Some("3"));
        assert!(result.ex.is_none());
    });
}

#[test]
#[ignore = "requires proof serve"]
fn output_arrives_whole() {
    with_session(|worker, session| {
        let result = eval(worker, session, r#"(println "hi") (print "there")"#);
        assert_eq!(result.output.concat(), "hi\nthere");
    });
}

#[test]
#[ignore = "requires proof serve"]
fn error_output_is_whole_or_absent() {
    // Some servers drop stderr entirely; the rest must deliver all of it.
    with_session(|worker, session| {
        let result = eval(worker, session, r#"(binding [*out* *err*] (println "e"))"#);
        let err = result.error.concat();
        assert!(err == "e\n" || err.is_empty(), "error output was {err:?}");
    });
}

#[test]
#[ignore = "requires proof serve"]
fn last_value_wins() {
    // Some servers only send the last value; either way it's the one shown.
    with_session(|worker, session| {
        let result = eval(worker, session, r#"(println "a") 1 (+ 1 1)"#);
        assert_eq!(result.output.concat(), "a\n");
        assert_eq!(result.value.as_deref(), Some("2"));
    });
}

#[test]
#[ignore = "requires proof serve"]
fn throw_surfaces_ex() {
    with_session(|worker, session| {
        let result = eval(worker, session, r#"(throw (ex-info "boom" {}))"#);
        assert!(result.ex.is_some(), "no ex in {result:?}");
        assert!(result.value.is_none());
    });
}

#[test]
#[ignore = "requires proof serve"]
fn long_value_arrives_whole() {
    with_session(|worker, session| {
        let result = eval(worker, session, r#"(apply str (repeat 10000 "x"))"#);
        let value = result.value.expect("no value");
        assert_eq!(value.len(), 10002, "a quoted string of 10000 x's");
    });
}

#[test]
#[ignore = "requires proof serve"]
fn definitions_persist() {
    with_session(|worker, session| {
        eval(worker, session, "(def x 99)");
        assert_eq!(eval(worker, session, "x").value.as_deref(), Some("99"));
    });
}

#[test]
#[ignore = "requires proof serve"]
fn interrupt() {
    with_session(|worker, session| {
        if !supports(worker, "interrupt") {
            return;
        }
        let request_id = submit(worker, session, "(Thread/sleep 10000)");
        std::thread::sleep(Duration::from_millis(200));
        let (reply_tx, reply_rx) = channel();
        worker
            .command_sender()
            .send(WorkerCommand::Interrupt {
                op_id: worker.next_id(),
                session: session.clone(),
                target: request_id,
                reply: reply_tx,
            })
            .expect("worker thread gone");
        reply_rx
            .recv_timeout(REPLY_TIMEOUT)
            .expect("interrupt reply timed out")
            .expect("interrupt failed");
        let result = wait_done(worker, request_id).expect("eval failed");
        assert!(result.interrupted, "eval wasn't interrupted: {result:?}");
    });
}

#[test]
#[ignore = "requires proof serve"]
fn stdin() {
    with_session(|worker, session| {
        if !supports(worker, "stdin") {
            // Reading input returns or throws right away instead.
            eval(worker, session, "(read-line)");
            return;
        }
        let request_id = submit(worker, session, r#"(str "got " (read-line))"#);
        assert!(
            matches!(
                wait_outcome(worker, request_id),
                EvalOutcome::NeedInput { .. }
            ),
            "no need-input"
        );
        let (reply_tx, reply_rx) = channel();
        worker
            .command_sender()
            .send(WorkerCommand::Stdin {
                op_id: worker.next_id(),
                session: session.clone(),
                data: "hi\n".to_string(),
                reply: reply_tx,
            })
            .expect("worker thread gone");
        reply_rx
            .recv_timeout(REPLY_TIMEOUT)
            .expect("stdin reply timed out")
            .expect("stdin failed");
        let result = wait_done(worker, request_id).expect("eval failed");
        assert_eq!(result.value.as_deref(), Some(r#""got hi""#));
    });
}

#[test]
#[ignore = "requires proof serve hang-up"]
fn hang_up() {
    // The server drops the connection instead of answering the eval.
    let (mut worker, session) = common::connect();
    let request_id = submit(&mut worker, &session, "(+ 1 2)");
    assert!(
        wait_done(&mut worker, request_id).is_err(),
        "an eval the server hung up on should fail"
    );
}
