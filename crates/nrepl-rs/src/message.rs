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

use serde::{Deserialize, Deserializer, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub(crate) op: String,
    pub(crate) id: String,
    // Common to many operations
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) session: Option<String>,

    // eval operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) code: Option<String>,

    // load-file operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "file-path")]
    pub(crate) file_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "file-name")]
    pub(crate) file_name: Option<String>,

    // interrupt operation
    #[serde(skip_serializing_if = "Option::is_none", rename = "interrupt-id")]
    pub(crate) interrupt_id: Option<String>,

    // stdin operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) stdin: Option<String>,

    // describe operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) verbose: Option<bool>,

    // completions operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) prefix: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "complete-fn")]
    pub(crate) complete_fn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) ns: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) options: Option<String>,

    // lookup operation
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) sym: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lookup-fn")]
    pub(crate) lookup_fn: Option<String>,

    // middleware operations (add-middleware, swap-middleware)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) middleware: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "extra-namespaces")]
    pub(crate) extra_namespaces: Option<Vec<String>>,
}

/// Bencode value types that can appear in nREPL responses
/// Standard nREPL uses strings, but nrepl-python sends structured data
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum BencodeValue {
    String(String),
    Int(i64),
    List(Vec<BencodeValue>),
    Dict(BTreeMap<String, BencodeValue>),
}

impl BencodeValue {
    fn to_string_repr(&self) -> String {
        match self {
            BencodeValue::String(s) => {
                // Strip surrounding quotes from Clojure string values
                // Clojure returns string values as "..." (with quotes)
                // We want to return the actual string content without quotes
                if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
                    // Remove the surrounding quotes
                    s[1..s.len()-1].to_string()
                } else {
                    s.clone()
                }
            }
            BencodeValue::Int(i) => i.to_string(),
            BencodeValue::List(list) => {
                let items: Vec<String> = list.iter().map(|v| v.to_string_repr()).collect();
                format!("[{}]", items.join(", "))
            }
            BencodeValue::Dict(dict) => {
                let items: Vec<String> = dict
                    .iter()
                    .map(|(k, v)| format!("{}: {}", k, v.to_string_repr()))
                    .collect();
                format!("{{{}}}", items.join(", "))
            }
        }
    }
}

/// Convert any bencode value to a string representation
/// Handles both standard nREPL (string values) and nrepl-python (structured values)
/// IMPORTANT: Must use default attribute to handle missing field
fn deserialize_value<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let value: Option<BencodeValue> = Option::deserialize(deserializer)?;
    Ok(value.map(|v| v.to_string_repr()))
}

#[derive(Debug, Clone, Deserialize)]
pub struct Response {
    pub id: String,
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub status: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_value")]
    pub value: Option<String>,
    pub out: Option<String>,
    pub err: Option<String>,
    pub ns: Option<String>,

    // clone operation
    #[serde(rename = "new-session")]
    pub new_session: Option<String>,

    // ls-sessions operation
    pub sessions: Option<Vec<String>>,

    // completions operation
    pub completions: Option<Vec<String>>,

    // describe operation
    pub ops: Option<BTreeMap<String, BTreeMap<String, String>>>,
    pub versions: Option<BTreeMap<String, BTreeMap<String, String>>>,
    pub aux: Option<BTreeMap<String, String>>,

    // lookup operation
    pub info: Option<BTreeMap<String, String>>,

    // middleware operations
    pub middleware: Option<Vec<String>>,
    #[serde(rename = "unresolved-middleware")]
    pub unresolved_middleware: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct EvalResult {
    pub value: Option<String>,
    pub output: Vec<String>,
    pub error: Vec<String>,
    pub ns: Option<String>,
}

impl EvalResult {
    pub fn new() -> Self {
        Self {
            value: None,
            output: Vec::new(),
            error: Vec::new(),
            ns: None,
        }
    }
}

impl Default for EvalResult {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eval_result_is_send_sync() {
        fn assert_send<T: Send>() {}
        fn assert_sync<T: Sync>() {}

        assert_send::<EvalResult>();
        assert_sync::<EvalResult>();
    }
}
