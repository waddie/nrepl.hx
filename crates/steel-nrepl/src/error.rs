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

//! Error handling for Steel FFI

use steel::SteelErr;
use steel::rerrs::ErrorKind;

pub type SteelNReplResult<T> = Result<T, SteelErr>;

/// Convert nrepl_rs::NReplError to SteelErr
pub fn nrepl_error_to_steel(err: nrepl_rs::NReplError) -> SteelErr {
    SteelErr::new(ErrorKind::Generic, err.to_string())
}

/// Create a generic Steel error
pub fn steel_error(message: String) -> SteelErr {
    SteelErr::new(ErrorKind::Generic, message)
}
