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

/// nREPL client connection and operations
use crate::codec::{Decoded, decode_one, encode_request};
use crate::error::{NReplError, Result};
use crate::message::classify;
use crate::message::{EvalResult, Request, Response};
use std::sync::OnceLock;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpStream, ToSocketAddrs};

/// Check if debug logging is enabled via `NREPL_DEBUG` environment variable
///
/// # Security Warning
///
/// Debug logging outputs sensitive information to stderr including:
/// - Source code being evaluated (may contain secrets, credentials, API keys)
/// - Evaluation results and output
/// - Session IDs
/// - Buffer contents in hexadecimal format
///
/// **Never enable debug logging in production.** Only use during development/debugging,
/// and ensure logs are not committed to version control or exposed to unauthorized users.
fn debug_enabled() -> bool {
    static DEBUG: OnceLock<bool> = OnceLock::new();
    *DEBUG.get_or_init(|| std::env::var("NREPL_DEBUG").is_ok())
}

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if debug_enabled() {
            eprintln!($($arg)*);
        }
    };
}

/// Maximum size for a single nREPL response message (10MB)
/// This prevents OOM attacks from malicious servers sending infinite data
const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;

/// Maximum number of incomplete read attempts before giving up (1000 reads)
/// This prevents `DoS` attacks via incomplete messages that never complete
const MAX_INCOMPLETE_READS: usize = 1000;

/// Maximum number of output entries that can be accumulated during an evaluation (10,000 entries)
/// This prevents `DoS` attacks via excessive output flooding
const MAX_OUTPUT_ENTRIES: usize = 10_000;

/// Maximum total size of all output accumulated during an evaluation (10MB)
/// This prevents memory exhaustion from massive output
const MAX_OUTPUT_TOTAL_SIZE: usize = 10 * 1024 * 1024;

/// TCP connection establishment for nREPL.
///
/// [`connect`](Self::connect) opens the socket; [`into_split`](Self::into_split)
/// hands the two halves to [`crate::worker::Worker`], which owns all protocol
/// operations. This type has no op methods by design: a single stream cannot
/// serve concurrent ops, and doing them sequentially is what made `interrupt`
/// impossible (the interrupt could not be written until the eval it was meant
/// to cancel had already finished). The worker solves that by demultiplexing
/// responses by request id, so control ops go out while an eval is in flight.
pub struct NReplClient {
    stream: TcpStream,
    buffer: Vec<u8>, // Persistent buffer for handling multiple messages in one TCP read
    incomplete_read_count: usize, // Counter to detect stuck/incomplete reads (DoS prevention)
}

impl NReplClient {
    /// Connect to an nREPL server
    ///
    /// Establishes a TCP connection to an nREPL server at the specified address.
    ///
    /// # Arguments
    ///
    /// * `addr` - The server address (e.g., "localhost:7888" or "127.0.0.1:7888")
    ///
    /// # Returns
    ///
    /// Returns a new `NReplClient` instance if the connection succeeds.
    ///
    /// # Errors
    ///
    /// Returns `NReplError::Connection` if the connection fails (e.g., server not running,
    /// invalid address, network error).
    ///
    /// Callers outside the crate go through [`crate::worker::Worker`], which
    /// calls this and then [`into_split`](Self::into_split) on its own thread.
    pub async fn connect(addr: impl ToSocketAddrs) -> Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Self {
            stream,
            buffer: Vec::new(),
            incomplete_read_count: 0,
        })
    }

    /// Split this client into an independent writer and reader over the same
    /// TCP connection.
    ///
    /// This is the foundation of the demux model: an interrupt (or stdin) can be
    /// *written* through [`NReplWriter`] while [`NReplReader`] is parked
    /// accumulating an eval's responses. The reader inherits the client's
    /// in-progress decode buffer so no buffered bytes are lost.
    ///
    /// The caller is responsible for session lifecycle and id minting (use
    /// [`crate::ops::wire_id`]); [`crate::worker::Worker`] does both.
    pub fn into_split(self) -> (NReplWriter, NReplReader) {
        let NReplClient {
            stream,
            buffer,
            incomplete_read_count,
            ..
        } = self;

        let (read_half, write_half) = stream.into_split();
        (
            NReplWriter { stream: write_half },
            NReplReader {
                stream: read_half,
                buffer,
                incomplete_read_count,
            },
        )
    }
}

