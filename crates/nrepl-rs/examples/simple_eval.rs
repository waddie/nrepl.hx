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

//! Simple example demonstrating nREPL client usage
//!
//! The client is `Worker`: it owns a background thread with its own runtime, so
//! this example is plain synchronous code. Evals are submitted and then polled,
//! which is what lets a control op (interrupt, stdin) be sent while an eval is
//! still running.
//!
//! Start an nREPL server first:
//! ```sh
//! clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.4.0"}}}' -M -m nrepl.cmdline --port 7888
//! ```
//!
//! Then run this example:
//! ```sh
//! cargo run -p nrepl-rs --example simple_eval
//! ```

use nrepl_rs::worker::{EvalOutcome, Worker, WorkerCommand};
use nrepl_rs::{EvalResult, Result, Session};
use std::sync::mpsc::channel;
use std::time::Duration;

/// Submit `code` and block until the worker delivers its result.
fn eval(worker: &mut Worker, session: &Session, code: &str) -> Result<EvalResult> {
    let request_id = worker
        .submit_eval(
            session.clone(),
            code.to_string(),
            Some(Duration::from_secs(30)),
            None,
            None,
            None,
        )
        .expect("worker thread gone");

    loop {
        if let Some(response) = worker.try_recv_response(request_id) {
            match response.outcome {
                EvalOutcome::Done(result) => return result,
                EvalOutcome::NeedInput { .. } => {
                    panic!("this example evaluates nothing that reads stdin")
                }
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn main() -> Result<()> {
    println!("Connecting to nREPL server at localhost:7888...");
    let mut worker = Worker::new();
    worker.connect_blocking("localhost:7888".to_string())?;
    println!("Connected");

    println!("\nCloning session...");
    let (reply_tx, reply_rx) = channel();
    worker
        .command_sender()
        .send(WorkerCommand::CloneSession {
            op_id: worker.next_id(),
            reply: reply_tx,
        })
        .expect("worker thread gone");
    let session = reply_rx
        .recv_timeout(Duration::from_secs(30))
        .expect("clone-session timed out")?;
    println!("Session created: {}", session.id());

    println!("\nEvaluating: (+ 1 2)");
    let result = eval(&mut worker, &session, "(+ 1 2)")?;
    println!("Result: {:?}", result.value);

    println!("\nEvaluating: (- 0 1)");
    let result = eval(&mut worker, &session, "(- 0 1)")?;
    println!("Result: {:?}", result.value);

    println!("\nEvaluating with output: (do (println \"Hello from nREPL!\") (+ 10 20))");
    let result = eval(
        &mut worker,
        &session,
        r#"(do (println "Hello from nREPL!") (+ 10 20))"#,
    )?;
    println!("Output: {:?}", result.output);
    println!("Result: {:?}", result.value);

    println!("\nDefining a variable: (def my-number 42)");
    let result = eval(&mut worker, &session, "(def my-number 42)")?;
    println!("Result: {:?}", result.value);

    println!("\nUsing the defined variable: (* my-number 2)");
    let result = eval(&mut worker, &session, "(* my-number 2)")?;
    println!("Result: {:?}", result.value);

    println!("\nAll examples completed successfully");

    worker.shutdown();
    Ok(())
}
