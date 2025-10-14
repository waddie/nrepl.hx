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

//! Steel FFI wrapper for nREPL client
//!
//! This dylib exposes the nrepl-rs functionality to Steel scripting.

pub mod connection;
pub mod error;
pub mod registry;
pub mod worker;

use steel::{
    declare_module,
    steel_vm::ffi::{FFIModule, RegisterFFIFn},
};

// Export the Steel module using the declare_module! macro
declare_module!(create_module);

fn create_module() -> FFIModule {
    let mut module = FFIModule::new("steel-nrepl");

    module
        .register_fn("connect", connection::nrepl_connect)
        .register_fn("clone-session", connection::nrepl_clone_session)
        .register_fn("eval", connection::NReplSession::eval)
        .register_fn(
            "eval-with-timeout",
            connection::NReplSession::eval_with_timeout,
        )
        .register_fn("load-file", connection::NReplSession::load_file)
        .register_fn("try-get-result", connection::nrepl_try_get_result)
        .register_fn("interrupt", connection::nrepl_interrupt)
        .register_fn("close-session", connection::nrepl_close_session)
        .register_fn("stdin", connection::nrepl_stdin)
        .register_fn("completions", connection::nrepl_completions)
        .register_fn("lookup", connection::nrepl_lookup)
        .register_fn("stats", connection::nrepl_stats)
        .register_fn("close", connection::nrepl_close);

    module
}
