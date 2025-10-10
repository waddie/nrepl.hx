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

//! Callback handling and result conversion

use nrepl_rs::EvalResult;
use steel::rvals::IntoSteelVal;
use steel::SteelErr;
use steel::SteelVal;

/// Convert nREPL EvalResult to a Steel hashmap
///
/// Returns a hashmap with the following keys:
/// - value - The result value (or #f if none)
/// - output - List of output strings
/// - error - Error message (or #f if none)
/// - ns - Namespace (or #f if none)
pub fn result_to_steel_val(result: EvalResult) -> Result<SteelVal, SteelErr> {
    // Convert to a vector of key-value pairs for the hashmap
    let mut pairs = Vec::new();

    // Add value
    pairs.push((
        "value".into_steelval()?,
        result
            .value
            .map(|v| v.into_steelval())
            .transpose()?
            .unwrap_or(SteelVal::BoolV(false)),
    ));

    // Add output (list of strings)
    let output_vals: Result<Vec<SteelVal>, SteelErr> = result
        .output
        .into_iter()
        .map(|s| s.into_steelval())
        .collect();
    pairs.push(("output".into_steelval()?, output_vals?.into_steelval()?));

    // Add error
    pairs.push((
        "error".into_steelval()?,
        result
            .error
            .map(|e| e.into_steelval())
            .transpose()?
            .unwrap_or(SteelVal::BoolV(false)),
    ));

    // Add ns
    pairs.push((
        "ns".into_steelval()?,
        result
            .ns
            .map(|n| n.into_steelval())
            .transpose()?
            .unwrap_or(SteelVal::BoolV(false)),
    ));

    // Convert pairs to hashmap
    pairs.into_steelval()
}
