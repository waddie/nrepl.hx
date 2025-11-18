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

/// Represents an nREPL session
///
/// # Security Note
///
/// Session objects can only be created through controlled paths to prevent session
/// hijacking attacks:
/// - `NReplClient::clone_session()` - Creates a new session on the server
/// - `Session::new()` - Internal constructor (crate-private) for server-provided IDs
///
/// **`Deserialize` is intentionally NOT implemented** to prevent malicious code from
/// constructing `Session` objects with arbitrary IDs from untrusted data sources
/// (config files, user input, network data). Such deserialization would enable
/// session hijacking where an attacker provides another user's session ID.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize)]
pub struct Session {
    id: String,
}

impl Session {
    pub(crate) fn new(id: impl Into<String>) -> Self {
        Self { id: id.into() }
    }

    /// Get the session ID
    pub fn id(&self) -> &str {
        &self.id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_ordering() {
        let session_a = Session::new("aaa");
        let session_b = Session::new("bbb");
        let session_c = Session::new("ccc");

        // Test PartialOrd and Ord
        assert!(session_a < session_b);
        assert!(session_b < session_c);
        assert!(session_a < session_c);
        assert!(session_b > session_a);

        // Test that sessions can be sorted
        let mut sessions = [session_c.clone(), session_a.clone(), session_b.clone()];
        sessions.sort();
        assert_eq!(sessions[0].id(), "aaa");
        assert_eq!(sessions[1].id(), "bbb");
        assert_eq!(sessions[2].id(), "ccc");
    }

    #[test]
    fn test_session_serialization() {
        let session = Session::new("test-session-123");

        // Test Serialize
        let json = serde_json::to_string(&session).expect("Failed to serialize");
        assert!(json.contains("test-session-123"));

        // Note: Deserialize is intentionally NOT implemented for security reasons
        // (prevents session hijacking via untrusted data deserialization)
    }
}
