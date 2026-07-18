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

//! Connection management for Steel FFI

use crate::error::{SteelNReplResult, nrepl_error_to_steel, steel_error};
use crate::registry::{self, ConnectionId, SessionId};
use nrepl_rs::worker::{EvalOutcome, RequestId};
use nrepl_rs::{CompletionCandidate, EvalResult, Session};
use std::borrow::Cow;
use std::time::Duration;
use steel::SteelErr;
use steel::rvals::Custom;

/// Maximum code size in bytes to prevent `DoS` attacks
///
/// This limit prevents malicious or accidental submission of extremely large
/// code strings that could exhaust memory or cause processing delays.
///
/// 10MB is generous for legitimate code while preventing abuse:
/// - Most source files are well under 1MB
/// - 10MB is ~200,000 lines of typical code
/// - Large enough for reasonable use cases
/// - Small enough to prevent memory exhaustion
const MAX_CODE_SIZE: usize = 10 * 1024 * 1024; // 10MB

/// Escape a string for Steel/Scheme syntax
/// Handles: ", \, newlines, tabs, and other common escapes
///
/// Uses Cow<str> to avoid allocations when no escaping is needed.
/// Returns a borrowed reference if the string contains no special characters,
/// otherwise returns an owned escaped string.
fn escape_steel_string(s: &str) -> Cow<'_, str> {
    // Check if escaping is needed
    let needs_escape = s
        .chars()
        .any(|c| matches!(c, '"' | '\\' | '\n' | '\r' | '\t'));

    if needs_escape {
        // Escaping needed - build escaped string
        let escaped: String = s
            .chars()
            .flat_map(|c| match c {
                '"' => vec!['\\', '"'],
                '\\' => vec!['\\', '\\'],
                '\n' => vec!['\\', 'n'],
                '\r' => vec!['\\', 'r'],
                '\t' => vec!['\\', 't'],
                c => vec![c],
            })
            .collect();
        Cow::Owned(escaped)
    } else {
        // No escaping needed - return borrowed reference (zero allocation)
        Cow::Borrowed(s)
    }
}

/// Render a list of output strings as a Steel `(list "..." ...)` expression,
/// escaping each string. Shared by the `Done` and `need-input` paths so both
/// produce identically-escaped lists the Scheme reader can parse.
fn output_list_to_steel(output: &[String]) -> String {
    let items: Vec<String> = output
        .iter()
        .map(|s| format!("\"{}\"", escape_steel_string(s)))
        .collect();
    format!("(list {})", items.join(" "))
}

/// Convert an `EvalResult` to a Steel-readable hashmap string
/// Returns a hash construction call: (hash 'value "..." 'output [...] 'error "..." 'ns "...")
/// Uses #f for false/null values (Steel is R5RS Scheme, no nil)
fn eval_result_to_steel_hashmap(result: &EvalResult) -> String {
    let mut parts = Vec::new();

    // Add 'value
    let value_str = match &result.value {
        Some(v) => format!("\"{}\"", escape_steel_string(v)),
        None => "#f".to_string(),
    };
    parts.push(format!("'value {value_str}"));

    // Add 'output as a list of strings
    parts.push(format!("'output {}", output_list_to_steel(&result.output)));

    // Add 'error - join multiple errors with newlines, or #f if none
    let error_str = if result.error.is_empty() {
        "#f".to_string()
    } else {
        format!("\"{}\"", escape_steel_string(&result.error.join("\n")))
    };
    parts.push(format!("'error {error_str}"));

    // Add 'ns
    let ns_str = match &result.ns {
        Some(n) => format!("\"{}\"", escape_steel_string(n)),
        None => "#f".to_string(),
    };
    parts.push(format!("'ns {ns_str}"));

    // Add 'ex - the explicit exception from `ex`/`root-ex` (conformance #1).
    // Distinct from 'error (stderr text): set only on a genuine eval error, so
    // adapters can key off it instead of string-matching stderr.
    let ex_str = match &result.ex {
        Some(e) => format!("\"{}\"", escape_steel_string(e)),
        None => "#f".to_string(),
    };
    parts.push(format!("'ex {ex_str}"));

    // Add 'interrupted - #t if the eval was interrupted (conformance #4).
    parts.push(format!(
        "'interrupted {}",
        if result.interrupted { "#t" } else { "#f" }
    ));

    format!("(hash {})", parts.join(" "))
}

/// Format completion candidates as a Steel list of hashmaps:
/// `(list (hash '#:candidate "map" '#:ns "clojure.core" '#:type "function") ...)`
/// Missing fields are `#f`. Shared by the blocking and submit/poll paths so
/// both emit the same FFI grammar.
fn format_completions(completions: &[CompletionCandidate]) -> String {
    let completion_items: Vec<String> = completions
        .iter()
        .map(|c| {
            let mut parts = Vec::new();

            // Always include candidate
            parts.push(format!(
                "'#:candidate \"{}\"",
                escape_steel_string(&c.candidate)
            ));

            // Include namespace if present
            if let Some(ns) = &c.ns {
                parts.push(format!("'#:ns \"{}\"", escape_steel_string(ns)));
            } else {
                parts.push("'#:ns #f".to_string());
            }

            // Include type if present
            if let Some(ctype) = &c.candidate_type {
                parts.push(format!("'#:type \"{}\"", escape_steel_string(ctype)));
            } else {
                parts.push("'#:type #f".to_string());
            }

            format!("(hash {})", parts.join(" "))
        })
        .collect();

    format!("(list {})", completion_items.join(" "))
}

