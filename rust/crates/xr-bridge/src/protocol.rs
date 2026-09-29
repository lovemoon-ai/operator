//! Binary protocol codecs for the XR (headset) wire protocol.
//!
//! Copied verbatim (byte-level) from `robot/src/network/protocol.rs` during the
//! bridge/adapter split. These codecs are type-agnostic — they frame raw
//! command/video bytes and decode the UDP pose packet — so nothing here depends
//! on the device-command types; the bridge layers `teleop_protocol::DeviceCommand`
//! on top by `serde_json`-decoding the `CommandFrame.data`.
//!
//! Two distinct frame formats are used:
//!
//! - **Command frames** (pose/control channel, port 63901):
//!   `[4B cmd_len LE][cmd UTF-8][4B data_len LE][data]`
//!   Compatible with `NetworkDataProtocolSerializer.cs`.
//!
//! - **Video frames** (video channel, port 12345):
//!   Legacy raw NAL packet: `[4B len BE][H.264 NAL unit]`
//!   Timed packet with per-stage timestamps (see [`TimedVideoFrame`]).
//!   The raw packet stays available for ffplay preview; the timed packet is
//!   used by the robot video pipeline and XR latency logging.

use bytes::{Buf, BufMut, BytesMut};
use tokio_util::codec::{Decoder, Encoder};

// ---------------------------------------------------------------------------
// Command protocol (little-endian lengths)
// ---------------------------------------------------------------------------

/// A single command frame as sent by the XR headset.
#[derive(Debug, Clone)]
pub struct CommandFrame {
    /// Command name (e.g. "Tracking", "Heartbeat", "Function").
    pub command: String,
    /// Payload bytes (usually UTF-8 JSON, but treated as opaque).
    pub data: Vec<u8>,
}

/// Codec for the command protocol.
///
/// Wire format (all lengths are **little-endian signed i32**):
/// ```text
/// [4B cmd_len LE] [cmd_len bytes: UTF-8 command] [4B data_len LE] [data_len bytes: payload]
/// ```
pub struct CommandCodec;

/// Maximum allowed command string length (64 KiB). Prevents OOM on garbage.
const MAX_CMD_LEN: usize = 64 * 1024;
/// Maximum allowed data payload length (16 MiB).
const MAX_DATA_LEN: usize = 16 * 1024 * 1024;

impl Decoder for CommandCodec {
    type Item = CommandFrame;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        // Need at least 4 bytes for cmd_len.
        if src.len() < 4 {
            return Ok(None);
        }

        let cmd_len = i32::from_le_bytes(src[0..4].try_into().unwrap()) as usize;
        if cmd_len > MAX_CMD_LEN {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("command length {cmd_len} exceeds maximum {MAX_CMD_LEN}"),
            ));
        }

        // Need cmd_len + second length field.
        if src.len() < 4 + cmd_len + 4 {
            return Ok(None);
        }

        let data_len =
            i32::from_le_bytes(src[4 + cmd_len..4 + cmd_len + 4].try_into().unwrap()) as usize;
        if data_len > MAX_DATA_LEN {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("data length {data_len} exceeds maximum {MAX_DATA_LEN}"),
            ));
        }

        let total = 4 + cmd_len + 4 + data_len;
        if src.len() < total {
            // Reserve space so tokio-util knows how much more to read.
            src.reserve(total - src.len());
            return Ok(None);
        }

        // We have a complete frame — consume it.
        src.advance(4); // skip cmd_len field
        let command = String::from_utf8_lossy(&src.split_to(cmd_len)).into_owned();
        src.advance(4); // skip data_len field
        let data = src.split_to(data_len).to_vec();

        Ok(Some(CommandFrame { command, data }))
    }
}

