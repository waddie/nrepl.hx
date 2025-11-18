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

/// Type alias for nested string maps (used in describe operation for ops/versions)
type NestedStringMap = BTreeMap<String, BTreeMap<String, String>>;

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

    // eval operation - file location metadata
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) line: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) column: Option<i64>,

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
                    s[1..s.len() - 1].to_string()
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

/// Convert a map of bencode values to a map of string representations
/// Used for lookup info which contains mixed value types (strings, lists, etc.)
///
/// **Special handling**: cider-nrepl sends an empty list `[]` when a symbol doesn't exist,
/// instead of an empty map or null. This deserializer handles that case gracefully.
fn deserialize_info_map<'de, D>(
    deserializer: D,
) -> Result<Option<BTreeMap<String, String>>, D::Error>
where
    D: Deserializer<'de>,
{
    // Try to deserialize as BencodeValue to handle both map and list cases
    let value: Option<BencodeValue> = Option::deserialize(deserializer)?;

    match value {
        Some(BencodeValue::Dict(map)) => {
            // Normal case: map with symbol info
            Ok(Some(
                map.into_iter()
                    .map(|(k, v)| (k, v.to_string_repr()))
                    .collect(),
            ))
        }
        Some(BencodeValue::List(_)) => {
            // cider-nrepl sends empty list [] for unknown symbols
            // Treat as None (no info available)
            Ok(None)
        }
        _ => {
            // None or other types
            Ok(None)
        }
    }
}

/// Convert aux field which can contain nested structures from cider-nrepl
///
/// **Special handling**: cider-nrepl sends nested dictionaries in aux field
/// (e.g., `{"cider-version": {"major": 0, "minor": 50, ...}}`).
/// This deserializer flattens or converts nested structures to strings.
fn deserialize_aux_map<'de, D>(
    deserializer: D,
) -> Result<Option<BTreeMap<String, String>>, D::Error>
where
    D: Deserializer<'de>,
{
    let value: Option<BTreeMap<String, BencodeValue>> = Option::deserialize(deserializer)?;
    Ok(value.map(|m| {
        m.into_iter()
            .map(|(k, v)| (k, v.to_string_repr()))
            .collect()
    }))
}

/// Convert nested ops/versions maps from describe operation
///
/// **Special handling**: cider-nrepl sends nested dictionaries with BencodeValue types
/// in the ops and versions fields. This deserializer converts all nested values to strings.
fn deserialize_nested_map<'de, D>(deserializer: D) -> Result<Option<NestedStringMap>, D::Error>
where
    D: Deserializer<'de>,
{
    let value: Option<BTreeMap<String, BTreeMap<String, BencodeValue>>> =
        Option::deserialize(deserializer)?;
    Ok(value.map(|outer_map| {
        outer_map
            .into_iter()
            .map(|(outer_key, inner_map)| {
                let converted_inner: BTreeMap<String, String> = inner_map
                    .into_iter()
                    .map(|(k, v)| (k, v.to_string_repr()))
                    .collect();
                (outer_key, converted_inner)
            })
            .collect()
    }))
}

/// Represents a single completion candidate returned by the completions operation
///
/// The nREPL completions middleware returns structured data for each completion:
/// - `candidate`: The completion string (e.g., "map", "reduce")
/// - `ns`: The namespace where the symbol is defined (e.g., "clojure.core")
/// - `type`: The type of the symbol (e.g., "function", "macro", "var")
#[derive(Debug, Clone, Deserialize)]
pub struct CompletionCandidate {
    pub candidate: String,
    #[serde(default)]
    pub ns: Option<String>,
    #[serde(default, rename = "type")]
    pub candidate_type: Option<String>,
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
    pub completions: Option<Vec<CompletionCandidate>>,

    // describe operation
    #[serde(default, deserialize_with = "deserialize_nested_map")]
    pub ops: Option<BTreeMap<String, BTreeMap<String, String>>>,
    #[serde(default, deserialize_with = "deserialize_nested_map")]
    pub versions: Option<BTreeMap<String, BTreeMap<String, String>>>,
    #[serde(default, deserialize_with = "deserialize_aux_map")]
    pub aux: Option<BTreeMap<String, String>>,

    // lookup operation
    #[serde(default, deserialize_with = "deserialize_info_map")]
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