/// A lookup info key is emitted as a Steel keyword (`'#:key`), so it must be
/// a single reader token. Restrict to characters that cannot terminate or
/// corrupt the token; entries with other keys are skipped (the Scheme side
/// could never parse them).
fn is_steel_keyword_safe(key: &str) -> bool {
    !key.is_empty()
        && key.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(
                    c,
                    '-' | '_' | '+' | '*' | '/' | '.' | '<' | '>' | '=' | '!' | '?'
                )
        })
}

/// Format a lookup response's info map as a Steel hash of keyword keys:
/// `(hash '#:doc "..." '#:ns "..." ...)`, or `(hash )` when the server sent
/// no info. Shared by the blocking and submit/poll paths.
fn format_lookup_info(info: Option<&std::collections::BTreeMap<String, String>>) -> String {
    let mut parts = Vec::new();

    if let Some(info) = info {
        for (key, value) in info {
            if !is_steel_keyword_safe(key) {
                continue;
            }
            let value_escaped = escape_steel_string(value);
            parts.push(format!("'#:{key} \"{value_escaped}\""));
        }
    }

    format!("(hash {})", parts.join(" "))
}

/// A handle to an nREPL session that can be used from Steel
#[derive(Clone)]
pub struct NReplSession {
    pub conn_id: ConnectionId,
    pub session_id: SessionId,
}

impl Custom for NReplSession {}

/// Reject an empty or oversized eval/load-file payload. `kind` names the
/// payload in the size error ("Code" or "File"); `empty_msg` is the full
/// message for the empty case.
fn check_payload(payload: &str, empty_msg: &str, kind: &str) -> SteelNReplResult<()> {
    if payload.trim().is_empty() {
        return Err(steel_error(empty_msg.to_string()));
    }
    // Check payload size to prevent DoS attacks
    if payload.len() > MAX_CODE_SIZE {
        return Err(steel_error(format!(
            "{kind} size ({} bytes) exceeds maximum allowed size ({} bytes)",
            payload.len(),
            MAX_CODE_SIZE
        )));
    }
    Ok(())
}

/// The error for a session handle the registry no longer holds.
///
/// The wording reaches the Scheme side and the `*nrepl*` buffer, so it names
/// the recovery action rather than just the failure.
fn session_not_found(conn_id: ConnectionId, session_id: SessionId) -> SteelErr {
    steel_error(format!(
        "Session {} not found in connection {}. Clone a new session with nrepl-clone-session.",
        session_id.as_usize(),
        conn_id.as_usize()
    ))
}

/// The error for a connection id the registry no longer holds.
fn connection_not_found(conn_id: ConnectionId) -> SteelErr {
    steel_error(format!(
        "Connection {} not found. Create a connection with nrepl-connect first.",
        conn_id.as_usize()
    ))
}

impl NReplSession {
    /// Resolve this handle's session from the registry.
    fn session(&self) -> SteelNReplResult<Session> {
        registry::get_session(self.conn_id, self.session_id)
            .ok_or_else(|| session_not_found(self.conn_id, self.session_id))
    }

    /// Shared submission path for `eval` and `eval_with_timeout`.
    fn submit_eval(
        &self,
        code: &str,
        timeout: Option<Duration>,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> SteelNReplResult<usize> {
        check_payload(
            code,
            "Cannot evaluate empty code. Provide non-empty code to evaluate.",
            "Code",
        )?;
        let session = self.session()?;

        // Submit eval to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_eval(
            self.conn_id,
            session,
            code.to_string(),
            timeout,
            file,
            line,
            column,
        )
        .ok_or_else(|| connection_not_found(self.conn_id))?
        .map_err(|e| steel_error(e.to_string()))?;

        Ok(request_id.as_usize())
    }

    /// Submit an eval request with custom timeout (non-blocking, returns request ID immediately)
    ///
    /// Usage: (define req-id (nrepl-eval-with-timeout session "(+ 1 2)" 5000 file-path line-num col-num))
    /// File location parameters are optional (pass #f for any or all of them).
    pub fn eval_with_timeout(
        &mut self,
        code: &str,
        timeout_ms: usize,
        file: Option<String>,
        line: Option<i64>,
        column: Option<i64>,
    ) -> SteelNReplResult<usize> {
        self.submit_eval(
            code,
            Some(Duration::from_millis(timeout_ms as u64)),
            file,
            line,
            column,
        )
    }

    /// Submit a load-file request (non-blocking, returns request ID immediately)
    ///
    /// Loads file contents with optional file path and name for better error messages.
    /// This is similar to eval but provides context for error reporting.
    ///
    /// Usage: (define req-id (nrepl-load-file session file-contents "/path/to/file.clj" "file.clj"))
    /// Or with no path info: (define req-id (nrepl-load-file session file-contents #f #f))
    pub fn load_file(
        &mut self,
        file_contents: &str,
        file_path: Option<String>,
        file_name: Option<String>,
    ) -> SteelNReplResult<usize> {
        check_payload(
            file_contents,
            "Cannot load empty file contents. Provide non-empty file contents to load.",
            "File",
        )?;
        let session = self.session()?;

        // Submit load-file to worker thread (non-blocking, returns immediately)
        let request_id = registry::submit_load_file(
            self.conn_id,
            session,
            file_contents.to_string(),
            file_path,
            file_name,
        )
        .ok_or_else(|| connection_not_found(self.conn_id))?
        .map_err(|e| steel_error(e.to_string()))?;

        Ok(request_id.as_usize())
    }

