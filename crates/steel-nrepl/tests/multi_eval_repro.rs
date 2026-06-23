// Repro for the "eval times out after a few sequential evals against nrepl-steel"
// bug. Drives the real registry/Worker/demux exactly like the Steel FFI does:
// connect -> clone -> describe -> then for each form submit_eval (with file/line/
// column location metadata) and poll try_recv_response until done, firing the next
// eval immediately on completion (as nrepl-eval-multiple-selections does).
//
// Requires a running nrepl-steel server. Set NREPL_STEEL_ADDR (default 127.0.0.1:7899).
// Ignored by default so the normal suite doesn't need a server.
//
//   cargo test -p steel-nrepl --test multi_eval_repro -- --ignored --nocapture

use std::time::{Duration, Instant};
use steel_nrepl::registry;
use steel_nrepl::worker::{EvalOutcome, RequestId};

fn addr() -> String {
    std::env::var("NREPL_STEEL_ADDR").unwrap_or_else(|_| "127.0.0.1:7899".to_string())
}

/// Mimic the Steel poll loop: poll `try_recv_response` every 10ms until the worker
/// delivers an outcome, with a wall-clock guard so a wedge fails the test fast
/// instead of waiting out the full 60s eval deadline.
fn poll_outcome(conn: registry::ConnectionId, req: RequestId, guard: Duration) -> EvalOutcome {
    let start = Instant::now();
    loop {
        if let Some(resp) = registry::try_recv_response(conn, req) {
            return resp.outcome;
        }
        assert!(
            start.elapsed() <= guard,
            "WEDGED: no response for {req:?} within {guard:?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Simulate jack-in's `try-connect-to-port` readiness probe: open a TCP
/// connection to the server and immediately close it (like `nc -z`), with no
/// data. Done right before the real connect, with zero gap, to mirror jack-in.
fn probe(addr: &str) {
    use std::net::TcpStream;
    if let Ok(s) = TcpStream::connect(addr) {
        drop(s);
    }
}

#[test]
#[ignore = "requires a running nrepl-steel server (set NREPL_STEEL_ADDR)"]
fn multi_selection_sequence_against_nrepl_steel() {
    // jack-in probes readiness with `nc -z` immediately before connecting.
    let do_probe = std::env::var("REPRO_PROBE").is_ok();
    if do_probe {
        probe(&addr());
        probe(&addr());
        eprintln!("(probed twice immediately before connect, like jack-in)");
    }
    let conn = registry::create_and_connect(addr()).expect("connect");
    let session = registry::clone_session_blocking(conn).expect("clone");
    let _ = registry::describe_blocking(conn, false); // as nrepl:connect does

    let forms = [
        ("(+ 1 2)", 1u32),
        ("(println (+ 1 2))", 2),
        ("(println \"hello world\")", 3),
        ("\"hello world\"", 4),
        ("(/ 1 0)", 5),
        ("(define (testfn x) (* x 4))", 6),
        ("(testfn 2)", 7),
    ];

    for (code, line) in forms {
        let req = registry::submit_eval(
            conn,
            session.clone(),
            code.to_string(),
            Some(Duration::from_mins(1)),
            Some("/Users/waddie/scratch/steel.md".to_string()),
            Some(i64::from(line)),
            Some(1),
        )
        .expect("connection present")
        .expect("submit");

        // 8s guard: the server answers in ms; anything longer is the wedge.
        match poll_outcome(conn, req, Duration::from_secs(8)) {
            EvalOutcome::Done(Ok(r)) => {
                eprintln!(
                    "  {:32} value={:?} out={:?} err={:?} ex={:?}",
                    code, r.value, r.output, r.error, r.ex
                );
            }
            EvalOutcome::Done(Err(e)) => {
                eprintln!("  {code:32} ERR {e}");
            }
            EvalOutcome::NeedInput { .. } => {
                eprintln!("  {code:32} need-input (unexpected)");
            }
        }
    }

    eprintln!("ALL EVALS COMPLETED - no wedge");
}
