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
//! This dylib exposes the nrepl-client functionality to Steel scripting.

use steel::steel_vm::engine::Engine;
use steel::steel_vm::register_fn::RegisterFn;

mod connection;
mod callback;
mod error;

use connection::*;

/// Initialize the Steel nREPL module
pub fn module() -> steel::steel_vm::ffi::FFIModule {
    let mut module = steel::steel_vm::ffi::FFIModule::new("steel-nrepl");

    module
        .register_fn("nrepl-connect!", nrepl_connect)
        .register_fn("nrepl-close!", nrepl_close)
        .register_fn("nrepl-eval!", nrepl_eval)
        .register_fn("nrepl-load-file!", nrepl_load_file)
        .register_fn("nrepl-interrupt!", nrepl_interrupt);

    module
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_compiles() {
        assert!(true);
    }
}