    /// Submit a completions request (non-blocking, returns request ID
    /// immediately). Poll with `try-get-completions`. Single-flight per
    /// connection: submitting again supersedes any pending completions
    /// request, whose poller then errors and stops.
    ///
    /// Usage: (define req-id (session.submit-completions "ma" #f #f))
    pub fn submit_completions(
        &self,
        prefix: &str,
        ns: Option<String>,
        complete_fn: Option<String>,
    ) -> SteelNReplResult<usize> {
        let session = self.session()?;
        let request_id = registry::submit_completions(
            self.conn_id,
            session,
            prefix.to_string(),
            ns,
            complete_fn,
        )
        .map_err(nrepl_error_to_steel)?;
        Ok(request_id.as_usize())
    }

    /// Try to get a submitted completions result (non-blocking).
    ///
    /// Returns #f while pending; the formatted candidate list (same shape as
    /// `completions`) when ready. Errors once the request was superseded or
    /// the connection closed, so poll loops terminate.
    ///
    /// Usage: (session.try-get-completions req-id)
    pub fn try_get_completions(&self, request_id: usize) -> SteelNReplResult<Option<String>> {
        let candidates = registry::try_get_completions(self.conn_id, RequestId::new(request_id))
            .map_err(nrepl_error_to_steel)?;
        Ok(candidates.map(|c| format_completions(&c)))
    }

    /// Submit a lookup request (non-blocking, returns request ID
    /// immediately). Poll with `try-get-lookup`. Single-flight per
    /// connection, like `submit-completions`.
    ///
    /// Usage: (define req-id (session.submit-lookup "map" #f #f))
    pub fn submit_lookup(
        &self,
        sym: &str,
        ns: Option<String>,
        lookup_fn: Option<String>,
    ) -> SteelNReplResult<usize> {
        let session = self.session()?;
        let request_id =
            registry::submit_lookup(self.conn_id, session, sym.to_string(), ns, lookup_fn)
                .map_err(nrepl_error_to_steel)?;
        Ok(request_id.as_usize())
    }

    /// Try to get a submitted lookup result (non-blocking).
    ///
    /// Returns #f while pending; the formatted info hash (same shape as
    /// `lookup`) when ready. Errors once the request was superseded or the
    /// connection closed.
    ///
    /// Usage: (session.try-get-lookup req-id)
    pub fn try_get_lookup(&self, request_id: usize) -> SteelNReplResult<Option<String>> {
        let response = registry::try_get_lookup(self.conn_id, RequestId::new(request_id))
            .map_err(nrepl_error_to_steel)?;
        Ok(response.map(|r| format_lookup_info(r.info.as_ref())))
    }

    /// Interrupt the in-flight eval with the given steel request id.
    ///
    /// Method form taking the session handle (the shape Steel uses, like
    /// `eval`/`completions`/`lookup`). Delegates to [`nrepl_interrupt`].
    ///
    /// Usage: (session.interrupt request-id)
    pub fn interrupt(&self, request_id: usize) -> SteelNReplResult<()> {
        nrepl_interrupt(
            self.conn_id.as_usize(),
            self.session_id.as_usize(),
            request_id,
        )
    }

    /// Send stdin input to this session (to unblock a `(read-line)` etc.).
    ///
    /// Method form taking the session handle. Delegates to [`nrepl_stdin`].
    ///
    /// Usage: (session.stdin "some input\n")
    pub fn stdin(&self, data: &str) -> SteelNReplResult<()> {
        nrepl_stdin(self.conn_id.as_usize(), self.session_id.as_usize(), data)
    }

    /// Return this session's on-the-wire session id (the UUID string the
    /// server minted in the clone response). This is the id `ls-sessions`
    /// reports, so the client can match its own session in that list.
    ///
    /// Usage: (session-id session)
    pub fn wire_session_id(&self) -> SteelNReplResult<String> {
        Ok(self.session()?.id().to_string())
    }
}

// Note: We no longer need a shared runtime here because each worker thread
// has its own Tokio runtime. This avoids runtime contention and allows
// better isolation of async operations.

/// Try to get a completed eval result (non-blocking)
///
/// Returns #f if no result is ready yet.
/// Returns the result string if ready: (hash 'value "..." 'output (list) 'error #f 'ns "user")
///
/// Usage in polling loop:
/// ```scheme
/// (define req-id (nrepl-eval session code))
/// (helix-await-callback
///   (lambda ()
///     (nrepl-try-get-result conn-id req-id))
///   (lambda (result)
///     (when result
///       ;; Got result! Process it
///       (process-result result))))
/// ```
pub fn nrepl_try_get_result(conn_id: usize, request_id: usize) -> SteelNReplResult<Option<String>> {
    // Try to get the response for this specific request ID
    // The worker buffers responses to support concurrent evals
    //
    // A missing connection (closed mid-eval) is an error so the Steel poll
    // loop terminates instead of rescheduling itself forever.
    let response =
        registry::try_recv_response(ConnectionId::new(conn_id), RequestId::new(request_id))
            .map_err(nrepl_error_to_steel)?;
    match response {
        Some(response) => match response.outcome {
            EvalOutcome::Done(result) => {
                let result = result.map_err(nrepl_error_to_steel)?;
                Ok(Some(eval_result_to_steel_hashmap(&result)))
            }
            EvalOutcome::NeedInput { output, error } => {
                // The evaluation is blocked on (read-line) etc. Surface a marker
                // hash so the Steel side can prompt and send `nrepl-stdin`
                // targeting this request id, then keep polling for the result.
                // Carry any output produced before the pause (e.g. a prompt
                // string) so the client can render it before opening its stdin
                // box. Escape identically to the `Done` path.
                let error_str = if error.is_empty() {
                    "#f".to_string()
                } else {
                    format!("\"{}\"", escape_steel_string(&error.join("\n")))
                };
                Ok(Some(format!(
                    "(hash 'need-input #t 'request-id {} 'output {} 'error {})",
                    request_id,
                    output_list_to_steel(&output),
                    error_str
                )))
            }
        },
        None => {
            // Response not ready yet
            Ok(None)
        }
    }
}

