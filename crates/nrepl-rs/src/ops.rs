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
#[must_use]
pub fn wire_id(id: usize) -> String {
    format!("req-{id}")
}

/// A request carrying only `op` and an explicit id; every other field defaults
/// to `None`. Builders fill in their own fields with struct-update syntax.
fn base_request(op: &str, id: impl Into<String>) -> Request {
    Request {
        op: op.to_string(),
        id: id.into(),
        ..Request::default()
    }
}

pub fn clone_request(id: impl Into<String>) -> Request {
    base_request("clone", id)
}

/// Build an eval request with optional file location metadata
///
/// This allows the nREPL server to preserve source file metadata in compiled functions,
/// improving stack traces by showing actual filenames instead of "`NO_SOURCE_FILE`".
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
    Request {
        session: Some(session.to_string()),
        code: Some(code.into()),
        file,
        line,
        column,
        ..base_request("eval", id)
    }
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
    Request {
        session: Some(session.to_string()),
        file: Some(file_contents.into()),
        file_path,
        file_name,
        ..base_request("load-file", id)
    }
}

/// Build a close request to close a session
pub fn close_request(id: impl Into<String>, session: &str) -> Request {
    Request {
        session: Some(session.to_string()),
        ..base_request("close", id)
    }
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
    Request {
        session: Some(session.to_string()),
        interrupt_id: Some(interrupt_id.into()),
        ..base_request("interrupt", id)
    }
}

/// Build a describe request to get server capabilities
///
/// # Arguments
/// * `verbose` - Optional flag for verbose output
pub fn describe_request(id: impl Into<String>, verbose: Option<bool>) -> Request {
    Request {
        verbose,
        ..base_request("describe", id)
    }
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
    Request {
        session: Some(session.to_string()),
        stdin: Some(stdin_data.into()),
        ..base_request("stdin", id)
    }
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
    Request {
        session: Some(session.to_string()),
        prefix: Some(prefix.into()),
        ns,
        complete_fn,
        ..base_request("completions", id)
    }
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
    Request {
        session: Some(session.to_string()),
        sym: Some(sym.into()),
        ns,
        lookup_fn,
        ..base_request("lookup", id)
    }
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
}
