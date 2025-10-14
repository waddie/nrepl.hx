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
use std::sync::atomic::{AtomicUsize, Ordering};

/// Global counter for generating sequential request IDs
static REQUEST_ID_COUNTER: AtomicUsize = AtomicUsize::new(1);

/// Generate a unique request ID
///
/// Uses a global atomic counter to generate sequential IDs starting from 1.
/// Thread-safe and guaranteed to produce unique IDs within a single process.
fn next_request_id() -> String {
    let id = REQUEST_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("req-{}", id)
}

/// Helper to create a base request with just op and id
fn base_request(op: &str) -> Request {
    Request {
        op: op.to_string(),
        id: next_request_id(),
        session: None,
        code: None,
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

pub fn clone_request() -> Request {
    base_request("clone")
}

pub fn eval_request(session: &str, code: impl Into<String>) -> Request {
    let mut req = base_request("eval");
    req.session = Some(session.to_string());
    req.code = Some(code.into());
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
    session: &str,
    file_contents: impl Into<String>,
    file_path: Option<String>,
    file_name: Option<String>,
) -> Request {
    let mut req = base_request("load-file");
    req.session = Some(session.to_string());
    req.file = Some(file_contents.into());
    req.file_path = file_path;
    req.file_name = file_name;
    req
}

/// Build a close request to close a session
pub fn close_request(session: &str) -> Request {
    let mut req = base_request("close");
    req.session = Some(session.to_string());
    req
}

/// Build an interrupt request to interrupt an ongoing evaluation
///
/// # Arguments
/// * `session` - The session ID
/// * `interrupt_id` - The message ID of the evaluation to interrupt
pub fn interrupt_request(session: &str, interrupt_id: impl Into<String>) -> Request {
    let mut req = base_request("interrupt");
    req.session = Some(session.to_string());
    req.interrupt_id = Some(interrupt_id.into());
    req
}

/// Build a describe request to get server capabilities
///
/// # Arguments
/// * `verbose` - Optional flag for verbose output
pub fn describe_request(verbose: Option<bool>) -> Request {
    let mut req = base_request("describe");
    req.verbose = verbose;
    req
}

/// Build an ls-sessions request to list active sessions
pub fn ls_sessions_request() -> Request {
    base_request("ls-sessions")
}

/// Build a stdin request to send input to a session
///
/// # Arguments
/// * `session` - The session ID
/// * `stdin_data` - The input data to send
pub fn stdin_request(session: &str, stdin_data: impl Into<String>) -> Request {
    let mut req = base_request("stdin");
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
    session: &str,
    prefix: impl Into<String>,
    ns: Option<String>,
    complete_fn: Option<String>,
) -> Request {
    let mut req = base_request("completions");
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
    session: &str,
    sym: impl Into<String>,
    ns: Option<String>,
    lookup_fn: Option<String>,
) -> Request {
    let mut req = base_request("lookup");
    req.session = Some(session.to_string());
    req.sym = Some(sym.into());
    req.ns = ns;
    req.lookup_fn = lookup_fn;
    req
}

/// Build an ls-middleware request to list loaded middleware
pub fn ls_middleware_request() -> Request {
    base_request("ls-middleware")
}

/// Build an add-middleware request
///
/// # Arguments
/// * `middleware` - List of middleware to add
/// * `extra_namespaces` - Optional list of extra namespaces to load
pub fn add_middleware_request(
    middleware: Vec<String>,
    extra_namespaces: Option<Vec<String>>,
) -> Request {
    let mut req = base_request("add-middleware");
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
    middleware: Vec<String>,
    extra_namespaces: Option<Vec<String>>,
) -> Request {
    let mut req = base_request("swap-middleware");
    req.middleware = Some(middleware);
    req.extra_namespaces = extra_namespaces;
    req
}
