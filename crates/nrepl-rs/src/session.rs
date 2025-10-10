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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Session {
    pub id: String,
}

impl Session {
    pub fn new(id: impl Into<String>) -> Self {
        Self { id: id.into() }
    }
}
