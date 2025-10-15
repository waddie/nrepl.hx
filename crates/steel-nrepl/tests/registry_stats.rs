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

//! Registry stats integration test for steel-nrepl
//!
//! This test verifies that registry statistics accurately reflect connection
//! and session counts. It's separated from other integration tests because
//! it requires predictable connection counts, which is only possible when
//! running in isolation.
//!
//! **Requirements:**
//! - A running nREPL server on localhost:7888
//! - Run with: cargo test -p steel-nrepl --test registry_stats -- --ignored
//!
//! **Setup:**
//! ```sh
//! clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//! ```

use std::sync::Mutex;
use steel_nrepl::connection::{nrepl_clone_session, nrepl_close, nrepl_connect, nrepl_stats};

/// Global mutex to serialize tests that check registry stats
/// This ensures only one test accesses registry stats at a time,
/// preventing flakiness from concurrent connection creation/closure
static REGISTRY_STATS_LOCK: Mutex<()> = Mutex::new(());

/// Helper to connect to test server and return connection ID
fn connect_test_server() -> usize {
    nrepl_connect("localhost:7888".to_string()).expect("Failed to connect to test server")
}

#[test]
#[ignore]
fn test_ffi_registry_stats_accuracy() {
    // This test verifies that registry stats accurately reflect the current state
    // of connections and sessions

    // Acquire lock to ensure this test runs serially (no concurrent registry access)
    let _lock = REGISTRY_STATS_LOCK.lock().unwrap();

    // Get initial stats (should be empty or have residual connections from other tests)
    let initial_stats = nrepl_stats();

    // Create 3 connections
    let conn1 = connect_test_server();
    let conn2 = connect_test_server();
    let conn3 = connect_test_server();

    // Clone 2 sessions for conn1, 3 for conn2, 1 for conn3
    let _session1_1 = nrepl_clone_session(conn1).expect("Failed to clone session 1 for conn1");
    let _session1_2 = nrepl_clone_session(conn1).expect("Failed to clone session 2 for conn1");

    let _session2_1 = nrepl_clone_session(conn2).expect("Failed to clone session 1 for conn2");
    let _session2_2 = nrepl_clone_session(conn2).expect("Failed to clone session 2 for conn2");
    let _session2_3 = nrepl_clone_session(conn2).expect("Failed to clone session 3 for conn2");

    let _session3_1 = nrepl_clone_session(conn3).expect("Failed to clone session 1 for conn3");

    // Get stats after creating connections and sessions
    let stats = nrepl_stats();

    // Parse the stats S-expression
    // Expected format: (hash 'total-connections N 'total-sessions M 'max-connections 100
    //                        'next-conn-id X 'connections (list ...))
    assert!(
        stats.starts_with("(hash "),
        "Stats should be a hash S-expression"
    );

    // Extract total-connections
    let total_connections_str = stats
        .split("'total-connections ")
        .nth(1)
        .expect("Stats should contain 'total-connections")
        .split_whitespace()
        .next()
        .expect("Should have value after 'total-connections");
    let total_connections: usize = total_connections_str
        .parse()
        .expect("total-connections should be a number");

    // Extract total-sessions
    let total_sessions_str = stats
        .split("'total-sessions ")
        .nth(1)
        .expect("Stats should contain 'total-sessions")
        .split_whitespace()
        .next()
        .expect("Should have value after 'total-sessions");
    let total_sessions: usize = total_sessions_str
        .parse()
        .expect("total-sessions should be a number");

    // Extract max-connections
    let max_connections_str = stats
        .split("'max-connections ")
        .nth(1)
        .expect("Stats should contain 'max-connections")
        .split_whitespace()
        .next()
        .expect("Should have value after 'max-connections");
    let max_connections: usize = max_connections_str
        .parse()
        .expect("max-connections should be a number");

    // Verify counts
    // Note: We can't assert exact numbers because other tests might be running concurrently
    // or there might be residual connections. We verify that:
    // 1. We have at least 3 connections (the ones we just created)
    // 2. We have at least 6 sessions (2 + 3 + 1)
    // 3. Max connections is the expected limit

    assert!(
        total_connections >= 3,
        "Should have at least 3 connections, got {}. Initial stats: {}",
        total_connections,
        initial_stats
    );

    assert!(
        total_sessions >= 6,
        "Should have at least 6 sessions (2+3+1), got {}. Stats: {}",
        total_sessions,
        stats
    );

    assert_eq!(max_connections, 100, "Max connections should be 100");

    // Verify connection details list exists
    assert!(
        stats.contains("'connections (list"),
        "Stats should contain connections list"
    );

    // Clean up - close connections
    nrepl_close(conn1).expect("Failed to close conn1");
    nrepl_close(conn2).expect("Failed to close conn2");
    nrepl_close(conn3).expect("Failed to close conn3");

    // Get stats after cleanup
    let final_stats = nrepl_stats();

    // Parse final stats
    let final_total_connections_str = final_stats
        .split("'total-connections ")
        .nth(1)
        .expect("Final stats should contain 'total-connections")
        .split_whitespace()
        .next()
        .expect("Should have value after 'total-connections");
    let final_total_connections: usize = final_total_connections_str
        .parse()
        .expect("total-connections should be a number");

    // After closing our 3 connections, count should decrease by at least 3
    // (Could decrease by more if other tests closed connections concurrently)
    assert!(
        final_total_connections <= total_connections - 3,
        "After closing 3 connections, count should decrease by at least 3. Before: {}, After: {}, Difference: {}",
        total_connections,
        final_total_connections,
        total_connections.saturating_sub(final_total_connections)
    );

    // Verify count actually decreased (not increased)
    assert!(
        final_total_connections < total_connections,
        "Connection count should decrease after closing connections. Before: {}, After: {}",
        total_connections,
        final_total_connections
    );
}
