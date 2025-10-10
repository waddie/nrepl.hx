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

/// Error handling for Steel FFI

use steel::steel_vm::engine::Engine;
use steel::SteelErr;

pub type SteelNReplResult<T> = Result<T, SteelErr>;

impl From<nrepl_client::NReplError> for SteelErr {
    fn from(err: nrepl_client::NReplError) -> Self {
        SteelErr::new(
            steel::steel_vm::builtin::BuiltInModule::ErrorKind,
            err.to_string(),
        )
    }
}
