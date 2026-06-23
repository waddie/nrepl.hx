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
pub(crate) enum BencodeValue {
    String(String),
    Int(i64),
    List(Vec<BencodeValue>),
    Dict(BTreeMap<String, BencodeValue>),
}

impl BencodeValue {
    pub(crate) fn to_string_repr(&self) -> String {
        match self {
            BencodeValue::String(s) => {
                // Conformance (#5): nREPL's `value` is strictly the *printed
                // representation* of the result, so a string result arrives
                // already quoted (e.g. `"hello"`). We preserve it verbatim, as
                // the spec intends: the quotes are part of the printed form and
                // are what distinguish the string `"hello"` from the symbol
                // `hello`. Display/quote handling is left to the adapter layer.
                s.clone()
            }
            BencodeValue::Int(i) => i.to_string(),
            BencodeValue::List(list) => {
                let items: Vec<String> = list.iter().map(BencodeValue::to_string_repr).collect();
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
/// **Special handling**: nREPL's `describe` normally nests a map under each
/// ops/versions key (cider-nrepl, for instance, sends nested dictionaries with
/// mixed value types). But some servers send a *flat* map whose values are
/// scalars — notably babashka, whose `versions` looks like
/// `{"babashka" "1.12.218", "babashka.nrepl" "0.0.6-SNAPSHOT"}`.
///
/// We accept either shape: each outer value is deserialized as a flexible
/// [`BencodeValue`] and normalised to an inner string map. A scalar value is
/// surfaced under a synthetic `version-string` key so callers that look it up
/// (the describe UI) still find it. Tolerating both shapes here matters because
/// a strict type mismatch would fail the *whole* response decode, and a complete
/// but undecodable message stalls the reader (see `codec::decode_one`).
///
/// **A third shape**: guile-ares-rs (and potentially other non-Clojure servers)
/// sends `ops` as a flat bencode *list* of operation-name strings, e.g.
/// `["eval" "describe" "clone" ...]`, rather than a map. We normalise that to a
/// map whose keys are the op names and whose inner maps are empty — the same
/// observable shape callers get from a server that nests empty dicts. Without
/// this, a list here would fail the entire `describe` decode and the connect
/// would stall for the full blocking timeout before giving up.
fn deserialize_nested_map<'de, D>(deserializer: D) -> Result<Option<NestedStringMap>, D::Error>
where
    D: Deserializer<'de>,
{
    let value: Option<BencodeValue> = Option::deserialize(deserializer)?;
    Ok(value.map(nested_map_from_bencode))
}

/// Normalise a `describe` `ops`/`versions` value (any of the three observed
/// shapes — nested dict, flat scalar dict, or list of strings) into the
/// canonical `{ outer_key: { inner_key: value } }` map.
fn nested_map_from_bencode(value: BencodeValue) -> NestedStringMap {
    match value {
        // Conforming nested/flat dict shape (Clojure/cider nest dicts; babashka
        // uses flat scalars under `versions`).
        BencodeValue::Dict(outer_map) => outer_map
            .into_iter()
            .map(|(outer_key, inner)| {
                let converted_inner: BTreeMap<String, String> = match inner {
                    // Conforming nested shape: convert each inner value to a string.
                    BencodeValue::Dict(inner_map) => inner_map
                        .into_iter()
                        .map(|(k, v)| (k, v.to_string_repr()))
                        .collect(),
                    // Flat scalar value (babashka-style): wrap it so lookups for
                    // "version-string" keep working.
                    other => {
                        let mut m = BTreeMap::new();
                        m.insert("version-string".to_string(), other.to_string_repr());
                        m
                    }
                };
                (outer_key, converted_inner)
            })
            .collect(),
        // List-of-strings shape (guile-ares-rs `ops`): each entry is an op name
        // with no nested metadata.
        BencodeValue::List(items) => items
            .into_iter()
            .filter_map(|item| match item {
                BencodeValue::String(name) => Some((name, BTreeMap::new())),
                // A non-string list entry is meaningless here; drop it rather
                // than fail the whole decode.
                _ => None,
            })
            .collect(),
        // Any other scalar: surface it as a lone key so the decode still
        // succeeds and the connection stays usable.
        other => {
            let mut m = BTreeMap::new();
            m.insert(other.to_string_repr(), BTreeMap::new());
            m
        }
    }
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

    // eval errors - the spec carries the exception's class/message in `ex`,
    // and the root cause in `root-ex`. These let us surface a real error
    // instead of inferring failure from stderr text (conformance #1).
    pub ex: Option<String>,
    #[serde(rename = "root-ex")]
    pub root_ex: Option<String>,

    // middleware operations
    pub middleware: Option<Vec<String>>,
    #[serde(rename = "unresolved-middleware")]
    pub unresolved_middleware: Option<Vec<String>>,
}

/// Build a [`Response`] from an already-parsed bencode value, tolerating shapes
/// that strict serde decoding rejects.
///
/// This is the recovery path for a *structurally complete* message that
/// `serde_bencode` cannot map onto [`Response`] — typically because a
/// non-conforming server emitted an unexpected value shape somewhere in the
/// message (e.g. guile-ares-rs writes stack frames with a `source` key whose
/// value is absent, which is invalid bencode in the strict sense). Rather than
/// drop such a message — which would leave the op that's awaiting this `id`
/// hanging until its timeout — we salvage the fields we can recognise so the op
/// completes with whatever the server actually sent (the `err` text, the `ex`
/// class, the `status`, …).
///
/// Returns `None` only when the value is not a dict or carries no usable string
/// `id`: without an `id` the message cannot be routed to a waiting op, so there
/// is nothing to salvage.
pub(crate) fn response_from_bencode(value: BencodeValue) -> Option<Response> {
    let BencodeValue::Dict(mut map) = value else {
        return None;
    };

    // `id` must be a real string for the message to be routable.
    let Some(BencodeValue::String(id)) = map.remove("id") else {
        return None;
    };

    // Pull a scalar field as its string representation.
    let take_string = |map: &mut BTreeMap<String, BencodeValue>, key: &str| {
        map.remove(key).map(|v| v.to_string_repr())
    };
    // Pull a field that should be a list of strings.
    let take_string_list =
        |map: &mut BTreeMap<String, BencodeValue>, key: &str| match map.remove(key) {
            Some(BencodeValue::List(items)) => {
                Some(items.into_iter().map(|v| v.to_string_repr()).collect())
            }
            _ => None,
        };

    let status: Vec<String> = take_string_list(&mut map, "status").unwrap_or_default();
    let ops = map.remove("ops").map(nested_map_from_bencode);
    let versions = map.remove("versions").map(nested_map_from_bencode);
    let aux = match map.remove("aux") {
        Some(BencodeValue::Dict(d)) => Some(
            d.into_iter()
                .map(|(k, v)| (k, v.to_string_repr()))
                .collect(),
        ),
        _ => None,
    };
    let info = match map.remove("info") {
        Some(BencodeValue::Dict(d)) => Some(
            d.into_iter()
                .map(|(k, v)| (k, v.to_string_repr()))
                .collect(),
        ),
        _ => None,
    };

    Some(Response {
        id,
        session: take_string(&mut map, "session").unwrap_or_default(),
        status,
        value: take_string(&mut map, "value"),
        out: take_string(&mut map, "out"),
        err: take_string(&mut map, "err"),
        ns: take_string(&mut map, "ns"),
        new_session: take_string(&mut map, "new-session"),
        sessions: take_string_list(&mut map, "sessions"),
        // Structured completion candidates aren't salvaged here: completion
        // responses are well-formed in practice and never reach this path.
        completions: None,
        ops,
        versions,
        aux,
        info,
        ex: take_string(&mut map, "ex"),
        root_ex: take_string(&mut map, "root-ex"),
        middleware: take_string_list(&mut map, "middleware"),
        unresolved_middleware: take_string_list(&mut map, "unresolved-middleware"),
    })
}

/// Decoded view of an nREPL response `status` list (conformance #4).
///
/// nREPL responses carry a `status` list of short tokens. The spec defines a
/// small set that matter for control flow; this struct decodes the ones we act
/// on so callers don't hand-roll `status.iter().any(...)` checks everywhere.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
// Each field maps to a distinct, independent nREPL status token; they are not
// mutually exclusive and don't compress into an enum.
#[allow(clippy::struct_excessive_bools)]
pub struct StatusFlags {
    /// `done` - this is the final message for the request id.
    pub done: bool,
    /// `need-input` - the evaluation is blocked waiting on `stdin`.
    pub need_input: bool,
    /// `interrupted` - the evaluation was interrupted.
    pub interrupted: bool,
    /// `error` / `eval-error` / `server-error` - the operation failed.
    pub error: bool,
    /// `unknown-op` - the server does not support the requested op.
    pub unknown_op: bool,
}

/// Classify a response `status` list against the spec status set
/// (`done`, `server-error`, `need-input`, `interrupted`, `unknown-op`,
/// plus the eval `error`/`eval-error` markers).
#[must_use]
pub fn classify(status: &[String]) -> StatusFlags {
    let mut flags = StatusFlags::default();
    for s in status {
        match s.as_str() {
            "done" => flags.done = true,
            "need-input" => flags.need_input = true,
            "interrupted" => flags.interrupted = true,
            "unknown-op" => flags.unknown_op = true,
            "error" | "eval-error" | "server-error" => flags.error = true,
            _ => {}
        }
    }
    flags
}

#[derive(Debug, Clone)]
pub struct EvalResult {
    pub value: Option<String>,
    pub output: Vec<String>,
    /// Accumulated stderr lines from the server (the `err` field of responses).
    pub error: Vec<String>,
    pub ns: Option<String>,
    /// Exception class/message from the `ex`/`root-ex` fields, if the
    /// evaluation raised. Distinct from `error` (stderr text): this is set only
    /// when the server reports a genuine evaluation error (conformance #1).
    pub ex: Option<String>,
    /// True if the evaluation was interrupted (status included `interrupted`).
    pub interrupted: bool,
}

impl EvalResult {
    #[must_use]
    pub fn new() -> Self {
        Self {
            value: None,
            output: Vec::new(),
            error: Vec::new(),
            ns: None,
            ex: None,
            interrupted: false,
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

    #[test]
    fn describe_decodes_babashka_flat_versions() {
        // Babashka's `describe` sends `versions` as a *flat* map of scalar
        // strings (unlike Clojure/cider which nest a map under each key). The
        // strict nested-map shape used to fail the whole decode, which wedged
        // the streaming reader on this message. Verify the tolerant deserializer
        // accepts it and surfaces the value under `version-string`.
        //
        // Bytes captured from a live `bb nrepl-server`:
        //   {"id" "d1" "ops" {... empty dicts ...} "session" "none"
        //    "status" ["done"]
        //    "versions" {"babashka" "1.12.218" "babashka.nrepl" "0.0.6-SNAPSHOT"}}
        let bytes: &[u8] = b"d2:id2:d13:opsd9:classpathde5:clonede5:closede8:completede11:completionsde8:describede5:eldocde4:evalde4:infode9:load-filede6:lookupde11:ls-sessionsde7:ns-listdee7:session4:none6:statusl4:donee8:versionsd8:babashka8:1.12.21814:babashka.nrepl14:0.0.6-SNAPSHOTee";
        let (response, consumed) =
            crate::codec::decode_response(bytes).expect("babashka describe should decode");
        assert_eq!(consumed, bytes.len());
        assert!(response.status.iter().any(|s| s == "done"));

        let versions = response.versions.expect("versions present");
        assert_eq!(
            versions
                .get("babashka")
                .and_then(|m| m.get("version-string"))
                .map(String::as_str),
            Some("1.12.218")
        );
        assert_eq!(
            versions
                .get("babashka.nrepl")
                .and_then(|m| m.get("version-string"))
                .map(String::as_str),
            Some("0.0.6-SNAPSHOT")
        );

        // ops keys are still present (their values are empty dicts).
        let ops = response.ops.expect("ops present");
        assert!(ops.contains_key("eval"));
        assert!(ops.contains_key("describe"));
    }

    #[test]
    fn classify_recognises_spec_status_set() {
        let done = classify(&["done".to_string()]);
        assert!(done.done);
        assert!(!done.error);

        let need_input = classify(&["need-input".to_string()]);
        assert!(need_input.need_input);

        let interrupted = classify(&["done".to_string(), "interrupted".to_string()]);
        assert!(interrupted.done);
        assert!(interrupted.interrupted);

        let unknown = classify(&["done".to_string(), "unknown-op".to_string()]);
        assert!(unknown.unknown_op);

        let eval_error = classify(&["eval-error".to_string(), "done".to_string()]);
        assert!(eval_error.error);
        assert!(eval_error.done);

        let server_error = classify(&["error".to_string(), "server-error".to_string()]);
        assert!(server_error.error);

        let empty = classify(&[]);
        assert_eq!(empty, StatusFlags::default());
    }

    #[test]
    fn string_value_preserves_printed_representation() {
        // Conformance (#5): `value` is the printed representation. A string
        // result arrives already quoted and must be kept verbatim so it stays
        // distinct from a symbol of the same name.
        assert_eq!(
            BencodeValue::String("\"hello\"".to_string()).to_string_repr(),
            "\"hello\""
        );
        // A symbol/unquoted value is untouched too.
        assert_eq!(
            BencodeValue::String("hello".to_string()).to_string_repr(),
            "hello"
        );
    }
}
