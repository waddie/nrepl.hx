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
use uuid::Uuid;

pub fn clone_request() -> Request {
    Request {
        op: "clone".to_string(),
        id: Uuid::new_v4().to_string(),
        session: None,
        code: None,
        file: None,
    }
}

pub fn eval_request(session: &str, code: impl Into<String>) -> Request {
    Request {
        op: "eval".to_string(),
        id: Uuid::new_v4().to_string(),
        session: Some(session.to_string()),
        code: Some(code.into()),
        file: None,
    }
}

pub fn load_file_request(session: &str, file: impl Into<String>) -> Request {
    Request {
        op: "load-file".to_string(),
        id: Uuid::new_v4().to_string(),
        session: Some(session.to_string()),
        code: None,
        file: Some(file.into()),
    }
}

pub fn close_request(session: &str) -> Request {
    Request {
        op: "close".to_string(),
        id: Uuid::new_v4().to_string(),
        session: Some(session.to_string()),
        code: None,
        file: None,
    }
}