impl Encoder<CommandFrame> for CommandCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: CommandFrame, dst: &mut BytesMut) -> Result<(), Self::Error> {
        let cmd_bytes = item.command.as_bytes();
        dst.reserve(4 + cmd_bytes.len() + 4 + item.data.len());
        dst.put_i32_le(cmd_bytes.len() as i32);
        dst.put_slice(cmd_bytes);
        dst.put_i32_le(item.data.len() as i32);
        dst.put_slice(&item.data);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Video protocol (big-endian lengths)
// ---------------------------------------------------------------------------

/// Codec for the H.264 video stream.
///
/// Wire format: `[4B NAL length, big-endian u32][NAL payload]`
pub struct VideoFrameCodec;

/// Video pipeline mode stored in timed packets.
pub const VIDEO_PIPELINE_MODE_V4L2_HW: u32 = 0;
pub const VIDEO_PIPELINE_MODE_FFMPEG: u32 = 1;

/// Maximum NAL unit size (10 MiB).
const MAX_NAL_SIZE: usize = 10 * 1024 * 1024;

impl Decoder for VideoFrameCodec {
    type Item = Vec<u8>;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        if src.len() < 4 {
            return Ok(None);
        }

        let nal_size = u32::from_be_bytes(src[0..4].try_into().unwrap()) as usize;
        if nal_size > MAX_NAL_SIZE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("NAL unit size {nal_size} exceeds maximum {MAX_NAL_SIZE}"),
            ));
        }

        if src.len() < 4 + nal_size {
            src.reserve(4 + nal_size - src.len());
            return Ok(None);
        }

        src.advance(4);
        Ok(Some(src.split_to(nal_size).to_vec()))
    }
}

impl Encoder<Vec<u8>> for VideoFrameCodec {
    type Error = std::io::Error;

    fn encode(&mut self, nal: Vec<u8>, dst: &mut BytesMut) -> Result<(), Self::Error> {
        dst.reserve(4 + nal.len());
        dst.put_u32(nal.len() as u32); // big-endian
        dst.put_slice(&nal);
        Ok(())
    }
}

/// A timed H.264 packet with per-stage timestamps.
#[derive(Debug, Clone)]
pub struct TimedVideoFrame {
    /// Monotonically increasing frame identifier.
    pub frame_id: u64,
    /// Index of this NAL within the frame.
    pub nal_index: u32,
    /// Total NAL count for this frame.
    pub nal_count: u32,
    /// Which capture/encode pipeline produced the packet.
    pub pipeline_mode: u32,
    /// Wall-clock timestamp when capture started.
    pub capture_start_ns: u64,
    /// Wall-clock timestamp when capture completed.
    pub capture_end_ns: u64,
    /// Wall-clock timestamp when encoding started.
    pub encode_start_ns: u64,
    /// Wall-clock timestamp when encoding completed.
    pub encode_end_ns: u64,
    /// Time spent blocked waiting for ffmpeg output.
    pub read_wait_ns: u64,
    /// Time spent parsing ffmpeg output into NALs.
    pub parse_ns: u64,
    /// Wall-clock timestamp when the packet was handed to the socket.
    pub send_ns: u64,
    /// Raw H.264 Annex B NAL payload.
    pub nal: Vec<u8>,
}

impl TimedVideoFrame {
    /// Helper used by the socket writer to stamp the actual send time.
    pub fn with_send_ns(mut self, send_ns: u64) -> Self {
        self.send_ns = send_ns;
        self
    }
}

/// Codec for the timed H.264 packet format used by the robot video pipeline.
pub struct TimedVideoFrameCodec;

/// Fixed header size of a timed frame.
pub const TIMED_VIDEO_HEADER_BYTES: usize = 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8 + 4;

impl Decoder for TimedVideoFrameCodec {
    type Item = TimedVideoFrame;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        if src.len() < TIMED_VIDEO_HEADER_BYTES {
            return Ok(None);
        }

        let frame_id = u64::from_be_bytes(src[0..8].try_into().unwrap());
        let nal_index = u32::from_be_bytes(src[8..12].try_into().unwrap());
        let nal_count = u32::from_be_bytes(src[12..16].try_into().unwrap());
        let pipeline_mode = u32::from_be_bytes(src[16..20].try_into().unwrap());
        let capture_start_ns = u64::from_be_bytes(src[20..28].try_into().unwrap());
        let capture_end_ns = u64::from_be_bytes(src[28..36].try_into().unwrap());
        let encode_start_ns = u64::from_be_bytes(src[36..44].try_into().unwrap());
        let encode_end_ns = u64::from_be_bytes(src[44..52].try_into().unwrap());
        let read_wait_ns = u64::from_be_bytes(src[52..60].try_into().unwrap());
        let parse_ns = u64::from_be_bytes(src[60..68].try_into().unwrap());
        let send_ns = u64::from_be_bytes(src[68..76].try_into().unwrap());
        let nal_len = u32::from_be_bytes(src[76..80].try_into().unwrap()) as usize;