/// Read a single bencode response from any async byte stream, using a
/// persistent decode buffer to handle messages split across (or batched into)
/// TCP reads.
///
/// Enforces the `MAX_RESPONSE_SIZE` and `MAX_INCOMPLETE_READS` protections.
///
/// Note that for a single large streamed response `MAX_INCOMPLETE_READS`
/// (1000 top-ups of 4KB) is reached at roughly 4MB, well before
/// `MAX_RESPONSE_SIZE`, so it is the guard that actually fires.
async fn read_one_response<R: AsyncRead + Unpin>(
    stream: &mut R,
    buffer: &mut Vec<u8>,
    incomplete_read_count: &mut usize,
) -> Result<Response> {
    // Bencode messages are self-delimiting. We use a persistent buffer to handle
    // cases where multiple messages arrive in a single TCP read.

    let mut temp_buf = [0u8; 4096];

    loop {
        // First, try to decode from existing buffer data
        if !buffer.is_empty() {
            match decode_one(buffer) {
                Decoded::Message { response, consumed } => {
                    debug_log!(
                        "[nREPL DEBUG] Successfully decoded response (consumed {} of {} bytes in buffer)",
                        consumed,
                        buffer.len()
                    );
                    // Remove the consumed bytes, keep the rest for next read
                    buffer.drain(..consumed);
                    debug_log!(
                        "[nREPL DEBUG] Buffer now has {} bytes remaining",
                        buffer.len()
                    );
                    // Reset incomplete read counter on success
                    *incomplete_read_count = 0;
                    return Ok(*response);
                }
                Decoded::Malformed { consumed, message } => {
                    // A *complete* message we cannot deserialize (a non-conforming
                    // server sent an unexpected value shape). Retrying would fail
                    // identically forever and wedge the reader - every later
                    // response queues up behind these bytes and never decodes.
                    // Skip the bad message and carry on so the connection stays
                    // usable; the op awaiting this id will simply time out.
                    debug_log!(
                        "[nREPL DEBUG] Skipping undecodable response ({} bytes): {}",
                        consumed,
                        message
                    );
                    buffer.drain(..consumed);
                    *incomplete_read_count = 0;
                    continue;
                }
                Decoded::Incomplete => {
                    // Incomplete message, need to read more data
                    *incomplete_read_count += 1;
                    debug_log!(
                        "[nREPL DEBUG] Incomplete message in buffer ({} bytes), reading more... (attempt {}/{})",
                        buffer.len(),
                        *incomplete_read_count,
                        MAX_INCOMPLETE_READS
                    );

                    // Check if we've exceeded the maximum incomplete reads
                    if *incomplete_read_count > MAX_INCOMPLETE_READS {
                        return Err(NReplError::protocol(format!(
                            "Too many incomplete reads ({} attempts), possible incomplete/malformed message",
                            *incomplete_read_count
                        )));
                    }

                    // Only format buffer contents if debug logging is enabled
                    if debug_enabled() {
                        // Show first 200 bytes as hex for debugging
                        let preview_len = buffer.len().min(200);
                        let hex: String = buffer[..preview_len]
                            .iter()
                            .map(|b| format!("{b:02x}"))
                            .collect::<Vec<_>>()
                            .join(" ");
                        eprintln!("[nREPL DEBUG] Buffer hex (first {preview_len} bytes): {hex}");
                        // Also show as string (replacing non-printable with .)
                        let ascii: String = buffer[..preview_len]
                            .iter()
                            .map(|&b| {
                                if (32..127).contains(&b) {
                                    b as char
                                } else {
                                    '.'
                                }
                            })
                            .collect();
                        eprintln!(
                            "[nREPL DEBUG] Buffer ASCII (first {preview_len} bytes): {ascii}"
                        );
                    }
                }
            }
        }

        // Read more data from the stream
        debug_log!("[nREPL DEBUG] Waiting for data from stream...");
        let n = stream.read(&mut temp_buf).await?;
        debug_log!("[nREPL DEBUG] Read {} bytes from stream", n);

        if n == 0 {
            return Err(NReplError::Connection(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "connection closed",
            )));
        }

        // Check buffer size BEFORE appending to prevent exceeding MAX_RESPONSE_SIZE
        if buffer.len() + n > MAX_RESPONSE_SIZE {
            return Err(NReplError::protocol(format!(
                "Response would exceed maximum size of {} bytes (current: {}, adding: {})",
                MAX_RESPONSE_SIZE,
                buffer.len(),
                n
            )));
        }

        buffer.extend_from_slice(&temp_buf[..n]);
    }
}

/// Write half of a split nREPL connection.
///
/// Holds the owned write half of the TCP stream so a control op (interrupt,
/// stdin) can be written while the [`NReplReader`] is parked reading.
pub struct NReplWriter {
    stream: OwnedWriteHalf,
}

impl NReplWriter {
    /// Encode and send a request, flushing the stream.
    ///
    /// # Errors
    ///
    /// Returns an error if encoding the request fails or the stream cannot be written.
    pub async fn send(&mut self, request: &Request) -> Result<()> {
        let encoded = encode_request(request)?;
        debug_log!(
            "[nREPL DEBUG] WROTE request op={} id={} ({} bytes)",
            request.op,
            request.id,
            encoded.len()
        );
        self.stream.write_all(&encoded).await?;
        self.stream.flush().await?;
        debug_log!("[nREPL DEBUG] flushed request id={}", request.id);
        Ok(())
    }
}

