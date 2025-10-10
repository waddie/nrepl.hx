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

//! # nREPL Client
//!
//! An async nREPL client library for Clojure.
//!
//! ## Example
//!
//! ```no_run
//! use nrepl_rs::NReplClient;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let mut client = NReplClient::connect("localhost:7888").await?;
//!     let session = client.clone_session().await?;
//!     let result = client.eval(&session, "(+ 1 2)").await?;
//!     println!("Result: {:?}", result.value);
//!     Ok(())
//! }
//! ```

mod codec;
mod connection;
mod error;
mod message;
mod ops;
mod session;

pub use connection::NReplClient;
pub use error::{NReplError, Result};
pub use message::{EvalResult, Request, Response};
pub use session::Session;

#[cfg(test)]
mod tests {
    #[test]
    fn it_compiles() {
        // Basic compilation test
        assert!(true);
    }
}
