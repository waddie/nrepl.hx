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

/// nREPL operation builders
use crate::message::Request;

/// Format a numeric request id into its on-the-wire form (`req-{n}`).
///
/// The wire id is a pure function of the caller's numeric id. Each connection
/// owns a single id source (the worker's `RequestId` counter), so there is no
/// global counter and the demux loop can route responses collision-free.
pub fn wire_id(id: usize) -> String {
    format!("req-{}", id)
}

/// Helper to create a base request with just op and an explicit id
fn base_request(op: &str, id: impl Into<String>) -> Request {
    Request {
        op: op.to_string(),
        id: id.into(),
        session: None,
        code: None,
        line: None,
        column: None,
        file: None,
        file_path: None,
        file_name: None,
        interrupt_id: None,
        stdin: None,
        verbose: None,
        prefix: None,
        complete_fn: None,
        ns: None,
        options: None,
        sym: None,
        lookup_fn: None,
        middleware: None,
        extra_namespaces: None,
    }
}

pub fn clone_request(id: impl Into<String>) -> Request {
    base_request("clone", id)
}

pub fn eval_request(id: impl Into<String>, session: &str, code: impl Into<String>) -> Request {
    let mut req = base_request("eval", id);
    req.session = Some(session.to_string());
    req.code = Some(code.into());
    req
}

/// Build an eval request with optional file location metadata
///
/// This allows the nREPL server to preserve source file metadata in compiled functions,
/// improving stack traces by showing actual filenames instead of "NO_SOURCE_FILE".
///
/// # Arguments
/// * `session` - The session ID
/// * `code` - Code to evaluate
/// * `file` - Optional file path containing the code
/// * `line` - Optional line number (1-indexed)
/// * `column` - Optional column number (1-indexed)
///
/// # Notes
/// - Requires nREPL server 1.3.0+ for metadata preservation (PR #385)
/// - Older servers will ignore unknown parameters (graceful degradation)
/// - All location parameters are optional and independent
pub fn eval_request_with_location(
    id: impl Into<String>,
    session: &str,
    code: impl Into<String>,
    file: Option<String>,
    line: Option<i64>,
    column: Option<i64>,
) -> Request {
    let mut req = base_request("eval", id);
    req.session = Some(session.to_string());
    req.code = Some(code.into());
    req.file = file;
    req.line = line;
    req.column = column;
    req
}

/// Build a load-file request
///
/// # Arguments
/// * `session` - The session ID
/// * `file_contents` - The contents of the file to load
/// * `file_path` - Optional file path (for error messages)
/// * `file_name` - Optional file name (for error messages)
pub fn load_file_request(
    id: impl Into<String>,
    session: &str,
    file_contents: impl Into<String>,
    file_path: Option<String>,
    file_name: Option<String>,
) -> Request {
    let mut req = base_request("load-file", id);
    req.session = Some(session.to_string());
    req.file = Some(file_contents.into());
    req.file_path = file_path;
    req.file_name = file_name;
    req
}

/// Build a close request to close a session
pub fn close_request(id: impl Into<String>, session: &str) -> Request {
    let mut req = base_request("close", id);
    req.session = Some(session.to_string());
    req
}

/// Build an interrupt request to interrupt an ongoing evaluation
///
/// # Arguments
/// * `session` - The session ID
/// * `interrupt_id` - The message ID of the evaluation to interrupt
pub fn interrupt_request(
    id: impl Into<String>,
    session: &str,
    interrupt_id: impl Into<String>,
) -> Request {
    let mut req = base_request("interrupt", id);
    req.session = Some(session.to_string());
    req.interrupt_id = Some(interrupt_id.into());
    req
}

/// Build a describe request to get server capabilities
///
/// # Arguments
/// * `verbose` - Optional flag for verbose output
pub fn describe_request(id: impl Into<String>, verbose: Option<bool>) -> Request {
    let mut req = base_request("describe", id);
    req.verbose = verbose;
    req
}

/// Build an ls-sessions request to list active sessions
pub fn ls_sessions_request(id: impl Into<String>) -> Request {
    base_request("ls-sessions", id)
}

/// Build a stdin request to send input to a session
///
/// # Arguments
/// * `session` - The session ID
/// * `stdin_data` - The input data to send
pub fn stdin_request(
    id: impl Into<String>,
    session: &str,
    stdin_data: impl Into<String>,
) -> Request {
    let mut req = base_request("stdin", id);
    req.session = Some(session.to_string());
    req.stdin = Some(stdin_data.into());
    req
}