/// Connect to an nREPL server
/// Returns a connection ID
///
/// **Important:** You must call `nrepl-close` when done to avoid resource leaks.
/// Connections are not automatically closed when the ID goes out of scope.
///
/// # Example
/// ```scheme
/// (define conn (nrepl-connect "localhost:7888"))
/// (define session (nrepl-clone-session conn))
/// ;; ... use connection ...
/// (nrepl-close conn)  ; Don't forget this!
/// ```
///
/// Usage: (nrepl-connect "localhost:7888")
pub fn nrepl_connect(address: String) -> SteelNReplResult<usize> {
    // Create worker thread and connect to server
    // Connection happens within the worker's Tokio runtime context
    let conn_id = registry::create_and_connect(address).map_err(nrepl_error_to_steel)?;

    Ok(conn_id.as_usize())
}

/// Clone a new session from a connection
/// Returns a session handle
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// Usage: (define session (nrepl-clone-session conn-id))
pub fn nrepl_clone_session(conn_id: usize) -> SteelNReplResult<NReplSession> {
    let conn_id = ConnectionId::new(conn_id);
    let session = registry::clone_session_blocking(conn_id).map_err(nrepl_error_to_steel)?;

    let session_id = registry::add_session(conn_id, session).ok_or_else(|| {
        steel_error(format!(
            "Failed to add session to connection {}. The connection may have been closed.",
            conn_id.as_usize()
        ))
    })?;

    Ok(NReplSession {
        conn_id,
        session_id,
    })
}

/// Interrupt an ongoing evaluation.
///
/// With the demux worker, the command channel is always able to receive, so an
/// interrupt is written immediately even while an eval is in flight - it is no
/// longer blocked behind the running evaluation.
///
/// Takes the **steel request id** of the evaluation to interrupt (the value
/// returned by `nrepl-eval`/`nrepl-eval-with-timeout`); the worker forms the
/// wire interrupt-id (`req-{n}`) itself. If the target eval is still queued it
/// is cancelled locally; if it has already finished, this is a harmless no-op.
///
/// **Blocking:** waits up to 30 seconds for the server's interrupt ack.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID containing the evaluation
/// * `request_id` - The steel request id of the evaluation to interrupt
///
/// Usage: (nrepl-interrupt conn-id session-id request-id)
pub fn nrepl_interrupt(
    conn_id: usize,
    session_id: usize,
    request_id: usize,
) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id)
        .ok_or_else(|| session_not_found(conn_id, session_id))?;

    registry::interrupt_blocking(conn_id, session, request_id).map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// List the sessions active on the server (the `ls-sessions` op).
///
/// Returns a Steel `(list "session-id" ...)` source string of wire session
/// ids, for the Scheme side to parse with `parse-eval-result`.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
/// Servers that don't implement `ls-sessions` produce an "unknown op" error.
///
/// Usage: (nrepl-ls-sessions conn-id)
pub fn nrepl_ls_sessions(conn_id: usize) -> SteelNReplResult<String> {
    let conn_id = ConnectionId::new(conn_id);
    let sessions = registry::ls_sessions_blocking(conn_id).map_err(nrepl_error_to_steel)?;
    Ok(output_list_to_steel(&sessions))
}

/// Attach to an existing server session by its wire session id.
///
/// Purely client-side: registers the id in the registry and returns a session
/// handle usable with `eval`, `interrupt`, etc. No server round trip - the
/// session already exists on the server. If this client already holds a handle
/// for the id, that handle is returned instead of minting a duplicate.
///
/// The wire id must originate from a server response (`ls-sessions` or a clone
/// response), never from config or user input - adopting arbitrary ids is
/// session hijacking (see `Session::from_server_id`).
///
/// Usage: (nrepl-attach-session conn-id "31f2c0a2-...")
pub fn nrepl_attach_session(conn_id: usize, wire_id: String) -> SteelNReplResult<NReplSession> {
    let conn_id = ConnectionId::new(conn_id);
    if let Some(session_id) = registry::find_session_by_wire_id(conn_id, &wire_id) {
        return Ok(NReplSession {
            conn_id,
            session_id,
        });
    }
    let session = Session::from_server_id(wire_id);
    let session_id = registry::add_session(conn_id, session).ok_or_else(|| {
        steel_error(format!(
            "Failed to add session to connection {}. The connection may have been closed.",
            conn_id.as_usize()
        ))
    })?;
    Ok(NReplSession {
        conn_id,
        session_id,
    })
}

/// Close a server session identified by its wire session id.
///
/// Unlike `nrepl-close-session`, this does not need a client-side handle: it
/// closes any session `ls-sessions` reported, including ones created by other
/// clients or a previous connection. Any handles this client holds for the id
/// are removed from the registry afterwards.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// Usage: (nrepl-close-session-by-id conn-id "31f2c0a2-...")
pub fn nrepl_close_session_by_wire_id(conn_id: usize, wire_id: &str) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session = Session::from_server_id(wire_id);
    registry::close_session_blocking(conn_id, session).map_err(nrepl_error_to_steel)?;
    registry::remove_sessions_by_wire_id(conn_id, wire_id);
    Ok(())
}

