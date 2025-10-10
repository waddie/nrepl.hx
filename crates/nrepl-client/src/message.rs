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

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub op: String,
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Response {
    pub id: String,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub status: Vec<String>,
    pub value: Option<String>,
    pub out: Option<String>,
    pub err: Option<String>,
    pub ns: Option<String>,
}

#[derive(Debug, Clone)]
pub struct EvalResult {
    pub value: Option<String>,
    pub output: Vec<String>,
    pub error: Option<String>,
    pub ns: Option<String>,
}

impl EvalResult {
    pub fn new() -> Self {
        Self {
            value: None,
            output: Vec::new(),
            error: None,
            ns: None,
        }
    }
}

impl Default for EvalResult {
    fn default() -> Self {
        Self::new()
    }
}
