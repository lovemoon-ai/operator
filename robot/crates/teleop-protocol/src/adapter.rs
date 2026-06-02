//! The bridge<->adapter boundary protocol.
//!
//! Two processes — `xr-bridge` and `robot-adapter` — exchange self-describing
//! JSON frames over a local connection (UDS or TCP, see [`crate::transport`]).
//!
//! Frame format on the wire:
//!
//! ```text
//! [4B len LE] [len bytes: JSON]
//! ```
//!
//! Each direction has its own message enum, and each side uses the codec named
//! for it: the bridge uses [`BridgeCodec`] (it *encodes* [`BridgeToAdapter`] and
//! *decodes* [`AdapterToBridge`]); the adapter uses [`AdapterCodec`] (the
//! mirror image). Both codecs share the private length-delimited framing below,
//! so they interoperate byte-for-byte.

use bytes::{Buf, BufMut, BytesMut};
use serde::{de::DeserializeOwned, Serialize};
use tokio_util::codec::{Decoder, Encoder};

use crate::descriptor::DeviceDescriptor;
use crate::wire::{DeviceCommand, DeviceTelemetry};

/// Maximum allowed frame length (16 MiB). A length prefix larger than this is
/// treated as protocol corruption and rejected with `InvalidData`.
pub const MAX_FRAME_LEN: usize = 16 * 1024 * 1024;

/// Messages flowing from the bridge to the adapter.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type")]
pub enum BridgeToAdapter {
    /// Initial handshake from the bridge.
    Hello,
    /// A control command destined for the device.
    Command(DeviceCommand),
    /// Ask the adapter to safe the device immediately (watchdog / E-stop).
    Stop { reason: String },
    /// Tell the adapter to shut down cleanly.
    Shutdown,
}

/// Messages flowing from the adapter back to the bridge.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type")]
pub enum AdapterToBridge {
    /// The adapter's device self-description (sent on connect).
    Descriptor(DeviceDescriptor),
    /// Periodic telemetry from the device.
    Telemetry(DeviceTelemetry),
    /// An out-of-band event/log line (e.g. a warning or state change).
    Event { kind: String, msg: String },
}

// ---------------------------------------------------------------------------
// Private length-delimited JSON framing shared by both codecs.
// ---------------------------------------------------------------------------

/// Encode `item` as `[4B len LE][JSON]` into `dst`.
fn encode_framed<T: Serialize>(item: &T, dst: &mut BytesMut) -> Result<(), std::io::Error> {
    let json = serde_json::to_vec(item)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    if json.len() > MAX_FRAME_LEN {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame length {} exceeds maximum {MAX_FRAME_LEN}", json.len()),
        ));
    }
    dst.reserve(4 + json.len());
    dst.put_u32_le(json.len() as u32);
    dst.put_slice(&json);
    Ok(())
}

/// Try to decode one `[4B len LE][JSON]` frame from `src`.
///
/// Returns `Ok(None)` when the buffer does not yet hold a full frame (partial
/// reads), and only consumes bytes when a complete frame is decoded.
fn decode_framed<T: DeserializeOwned>(
    src: &mut BytesMut,
) -> Result<Option<T>, std::io::Error> {
    // Need the 4-byte length prefix first.
    if src.len() < 4 {
        return Ok(None);
    }

    let len = u32::from_le_bytes(src[0..4].try_into().unwrap()) as usize;
    if len > MAX_FRAME_LEN {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame length {len} exceeds maximum {MAX_FRAME_LEN}"),
        ));
    }

    let total = 4 + len;
    if src.len() < total {
        // Reserve so tokio-util knows how much more to read.
        src.reserve(total - src.len());
        return Ok(None);
    }

    // Complete frame — consume it.
    src.advance(4);
    let json = src.split_to(len);
    let item = serde_json::from_slice(&json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    Ok(Some(item))
}

// ---------------------------------------------------------------------------
// Typed codecs (the bridge side).
// ---------------------------------------------------------------------------

/// Codec used by the **bridge** side of the connection.
///
/// Encodes [`BridgeToAdapter`] (what the bridge sends) and decodes
/// [`AdapterToBridge`] (what it receives).
#[derive(Debug, Clone, Copy, Default)]
pub struct BridgeCodec;

impl Encoder<BridgeToAdapter> for BridgeCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: BridgeToAdapter, dst: &mut BytesMut) -> Result<(), Self::Error> {
        encode_framed(&item, dst)
    }
}

impl Decoder for BridgeCodec {
    type Item = AdapterToBridge;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        decode_framed(src)
    }
}

// ---------------------------------------------------------------------------
// Typed codecs (the adapter side).
// ---------------------------------------------------------------------------

/// Codec used by the **adapter** side of the connection.
///
/// Encodes [`AdapterToBridge`] (what the adapter sends) and decodes
/// [`BridgeToAdapter`] (what it receives).
#[derive(Debug, Clone, Copy, Default)]
pub struct AdapterCodec;

impl Encoder<AdapterToBridge> for AdapterCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: AdapterToBridge, dst: &mut BytesMut) -> Result<(), Self::Error> {
        encode_framed(&item, dst)
    }
}

impl Decoder for AdapterCodec {
    type Item = BridgeToAdapter;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        decode_framed(src)
    }
}