/// Read half of a split nREPL connection.
///
/// Carries the in-progress decode buffer and incomplete-read counter so
/// splitting a client mid-stream loses no buffered bytes.
pub struct NReplReader {
    stream: OwnedReadHalf,
    buffer: Vec<u8>,
    incomplete_read_count: usize,
}

impl NReplReader {
    /// Read and decode the next bencode response from the connection.
    ///
    /// # Errors
    ///
    /// Returns an error if the connection is closed, a read times out, or the
    /// response cannot be decoded.
    pub async fn next_response(&mut self) -> Result<Response> {
        read_one_response(
            &mut self.stream,
            &mut self.buffer,
            &mut self.incomplete_read_count,
        )
        .await
    }
}

/// Accumulates the responses of a single eval/load-file request into an
/// [`EvalResult`], applying the same backpressure limits as the legacy path.
///
/// Reusable by both the legacy `&mut self` accumulate loop and the worker's
/// demux event loop: feed each routed response through [`push`](Self::push),
/// stop when [`is_done`](Self::is_done) is true, then take the result with
/// [`finish`](Self::finish).
pub struct EvalAccumulator {
    result: EvalResult,
    // Combined size of stdout + stderr accumulated so far (MAX_OUTPUT_TOTAL_SIZE).
    total_output_size: usize,
    done: bool,
}

impl EvalAccumulator {
    #[must_use]
    pub fn new() -> Self {
        Self {
            result: EvalResult::new(),
            total_output_size: 0,
            done: false,
        }
    }

    /// Fold one response (already known to belong to this request) into the
    /// result. Returns an error if a backpressure limit is exceeded.
    ///
    /// # Errors
    ///
    /// Returns an error if a backpressure limit (output size or message count) is exceeded.
    pub fn push(&mut self, response: Response) -> Result<()> {
        // Accumulate stdout output with backpressure limits
        if let Some(out) = response.out {
            if self.result.output.len() >= MAX_OUTPUT_ENTRIES {
                return Err(NReplError::protocol(format!(
                    "Output exceeded maximum entries limit ({MAX_OUTPUT_ENTRIES} entries)"
                )));
            }
            let out_size = out.len();
            if self.total_output_size + out_size > MAX_OUTPUT_TOTAL_SIZE {
                return Err(NReplError::protocol(format!(
                    "Output exceeded maximum total size of {} bytes ({} MB)",
                    MAX_OUTPUT_TOTAL_SIZE,
                    MAX_OUTPUT_TOTAL_SIZE / (1024 * 1024)
                )));
            }
            self.total_output_size += out_size;
            self.result.output.push(out);
        }

        // Accumulate stderr errors with backpressure limits
        if let Some(err) = response.err {
            if self.result.error.len() >= MAX_OUTPUT_ENTRIES {
                return Err(NReplError::protocol(format!(
                    "Error output exceeded maximum entries limit ({MAX_OUTPUT_ENTRIES} entries)"
                )));
            }
            let err_size = err.len();
            if self.total_output_size + err_size > MAX_OUTPUT_TOTAL_SIZE {
                return Err(NReplError::protocol(format!(
                    "Error output exceeded maximum total size of {} bytes ({} MB)",
                    MAX_OUTPUT_TOTAL_SIZE,
                    MAX_OUTPUT_TOTAL_SIZE / (1024 * 1024)
                )));
            }
            self.total_output_size += err_size;
            self.result.error.push(err);
        }

        // Capture value (last one wins)
        if let Some(value) = response.value {
            self.result.value = Some(value);
        }

        // Capture namespace (last one wins)
        if let Some(ns) = response.ns {
            self.result.ns = Some(ns);
        }

        // Capture explicit exception info (conformance #1). Prefer `ex`, fall
        // back to `root-ex` if only that is present.
        if let Some(ex) = response.ex {
            self.result.ex = Some(ex);
        } else if let Some(root_ex) = response.root_ex {
            self.result.ex = Some(root_ex);
        }

        // Decode status (conformance #4)
        let flags = classify(&response.status);
        if flags.interrupted {
            self.result.interrupted = true;
        }
        if flags.done {
            self.done = true;
        }

        Ok(())
    }

    /// Consume the accumulator, returning the assembled result.
    #[must_use]
    pub fn finish(self) -> EvalResult {
        self.result
    }

    /// Take the stdout/stderr accumulated so far, leaving the accumulator empty
    /// of it (so a later [`finish`](Self::finish) only returns output produced
    /// after this point). Used at a `need-input` pause to flush partial output
    /// without double-counting it at `done`. `value`/`ns`/`ex`/`done` are
    /// untouched - only stdout/stderr drain.
    pub fn drain_output(&mut self) -> (Vec<String>, Vec<String>) {
        self.total_output_size = 0;
        (
            std::mem::take(&mut self.result.output),
            std::mem::take(&mut self.result.error),
        )
    }
}

impl Default for EvalAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for NReplClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NReplClient")
            .field("buffer_size", &self.buffer.len())
            .field("incomplete_read_count", &self.incomplete_read_count)
            .finish_non_exhaustive()
    }
}
