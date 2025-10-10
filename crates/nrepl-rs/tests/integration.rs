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

//! Integration tests for nrepl-rs
//!
//! These tests require a running Clojure nREPL server.
//!
//! To run:
//! 1. Start nREPL server:
//!    clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//!
//! 2. Run tests:
//!    cargo test -p nrepl-rs --test integration -- --test-threads=1

// These tests are ignored by default since they require external setup
// Run with: cargo test -p nrepl-rs -- --ignored

#[cfg(test)]
mod real_server_tests {
    // TODO: Add integration tests once connection implementation is ready

    #[test]
    #[ignore]
    fn test_connect_to_real_server() {
        // This will be implemented after the connection module is complete
        todo!("Implement real server connection test");
    }
}