/// Build a completions request
///
/// # Arguments
/// * `session` - The session ID
/// * `prefix` - The prefix to complete
/// * `ns` - Optional namespace
/// * `complete_fn` - Optional custom completion function
pub fn completions_request(
    id: impl Into<String>,
    session: &str,
    prefix: impl Into<String>,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> Request {
    let mut req = base_request("completions", id);
    req.session = Some(session.to_string());
    req.prefix = Some(prefix.into());
    req.ns = ns;
    req.complete_fn = complete_fn;
    req
}

/// Build a lookup request to get information about a symbol
///
/// # Arguments
/// * `session` - The session ID
/// * `sym` - The symbol to look up
/// * `ns` - Optional namespace
/// * `lookup_fn` - Optional custom lookup function
pub fn lookup_request(
    id: impl Into<String>,
    session: &str,
    sym: impl Into<String>,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> Request {
    let mut req = base_request("lookup", id);
    req.session = Some(session.to_string());
    req.sym = Some(sym.into());
    req.ns = ns;
    req.lookup_fn = lookup_fn;
    req
}

/// Build an ls-middleware request to list loaded middleware
pub fn ls_middleware_request(id: impl Into<String>) -> Request {
    base_request("ls-middleware", id)
}

/// Build an add-middleware request
///
/// # Arguments
/// * `middleware` - List of middleware to add
/// * `extra_namespaces` - Optional list of extra namespaces to load
pub fn add_middleware_request(
    id: impl Into<String>,
    middleware: Vec<String>,
    extra_namespaces: Option<Vec<String>>,
) -> Request {
    let mut req = base_request("add-middleware", id);
    req.middleware = Some(middleware);
    req.extra_namespaces = extra_namespaces;
    req
}

/// Build a swap-middleware request
///
/// # Arguments
/// * `middleware` - List of middleware to replace the entire stack
/// * `extra_namespaces` - Optional list of extra namespaces to load
pub fn swap_middleware_request(
    id: impl Into<String>,
    middleware: Vec<String>,
    extra_namespaces: Option<Vec<String>>,
) -> Request {
    let mut req = base_request("swap-middleware", id);
    req.middleware = Some(middleware);
    req.extra_namespaces = extra_namespaces;
    req
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wire_id_format() {
        assert_eq!(wire_id(1), "req-1");
        assert_eq!(wire_id(42), "req-42");
    }

    #[test]
    fn test_eval_request_with_location_all_params() {
        let req = eval_request_with_location(
            wire_id(7),
            "session-1",
            "(+ 1 2)",
            Some("/path/to/file.clj".to_string()),
            Some(42),
            Some(10),
        );

        assert_eq!(req.id, "req-7");
        assert_eq!(req.op, "eval");
        assert_eq!(req.session, Some("session-1".to_string()));
        assert_eq!(req.code, Some("(+ 1 2)".to_string()));
        assert_eq!(req.file, Some("/path/to/file.clj".to_string()));
        assert_eq!(req.line, Some(42));
        assert_eq!(req.column, Some(10));
    }

    #[test]
    fn test_eval_request_with_location_no_metadata() {
        let req = eval_request_with_location(wire_id(1), "session-1", "(+ 1 2)", None, None, None);

        assert_eq!(req.op, "eval");
        assert_eq!(req.session, Some("session-1".to_string()));
        assert_eq!(req.code, Some("(+ 1 2)".to_string()));
        assert_eq!(req.file, None);
        assert_eq!(req.line, None);
        assert_eq!(req.column, None);
    }

    #[test]
    fn test_eval_request_with_location_partial_metadata() {
        let req = eval_request_with_location(
            wire_id(2),
            "session-1",
            "(defn foo [] 42)",
            Some("src/core.clj".to_string()),
            Some(10),
            None, // No column
        );

        assert_eq!(req.file, Some("src/core.clj".to_string()));
        assert_eq!(req.line, Some(10));
        assert_eq!(req.column, None);
    }

    #[test]
    fn test_eval_request_backward_compatible() {
        // Old eval_request should still work
        let req = eval_request(wire_id(3), "session-1", "(+ 1 2)");

        assert_eq!(req.op, "eval");
        assert_eq!(req.session, Some("session-1".to_string()));
        assert_eq!(req.code, Some("(+ 1 2)".to_string()));
        // Location fields should be None
        assert_eq!(req.file, None);
        assert_eq!(req.line, None);
        assert_eq!(req.column, None);
    }
}