/// Send stdin data to a session
///
/// Sends input data to a session for interactive programs that read from stdin.
/// This is useful for programs that call `read-line` or similar input functions.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
/// If the server doesn't respond within this timeout, a timeout error is returned.
///
/// # Arguments
/// * `conn_id` - The connection ID
/// * `session_id` - The session ID
/// * `data` - The stdin data to send
///
/// Usage: (nrepl-stdin conn-id session-id "user input\n")
pub fn nrepl_stdin(conn_id: usize, session_id: usize, data: &str) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);
    let session_id = SessionId::new(session_id);
    let session = registry::get_session(conn_id, session_id)
        .ok_or_else(|| session_not_found(conn_id, session_id))?;

    registry::stdin_blocking(conn_id, session, data.to_string()).map_err(nrepl_error_to_steel)?;

    Ok(())
}

/// Get registry statistics for observability
///
/// Returns a hashmap with connection and session counts, useful for monitoring.
///
/// Returns: Steel hashmap string with stats like:
/// `(hash 'total-connections 2 'total-sessions 5 'max-connections 100)`
///
/// Usage: (nrepl-stats)
#[must_use]
pub fn nrepl_stats() -> String {
    let stats = registry::get_stats();

    // Format as Steel hashmap with connection details
    let mut parts = vec![
        format!("'total-connections {}", stats.total_connections),
        format!("'total-sessions {}", stats.total_sessions),
        format!("'max-connections {}", stats.max_connections),
        format!("'next-conn-id {}", stats.next_conn_id),
    ];

    // Add connection details as list
    let conn_details: Vec<String> = stats
        .connections
        .iter()
        .map(|c| {
            format!(
                "(hash 'id {} 'sessions {})",
                c.connection_id.as_usize(),
                c.session_count
            )
        })
        .collect();

    parts.push(format!("'connections (list {})", conn_details.join(" ")));

    format!("(hash {})", parts.join(" "))
}

/// Describe the server's capabilities (the nREPL `describe` operation)
///
/// Queries the server for its supported operations, implementation versions,
/// and auxiliary metadata. This is the spec's capability-discovery mechanism;
/// the plugin uses it to gate optional operations and to surface server info.
///
/// **Blocking:** This operation blocks the calling thread for up to 30 seconds.
///
/// # Arguments
/// * `conn_id` - The connection ID (no session required - `describe` is global)
/// * `verbose` - When true, the server includes full op documentation
///
/// # Returns
///
/// An S-expression string holding a hashmap:
/// ```scheme
/// (hash 'ops (list "eval" "describe" "lookup" ...)
///       'versions (hash "nrepl" (hash "version-string" "1.3.0" ...) ...)
///       'aux (hash "current-ns" "user" ...))
/// ```
/// - `'ops`: list of supported operation names (the keys of the server's ops map)
/// - `'versions`: nested hash of implementation -> (sub-key -> value)
/// - `'aux`: flat hash of auxiliary metadata
///
/// Missing sections come back as empty `(list )` / `(hash )`.
///
/// Usage: (nrepl-describe conn-id #f)
pub fn nrepl_describe(conn_id: usize, verbose: bool) -> SteelNReplResult<String> {
    let conn_id = ConnectionId::new(conn_id);

    let response = registry::describe_blocking(conn_id, verbose).map_err(nrepl_error_to_steel)?;

    // ops -> (list "name" ...) - the op names are all the gating layer needs.
    let ops = match &response.ops {
        Some(ops) => {
            let names: Vec<String> = ops
                .keys()
                .map(|k| format!("\"{}\"", escape_steel_string(k)))
                .collect();
            format!("(list {})", names.join(" "))
        }
        None => "(list )".to_string(),
    };

    // versions -> (hash "impl" (hash "k" "v" ...) ...)
    let versions = match &response.versions {
        Some(versions) => {
            let entries: Vec<String> = versions
                .iter()
                .map(|(impl_name, sub)| {
                    let sub_parts: Vec<String> = sub
                        .iter()
                        .map(|(k, v)| {
                            format!(
                                "\"{}\" \"{}\"",
                                escape_steel_string(k),
                                escape_steel_string(v)
                            )
                        })
                        .collect();
                    format!(
                        "\"{}\" (hash {})",
                        escape_steel_string(impl_name),
                        sub_parts.join(" ")
                    )
                })
                .collect();
            format!("(hash {})", entries.join(" "))
        }
        None => "(hash )".to_string(),
    };

    // aux -> (hash "k" "v" ...)
    let aux = match &response.aux {
        Some(aux) => {
            let parts: Vec<String> = aux
                .iter()
                .map(|(k, v)| {
                    format!(
                        "\"{}\" \"{}\"",
                        escape_steel_string(k),
                        escape_steel_string(v)
                    )
                })
                .collect();
            format!("(hash {})", parts.join(" "))
        }
        None => "(hash )".to_string(),
    };

    Ok(format!("(hash 'ops {ops} 'versions {versions} 'aux {aux})"))
}

