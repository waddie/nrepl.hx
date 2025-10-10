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

/// Callback handling for async operations

use steel::rvals::SteelVal;

/// Schedule a Steel callback to run on the main thread
/// This is critical for thread safety - Steel must only be called from the main thread
pub fn schedule_steel_callback(callback: SteelVal, result: nrepl_client::EvalResult) {
    // TODO: Implement callback scheduling using Helix's enqueue mechanism
    // helix::commands::engine::steel::enqueue_thread_local_callback(...)
    todo!("Implement schedule_steel_callback")
}

/// Convert nREPL result to Steel value
pub fn result_to_steel_val(result: nrepl_client::EvalResult) -> SteelVal {
    // TODO: Convert Result to appropriate Steel data structure
    // Probably a hash map with :value, :output, :error, :ns keys
    todo!("Implement result_to_steel_val")
}