        if nal_len > MAX_NAL_SIZE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("NAL unit size {nal_len} exceeds maximum {MAX_NAL_SIZE}"),
            ));
        }

        if src.len() < TIMED_VIDEO_HEADER_BYTES + nal_len {
            src.reserve(TIMED_VIDEO_HEADER_BYTES + nal_len - src.len());
            return Ok(None);
        }

        src.advance(TIMED_VIDEO_HEADER_BYTES);
        let nal = src.split_to(nal_len).to_vec();

        Ok(Some(TimedVideoFrame {
            frame_id,
            nal_index,
            nal_count,
            pipeline_mode,
            capture_start_ns,
            capture_end_ns,
            encode_start_ns,
            encode_end_ns,
            read_wait_ns,
            parse_ns,
            send_ns,
            nal,
        }))
    }
}

impl Encoder<TimedVideoFrame> for TimedVideoFrameCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: TimedVideoFrame, dst: &mut BytesMut) -> Result<(), Self::Error> {
        dst.reserve(TIMED_VIDEO_HEADER_BYTES + item.nal.len());
        dst.put_u64(item.frame_id);
        dst.put_u32(item.nal_index);
        dst.put_u32(item.nal_count);
        dst.put_u32(item.pipeline_mode);
        dst.put_u64(item.capture_start_ns);
        dst.put_u64(item.capture_end_ns);
        dst.put_u64(item.encode_start_ns);
        dst.put_u64(item.encode_end_ns);
        dst.put_u64(item.read_wait_ns);
        dst.put_u64(item.parse_ns);
        dst.put_u64(item.send_ns);
        dst.put_u32(item.nal.len() as u32);
        dst.put_slice(&item.nal);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// UDP pose packet (data-plane)
// ---------------------------------------------------------------------------
//
// Wire format (all little-endian, 32 B fixed header + variable payload):
//
//   offset  size  field
//   0       8     t_xr_send_ns         u64  (XR-side wall clock at send)
//   8       8     seq                  u64  (monotonic per XR session)
//   16      4     session_token        u32  (0 = anonymous / dev mode)
//   20      2     descriptor_version   u16  (0 = unknown / not enforced)
//   22      2     payload_len          u16  (bytes after the header)
//   24      2     crc16                u16  (CRC-16/CCITT-FALSE over payload)
//   26      1     flags                u8   (bit0=keyframe, bit1=hold_request)
//   27      1     reserved             u8
//   28      4     payload_kind         4 ASCII bytes ("POSE", "AXIS", ...)
//   32      …     payload              binary, little-endian floats
//
// The "POSE" payload is 64 bytes: 3 × f64 position + 4 × f64 rotation + 1 × f64
// gripper. Other kinds will be added as needed.

/// Fixed UDP header size.
pub const POSE_UDP_HEADER_SIZE: usize = 32;
/// Size of a `POSE` payload.
pub const POSE_UDP_POSE_PAYLOAD_SIZE: usize = 8 * 8;
/// Total size of a `POSE` packet.
pub const POSE_UDP_POSE_PACKET_SIZE: usize = POSE_UDP_HEADER_SIZE + POSE_UDP_POSE_PAYLOAD_SIZE;

/// Payload kind tag for end-effector pose + gripper.
pub const POSE_UDP_KIND_POSE: [u8; 4] = *b"POSE";

/// Decoded UDP pose packet.
#[derive(Debug, Clone)]
pub struct PoseUdpPacket {
    pub t_xr_send_ns: u64,
    pub seq: u64,
    pub session_token: u32,
    pub descriptor_version: u16,
    pub flags: u8,
    pub kind: [u8; 4],
    pub payload: PoseUdpPayload,
}

/// Strongly-typed payload variants. Right now only `Pose` exists.
#[derive(Debug, Clone)]
pub enum PoseUdpPayload {
    /// End-effector pose + gripper. The XR client packs whatever it
    /// considers the active control input here.
    Pose {
        position: [f64; 3],
        rotation: [f64; 4],
        gripper: f64,
    },
}

/// CRC-16/CCITT-FALSE (poly=0x1021, init=0xFFFF, no reflection, xorout=0).
/// 10-line implementation — no external crate.
#[inline]
pub fn crc16_ccitt(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

/// Errors returned by [`PoseUdpPacket::decode`].
#[derive(Debug, thiserror::Error)]
pub enum PoseUdpDecodeError {
    #[error("packet too short: {got} bytes < {need}")]
    TooShort { got: usize, need: usize },
    #[error("crc mismatch: header=0x{header:04x}, computed=0x{computed:04x}")]
    CrcMismatch { header: u16, computed: u16 },
    #[error("unknown payload kind {kind:?}")]
    UnknownKind { kind: [u8; 4] },
    #[error("payload_len {got} != expected {expected} for kind {kind:?}")]
    PayloadLenMismatch {
        got: usize,
        expected: usize,
        kind: [u8; 4],
    },
}

impl PoseUdpPacket {
    /// Encode this packet into a freshly allocated `Vec<u8>`. CRC is
    /// computed over `payload` and written into the header.
    pub fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(POSE_UDP_HEADER_SIZE + POSE_UDP_POSE_PAYLOAD_SIZE);
        // --- payload first (so we can CRC it) ---
        match &self.payload {
            PoseUdpPayload::Pose {
                position,
                rotation,
                gripper,
            } => {
                let mut payload = Vec::with_capacity(POSE_UDP_POSE_PAYLOAD_SIZE);
                for v in position
                    .iter()
                    .chain(rotation.iter())
                    .chain(std::iter::once(gripper))
                {
                    payload.extend_from_slice(&v.to_le_bytes());
                }
                let crc = crc16_ccitt(&payload);
                buf.extend_from_slice(&self.t_xr_send_ns.to_le_bytes());
                buf.extend_from_slice(&self.seq.to_le_bytes());
                buf.extend_from_slice(&self.session_token.to_le_bytes());
                buf.extend_from_slice(&self.descriptor_version.to_le_bytes());
                buf.extend_from_slice(&(payload.len() as u16).to_le_bytes());
                buf.extend_from_slice(&crc.to_le_bytes());
                buf.push(self.flags);
                buf.push(0); // reserved
                buf.extend_from_slice(&self.kind);
                buf.extend_from_slice(&payload);
            }
        }
        buf
    }

    /// Decode a UDP datagram, validating CRC and payload length.
    pub fn decode(data: &[u8]) -> Result<Self, PoseUdpDecodeError> {
        if data.len() < POSE_UDP_HEADER_SIZE {
            return Err(PoseUdpDecodeError::TooShort {
                got: data.len(),
                need: POSE_UDP_HEADER_SIZE,
            });
        }
        let t_xr_send_ns = u64::from_le_bytes(data[0..8].try_into().unwrap());
        let seq = u64::from_le_bytes(data[8..16].try_into().unwrap());
        let session_token = u32::from_le_bytes(data[16..20].try_into().unwrap());
        let descriptor_version = u16::from_le_bytes(data[20..22].try_into().unwrap());
        let payload_len = u16::from_le_bytes(data[22..24].try_into().unwrap()) as usize;
        let crc_header = u16::from_le_bytes(data[24..26].try_into().unwrap());
        let flags = data[26];
        // data[27] reserved
        let kind: [u8; 4] = data[28..32].try_into().unwrap();

        let total = POSE_UDP_HEADER_SIZE + payload_len;
        if data.len() < total {
            return Err(PoseUdpDecodeError::TooShort {
                got: data.len(),
                need: total,
            });
        }
        let payload_bytes = &data[POSE_UDP_HEADER_SIZE..total];

        let crc_computed = crc16_ccitt(payload_bytes);
        if crc_computed != crc_header {
            return Err(PoseUdpDecodeError::CrcMismatch {
                header: crc_header,
                computed: crc_computed,
            });
        }

        let payload = match kind {
            POSE_UDP_KIND_POSE => {
                if payload_len != POSE_UDP_POSE_PAYLOAD_SIZE {
                    return Err(PoseUdpDecodeError::PayloadLenMismatch {
                        got: payload_len,
                        expected: POSE_UDP_POSE_PAYLOAD_SIZE,
                        kind,
                    });
                }
                let mut floats = [0f64; 8];
                for (i, slot) in floats.iter_mut().enumerate() {
                    let off = i * 8;
                    *slot = f64::from_le_bytes(payload_bytes[off..off + 8].try_into().unwrap());
                }
                PoseUdpPayload::Pose {
                    position: [floats[0], floats[1], floats[2]],
                    rotation: [floats[3], floats[4], floats[5], floats[6]],
                    gripper: floats[7],
                }
            }
            other => return Err(PoseUdpDecodeError::UnknownKind { kind: other }),
        };

        Ok(Self {
            t_xr_send_ns,
            seq,
            session_token,
            descriptor_version,
            flags,
            kind,
            payload,
        })
    }
}

// ---------------------------------------------------------------------------
// Ported unit tests (from robot/src/network/protocol.rs)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_roundtrip() {
        let mut codec = CommandCodec;
        let frame = CommandFrame {
            command: "Tracking".to_string(),
            data: b"{\"Head\":{}}".to_vec(),
        };