/// Close an nREPL connection
///
/// Removes the connection from the registry and triggers graceful shutdown.
/// The worker thread's Drop implementation will call `shutdown()` which closes
/// all sessions on the server and the TCP connection.
///
/// **You must call this** for every connection created with `nrepl-connect`
/// to avoid resource leaks.
///
/// **Non-blocking:** This function returns immediately. The actual cleanup
/// (closing sessions and TCP connection) happens in the background via the
/// worker thread's shutdown sequence with a 10-second timeout.
///
/// # Errors
/// Returns an error if the connection ID is not found (already closed or never existed).
///
/// Usage: (nrepl-close conn-id)
pub fn nrepl_close(conn_id: usize) -> SteelNReplResult<()> {
    let conn_id = ConnectionId::new(conn_id);

    // Remove connection from registry
    // This triggers worker Drop → shutdown() → client.shutdown()
    // which closes all sessions cleanly in the background
    if !registry::remove_connection(conn_id) {
        return Err(steel_error(format!(
            "Connection {} not found. It may have already been closed.",
            conn_id.as_usize()
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_escape_steel_string_quotes() {
        assert_eq!(escape_steel_string("\"hello\""), r#"\"hello\""#);
    }

    #[test]
    fn test_escape_steel_string_backslashes() {
        assert_eq!(escape_steel_string(r"path\to\file"), r"path\\to\\file");
    }

    #[test]
    fn test_escape_steel_string_newlines() {
        assert_eq!(escape_steel_string("line1\nline2"), r"line1\nline2");
    }

    #[test]
    fn test_escape_steel_string_tabs() {
        assert_eq!(escape_steel_string("col1\tcol2"), r"col1\tcol2");
    }

    #[test]
    fn test_escape_steel_string_carriage_return() {
        assert_eq!(escape_steel_string("line1\rline2"), r"line1\rline2");
    }

    #[test]
    fn test_escape_steel_string_combined() {
        let input = "He said \"Hello\"\nNext line\tTab here\\backslash";
        let expected = r#"He said \"Hello\"\nNext line\tTab here\\backslash"#;
        assert_eq!(escape_steel_string(input), expected);
    }

    #[test]
    fn test_escape_steel_string_empty() {
        assert_eq!(escape_steel_string(""), "");
    }

    #[test]
    fn test_escape_steel_string_no_escapes_needed() {
        assert_eq!(escape_steel_string("simple text"), "simple text");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_simple_value() {
        let result = EvalResult {
            value: Some("42".to_string()),
            output: vec![],
            error: vec![],
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify it's a valid S-expression hash
        assert!(hashmap.starts_with("(hash "), "Should start with '(hash '");
        assert!(hashmap.ends_with(')'), "Should end with ')'");

        // Verify it contains expected keys
        assert!(hashmap.contains("'value \"42\""), "Should contain value");
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );
        assert!(hashmap.contains("'error #f"), "Should contain no error");
        assert!(hashmap.contains("'ns \"user\""), "Should contain namespace");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_with_output() {
        let result = EvalResult {
            value: Some("3".to_string()),
            output: vec!["hello\n".to_string(), "world\n".to_string()],
            error: vec![],
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify output list contains both strings
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );
        assert!(
            hashmap.contains(r"hello\n"),
            "Should contain first output with escaped newline"
        );
        assert!(
            hashmap.contains(r"world\n"),
            "Should contain second output with escaped newline"
        );
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_with_error() {
        let result = EvalResult {
            value: None,
            output: vec![],
            error: vec!["Syntax error".to_string(), "Line 42".to_string()],
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify error is joined with newlines
        assert!(
            hashmap.contains("'error \"Syntax error\\nLine 42\""),
            "Should contain joined errors"
        );
        assert!(hashmap.contains("'value #f"), "Should contain no value");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_no_namespace() {
        let result = EvalResult {
            value: Some("result".to_string()),
            output: vec![],
            error: vec![],
            ns: None,
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        assert!(hashmap.contains("'ns #f"), "Should contain no namespace");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_special_chars_in_value() {
        let result = EvalResult {
            value: Some("\"quoted\"\n\ttabbed".to_string()),
            output: vec![],
            error: vec![],
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify special characters are escaped
        assert!(hashmap.contains(r#"\"quoted\""#), "Should escape quotes");
        assert!(hashmap.contains(r"\n"), "Should escape newline");
        assert!(hashmap.contains(r"\t"), "Should escape tab");
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_empty_error_list() {
        let result = EvalResult {
            value: Some("ok".to_string()),
            output: vec![],
            error: vec![], // Empty error list should become #f
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        assert!(
            hashmap.contains("'error #f"),
            "Empty error list should be #f"
        );
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_multiple_output_entries() {
        let result = EvalResult {
            value: Some("done".to_string()),
            output: vec![
                "line 1".to_string(),
                "line 2".to_string(),
                "line 3".to_string(),
            ],
            error: vec![],
            ns: Some("test.ns".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify all output entries are present
        assert!(hashmap.contains("\"line 1\""), "Should contain first line");
        assert!(hashmap.contains("\"line 2\""), "Should contain second line");
        assert!(hashmap.contains("\"line 3\""), "Should contain third line");
    }

    #[test]
    fn test_format_completions_empty() {
        assert_eq!(format_completions(&[]), "(list )");
    }

    #[test]
    fn test_format_completions_full_candidate() {
        let candidates = vec![CompletionCandidate {
            candidate: "map".to_string(),
            ns: Some("clojure.core".to_string()),
            candidate_type: Some("function".to_string()),
        }];

        assert_eq!(
            format_completions(&candidates),
            "(list (hash '#:candidate \"map\" '#:ns \"clojure.core\" '#:type \"function\"))"
        );
    }

    #[test]
    fn test_format_completions_missing_fields_are_false() {
        // babashka sends ns but no type; minimal servers may send neither
        let candidates = vec![CompletionCandidate {
            candidate: "mapv".to_string(),
            ns: Some("clojure.core".to_string()),
            candidate_type: None,
        }];

        assert_eq!(
            format_completions(&candidates),
            "(list (hash '#:candidate \"mapv\" '#:ns \"clojure.core\" '#:type #f))"
        );
    }

    #[test]
    fn test_format_completions_escapes_candidate() {
        let candidates = vec![CompletionCandidate {
            candidate: "weird\"name".to_string(),
            ns: None,
            candidate_type: None,
        }];

        assert_eq!(
            format_completions(&candidates),
            "(list (hash '#:candidate \"weird\\\"name\" '#:ns #f '#:type #f))"
        );
    }

    #[test]
    fn test_format_lookup_info_none_is_empty_hash() {
        assert_eq!(format_lookup_info(None), "(hash )");
    }

    #[test]
    fn test_format_lookup_info_fields_and_escaping() {
        let mut info = std::collections::BTreeMap::new();
        info.insert("doc".to_string(), "Line one\nline two".to_string());
        info.insert("ns".to_string(), "clojure.core".to_string());

        assert_eq!(
            format_lookup_info(Some(&info)),
            "(hash '#:doc \"Line one\\nline two\" '#:ns \"clojure.core\")"
        );
    }

    #[test]
    fn test_format_lookup_info_skips_unsafe_keys() {
        let mut info = std::collections::BTreeMap::new();
        info.insert("doc".to_string(), "adds numbers".to_string());
        info.insert("see also".to_string(), "x".to_string());
        info.insert("weird\"key".to_string(), "y".to_string());
        info.insert("arglists-str".to_string(), "[x y]".to_string());
        assert_eq!(
            format_lookup_info(Some(&info)),
            "(hash '#:arglists-str \"[x y]\" '#:doc \"adds numbers\")"
        );
    }

    #[test]
    fn test_eval_result_to_steel_hashmap_empty_string_output() {
        // Test edge case where output contains empty strings
        let result = EvalResult {
            value: Some("result".to_string()),
            output: vec![String::new(), "non-empty".to_string(), String::new()],
            error: vec![],
            ns: Some("user".to_string()),
            ex: None,
            interrupted: false,
        };

        let hashmap = eval_result_to_steel_hashmap(&result);

        // Verify output list is present
        assert!(
            hashmap.contains("'output (list"),
            "Should contain output list"
        );

        // Empty strings should appear as ""
        // The output should have three entries: two empty strings and one non-empty
        assert!(hashmap.contains("\"\""), "Should contain empty strings");
        assert!(
            hashmap.contains("\"non-empty\""),
            "Should contain non-empty string"
        );

        // Verify structure is valid
        assert!(hashmap.starts_with("(hash "), "Should start with '(hash '");
        assert!(hashmap.ends_with(')'), "Should end with ')'");
    }

    #[test]
    fn test_escape_steel_string_unicode_and_emoji() {
        // Test that Unicode and emoji characters are preserved as-is
        // Steel/Scheme strings support UTF-8, so we don't need to escape these

        // Unicode characters from various languages
        let unicode_text = "Hello 世界 مرحبا мир"; // Chinese, Arabic, Cyrillic
        assert_eq!(
            escape_steel_string(unicode_text),
            unicode_text,
            "Unicode text should be preserved"
        );

        // Emoji
        let emoji_text = "🎉 🚀 ❤️ 👍";
        assert_eq!(
            escape_steel_string(emoji_text),
            emoji_text,
            "Emoji should be preserved"
        );

        // Mixed content with special chars that DO need escaping
        let mixed = "Hello 🌍\nNext line\t\"quoted\"";
        let expected = "Hello 🌍\\nNext line\\t\\\"quoted\\\""; // Only ASCII special chars escaped
        assert_eq!(
            escape_steel_string(mixed),
            expected,
            "Should preserve Unicode while escaping ASCII special chars"
        );

        // Edge case: Unicode with backslash
        let unicode_with_backslash = "Path\\to\\日本語\\file";
        let expected_unicode_backslash = "Path\\\\to\\\\日本語\\\\file"; // Backslashes escaped, Unicode preserved
        assert_eq!(
            escape_steel_string(unicode_with_backslash),
            expected_unicode_backslash,
            "Should escape backslashes but preserve Unicode"
        );
    }

    #[test]
    fn test_max_code_size_constant() {
        // Verify MAX_CODE_SIZE is set to expected value
        assert_eq!(
            MAX_CODE_SIZE,
            10 * 1024 * 1024,
            "MAX_CODE_SIZE should be 10MB"
        );
    }

    /// Build a session handle pointing at ids the registry does not hold.
    fn orphan_session(conn_id: usize, session_id: usize) -> NReplSession {
        NReplSession {
            conn_id: ConnectionId::new(conn_id),
            session_id: SessionId::new(session_id),
        }
    }

    /// Eval through a handle the registry cannot resolve fails with the
    /// session-not-found error.
    ///
    /// An unknown connection and an unknown session inside a live connection
    /// both land here: the lookup is a single `get_session(conn, session)`, so
    /// there is one failure path, not two. This also covers a handle whose
    /// session has been closed, since closing removes it from the registry.
    #[test]
    fn test_eval_with_unresolvable_session_fails() {
        for (conn_id, session_id, case) in [
            (999, 1, "unknown connection"),
            (1, 999, "unknown session"),
            (1, 1, "closed session"),
        ] {
            let mut session = orphan_session(conn_id, session_id);

            let result = session.eval_with_timeout("(+ 1 2)", 60_000, None, None, None);

            assert!(result.is_err(), "eval should fail for {case}");
            let err_msg = format!("{:?}", result.unwrap_err());
            assert!(
                err_msg.contains("Session") && err_msg.contains("not found"),
                "Error for {case} should mention session not found, got: {err_msg}"
            );
        }
    }

    // Property-based tests using proptest
    use proptest::prelude::*;

    proptest! {
        /// Property: Escaped string should never be shorter than the original
        ///
        /// Since escaping only adds characters (never removes), the escaped
        /// string must be >= original length
        #[test]
        fn prop_escaped_length_never_decreases(s in ".*") {
            let escaped = escape_steel_string(&s);
            prop_assert!(escaped.len() >= s.len(),
                "Escaped string ({} bytes) shorter than original ({} bytes): {:?} -> {:?}",
                escaped.len(), s.len(), s, escaped);
        }

        /// Property: No unescaped quotes in output
        ///
        /// After escaping, any quote character (") must be preceded by a backslash.
        /// This ensures the string can be safely embedded in Steel/Scheme syntax.
        #[test]
        fn prop_no_unescaped_quotes(s in ".*") {
            let escaped = escape_steel_string(&s);

            // Check each quote is preceded by backslash
            let chars: Vec<char> = escaped.chars().collect();
            for (i, &c) in chars.iter().enumerate() {
                if c == '"' {
                    prop_assert!(i > 0 && chars[i-1] == '\\',
                        "Found unescaped quote at position {} in: {:?}", i, escaped);
                }
            }
        }

        /// Property: No bare newlines, tabs, or carriage returns
        ///
        /// These characters must be escaped as \n, \t, \r respectively.
        /// The literal characters should not appear in the output.
        #[test]
        fn prop_no_bare_control_chars(s in ".*") {
            let escaped = escape_steel_string(&s);

            prop_assert!(!escaped.contains('\n'),
                "Found bare newline in escaped string: {:?}", escaped);
            prop_assert!(!escaped.contains('\t'),
                "Found bare tab in escaped string: {:?}", escaped);
            prop_assert!(!escaped.contains('\r'),
                "Found bare carriage return in escaped string: {:?}", escaped);
        }

        /// Property: All backslashes are doubled or part of valid escape sequences
        ///
        /// After escaping, every backslash should either be:
        /// - Followed by another backslash (escaped backslash: \\)
        /// - Followed by a valid ASCII escape character (", n, t, r)
        /// Note: Non-ASCII characters after backslash are fine (they pass through unchanged)
        #[test]
        fn prop_valid_escape_sequences(s in ".*") {
            let escaped = escape_steel_string(&s);
            let chars: Vec<char> = escaped.chars().collect();

            let mut i = 0;
            while i < chars.len() {
                if chars[i] == '\\' {
                    prop_assert!(i + 1 < chars.len(),
                        "Backslash at end of string (position {}): {:?}", i, escaped);

                    let next = chars[i + 1];
                    // After a backslash, we expect either:
                    // - Another backslash (escaped \)
                    // - An ASCII escape char (", n, t, r)
                    // - Or a non-ASCII char (which is fine, just data)
                    if next.is_ascii() {
                        prop_assert!(
                            next == '\\' || next == '"' || next == 'n' || next == 't' || next == 'r',
                            "Invalid ASCII escape sequence \\{} at position {} in: {:?}",
                            next, i, escaped
                        );
                    }
                    // If we have \\, skip the next backslash
                    if next == '\\' {
                        i += 2;
                        continue;
                    }
                }
                i += 1;
            }
        }

        /// Property: Unicode and emoji are preserved
        ///
        /// Non-ASCII characters should pass through unchanged, only ASCII
        /// special characters should be escaped.
        #[test]
        fn prop_unicode_preserved(s in "[\\u{80}-\\u{10FFFF}]+") {
            // Generate strings with only non-ASCII characters
            let escaped = escape_steel_string(&s);

            // Since the input contains no ASCII special chars, output should equal input
            prop_assert_eq!(&escaped, &s,
                "Unicode-only string was modified: {:?} -> {:?}", s, escaped);
        }

        /// Property: Escaping is consistent
        ///
        /// Calling escape_steel_string twice should produce the same result as
        /// calling it once (idempotence for already-escaped strings).
        /// Note: This is NOT true in general because escaping adds backslashes
        /// which then get escaped again. This property tests that re-escaping
        /// is well-defined.
        #[test]
        fn prop_double_escape_is_well_defined(s in ".*") {
            let escaped_once = escape_steel_string(&s);
            let escaped_twice = escape_steel_string(&escaped_once);

            // Verify second escape is valid (doesn't panic or produce invalid output)
            prop_assert!(escaped_twice.len() >= escaped_once.len(),
                "Second escape produced shorter string: {:?} -> {:?}",
                escaped_once, escaped_twice);
        }

        /// Property: Empty string remains empty
        #[test]
        fn prop_empty_string_unchanged(_s in prop::strategy::Just(())) {
            let escaped = escape_steel_string("");
            prop_assert_eq!(&escaped, "",
                "Empty string was modified: {:?}", escaped);
        }

        /// Property: Strings without special characters are unchanged
        ///
        /// If a string contains only alphanumeric, spaces, and common punctuation
        /// (no quotes, backslashes, or control chars), it should pass through as-is.
        #[test]
        fn prop_safe_strings_unchanged(s in "[a-zA-Z0-9 .,;:!?()\\[\\]{}]+") {
            let escaped = escape_steel_string(&s);
            prop_assert_eq!(&escaped, &s,
                "Safe string was modified: {:?} -> {:?}", s, escaped);
        }
    }
}
