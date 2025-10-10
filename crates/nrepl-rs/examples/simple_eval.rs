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

//! Simple example demonstrating nREPL client usage
//!
//! Start an nREPL server first:
//! ```bash
//! clj -Sdeps '{:deps {nrepl/nrepl {:mvn/version "1.1.0"}}}' -M -m nrepl.cmdline --port 7888
//! ```
//!
//! Then run this example:
//! ```bash
//! cargo run -p nrepl-rs --example simple_eval
//! ```

use nrepl_rs::{NReplClient, Result};

#[tokio::main]
async fn main() -> Result<()> {
    println!("Connecting to nREPL server at localhost:7888...");
    let mut client = NReplClient::connect("localhost:7888").await?;
    println!("✓ Connected");

    println!("\nCloning session...");
    let session = client.clone_session().await?;
    println!("✓ Session created: {}", session.id);

    println!("\nEvaluating: (+ 1 2)");
    let result = client.eval(&session, "(+ 1 2)").await?;
    println!("✓ Result: {:?}", result.value);

    println!("\nEvaluating with output: (do (println \"Hello from nREPL!\") (+ 10 20))");
    let result = client
        .eval(&session, r#"(do (println "Hello from nREPL!") (+ 10 20))"#)
        .await?;
    println!("✓ Output: {:?}", result.output);
    println!("✓ Result: {:?}", result.value);

    println!("\nDefining a variable: (def my-number 42)");
    let result = client.eval(&session, "(def my-number 42)").await?;
    println!("✓ Result: {:?}", result.value);

    println!("\nUsing the defined variable: (* my-number 2)");
    let result = client.eval(&session, "(* my-number 2)").await?;
    println!("✓ Result: {:?}", result.value);

    println!("\n✓ All examples completed successfully!");

    Ok(())
}