        let mut buf = BytesMut::new();
        codec.encode(frame.clone(), &mut buf).unwrap();

        let decoded = codec.decode(&mut buf).unwrap().unwrap();
        assert_eq!(decoded.command, "Tracking");
        assert_eq!(decoded.data, b"{\"Head\":{}}");
    }

    #[test]
    fn command_le_byte_order() {
        let mut codec = CommandCodec;
        let frame = CommandFrame {
            command: "AB".to_string(),
            data: vec![1, 2, 3],
        };

        let mut buf = BytesMut::new();
        codec.encode(frame, &mut buf).unwrap();

        // cmd_len = 2 as LE i32
        assert_eq!(&buf[0..4], &[2, 0, 0, 0]);
        // command bytes
        assert_eq!(&buf[4..6], b"AB");
        // data_len = 3 as LE i32
        assert_eq!(&buf[6..10], &[3, 0, 0, 0]);
        // data bytes
        assert_eq!(&buf[10..13], &[1, 2, 3]);
    }

    #[test]
    fn command_oversized_rejected() {
        // Hand-craft a cmd_len that exceeds MAX_CMD_LEN; decode must error.
        let mut codec = CommandCodec;
        let mut buf = BytesMut::new();
        buf.put_i32_le((MAX_CMD_LEN as i32) + 1);
        let err = codec.decode(&mut buf).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn video_roundtrip() {
        let mut codec = VideoFrameCodec;
        let nal = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42];

        let mut buf = BytesMut::new();
        codec.encode(nal.clone(), &mut buf).unwrap();

        let decoded = codec.decode(&mut buf).unwrap().unwrap();
        assert_eq!(decoded, nal);
    }

    #[test]
    fn video_be_byte_order() {
        let mut codec = VideoFrameCodec;
        let nal = vec![0xAA; 256];

        let mut buf = BytesMut::new();
        codec.encode(nal, &mut buf).unwrap();

        // length = 256 as BE u32 = 0x00000100
        assert_eq!(&buf[0..4], &[0x00, 0x00, 0x01, 0x00]);
    }

    #[test]
    fn timed_video_roundtrip() {
        let mut codec = TimedVideoFrameCodec;
        let packet = TimedVideoFrame {
            frame_id: 42,
            nal_index: 1,
            nal_count: 3,
            pipeline_mode: VIDEO_PIPELINE_MODE_FFMPEG,
            capture_start_ns: 10,
            capture_end_ns: 20,
            encode_start_ns: 30,
            encode_end_ns: 40,
            read_wait_ns: 50,
            parse_ns: 60,
            send_ns: 70,
            nal: vec![0x00, 0x00, 0x00, 0x01, 0x65, 0xAA],
        };

        let mut buf = BytesMut::new();
        codec.encode(packet.clone(), &mut buf).unwrap();

        let decoded = codec.decode(&mut buf).unwrap().unwrap();
        assert_eq!(decoded.frame_id, 42);
        assert_eq!(decoded.nal_index, 1);
        assert_eq!(decoded.nal_count, 3);
        assert_eq!(decoded.pipeline_mode, VIDEO_PIPELINE_MODE_FFMPEG);
        assert_eq!(decoded.capture_start_ns, 10);
        assert_eq!(decoded.capture_end_ns, 20);
        assert_eq!(decoded.encode_start_ns, 30);
        assert_eq!(decoded.encode_end_ns, 40);
        assert_eq!(decoded.read_wait_ns, 50);
        assert_eq!(decoded.parse_ns, 60);
        assert_eq!(decoded.send_ns, 70);
        assert_eq!(decoded.nal, packet.nal);
    }

    #[test]
    fn command_partial_decode() {
        let mut codec = CommandCodec;
        let frame = CommandFrame {
            command: "Test".to_string(),
            data: b"hello".to_vec(),
        };

        let mut full = BytesMut::new();
        codec.encode(frame, &mut full).unwrap();

        // Feed partial data — should return None.
        let mut partial = full.split_to(5);
        assert!(codec.decode(&mut partial).unwrap().is_none());

        // Reassemble and decode.
        partial.unsplit(full);
        let decoded = codec.decode(&mut partial).unwrap().unwrap();
        assert_eq!(decoded.command, "Test");
        assert_eq!(decoded.data, b"hello");
    }

    #[test]
    fn crc16_ccitt_known_vector() {
        // Classic test vector: CRC-16/CCITT-FALSE("123456789") = 0x29B1.
        assert_eq!(crc16_ccitt(b"123456789"), 0x29B1);
    }

    #[test]
    fn pose_udp_pose_roundtrip() {
        let pkt = PoseUdpPacket {
            t_xr_send_ns: 1_234_567_890_123_456_789,
            seq: 42,
            session_token: 0xDEADBEEF,
            descriptor_version: 1,
            flags: 0b0000_0001,
            kind: POSE_UDP_KIND_POSE,
            payload: PoseUdpPayload::Pose {
                position: [0.1, -0.2, 1.0],
                rotation: [
                    0.0,
                    0.0,
                    std::f64::consts::FRAC_1_SQRT_2,
                    std::f64::consts::FRAC_1_SQRT_2,
                ],
                gripper: 0.5,
            },
        };
        let bytes = pkt.encode();
        assert_eq!(bytes.len(), POSE_UDP_POSE_PACKET_SIZE);

        let decoded = PoseUdpPacket::decode(&bytes).unwrap();
        assert_eq!(decoded.seq, 42);
        assert_eq!(decoded.session_token, 0xDEADBEEF);
        match decoded.payload {
            PoseUdpPayload::Pose {
                position,
                rotation,
                gripper,
            } => {
                assert_eq!(position, [0.1, -0.2, 1.0]);
                assert_eq!(
                    rotation,
                    [
                        0.0,
                        0.0,
                        std::f64::consts::FRAC_1_SQRT_2,
                        std::f64::consts::FRAC_1_SQRT_2,
                    ]
                );
                assert_eq!(gripper, 0.5);
            }
        }
    }

    #[test]
    fn pose_udp_crc_mismatch_rejected() {
        let pkt = PoseUdpPacket {
            t_xr_send_ns: 0,
            seq: 1,
            session_token: 0,
            descriptor_version: 0,
            flags: 0,
            kind: POSE_UDP_KIND_POSE,
            payload: PoseUdpPayload::Pose {
                position: [0.0; 3],
                rotation: [0.0, 0.0, 0.0, 1.0],
                gripper: 0.0,
            },
        };
        let mut bytes = pkt.encode();
        // Flip a payload byte — CRC must catch it.
        bytes[POSE_UDP_HEADER_SIZE] ^= 0xFF;
        match PoseUdpPacket::decode(&bytes) {
            Err(PoseUdpDecodeError::CrcMismatch { .. }) => {}
            other => panic!("expected CrcMismatch, got {other:?}"),
        }
    }

    #[test]
    fn pose_udp_short_packet_rejected() {
        let buf = vec![0u8; POSE_UDP_HEADER_SIZE - 1];
        match PoseUdpPacket::decode(&buf) {
            Err(PoseUdpDecodeError::TooShort { .. }) => {}
            other => panic!("expected TooShort, got {other:?}"),
        }
    }
}
