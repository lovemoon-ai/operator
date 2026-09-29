//! H.264 / H.265 Annex-B NAL parsing + parameter-set caching.
//!
//! `NalParser` is copied verbatim (byte-for-byte behaviour) from
//! `robot/src/video/ffmpeg.rs` during the bridge/adapter split — it splits a
//! continuous Annex-B bytestream into individual NAL units, always re-emitting
//! the stream's original start code. It is codec-agnostic (it only keys on the
//! `00 00 01` start codes, which both H.264 and H.265 share), so the relay
//! never rewrites the body regardless of codec.
//!
//! Everything *above* the splitter — NAL type classification and the
//! [`ParamSetCache`] — is codec-aware via [`Codec`], because H.264 and H.265
//! number their NAL types differently and put the type in different bits of the
//! header (`byte & 0x1F` for AVC vs `(byte >> 1) & 0x3F` for HEVC), and because
//! HEVC needs a third parameter set (VPS) cached alongside SPS/PPS to prime a
//! late-joining headset.

use std::sync::{Arc, Mutex};

/// Codec family of a relayed feed.
///
/// The bridge never transcodes (the RTSP source is stream-copied), so this is
/// purely a *declaration* of what the upstream (Isaac Sim / the test
/// publisher) is sending. It drives three things: how NAL units are classified
/// here, which parameter sets the cache keeps, and which bitstream filter +
/// muxer ffmpeg uses for the copy (see `source.rs`). It is also advertised to
/// the headset in the descriptor so it spins up the matching MediaCodec MIME
/// (`video/avc` vs `video/hevc`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Codec {
    /// H.264 / AVC — the historical default.
    #[default]
    H264,
    /// H.265 / HEVC.
    Hevc,
}

impl Codec {
    /// Parse a YAML / descriptor codec string. Unknown or empty strings fall
    /// back to [`Codec::H264`] (the historical default) rather than erroring,
    /// so a typo can't brick a feed — it relays as H.264 and the mismatch is
    /// visible in the logs / on the headset HUD.
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "hevc" | "h265" | "x265" => Codec::Hevc,
            _ => Codec::H264,
        }
    }

    /// Lower-case wire name (`"h264"` / `"hevc"`), as carried in the descriptor.
    pub fn as_str(self) -> &'static str {
        match self {
            Codec::H264 => "h264",
            Codec::Hevc => "hevc",
        }
    }
}

/// Parser that splits a continuous H.264 Annex B bytestream into individual NAL units.
///
/// NAL units are delimited by start codes: 0x00 0x00 0x00 0x01 (4-byte)
/// or 0x00 0x00 0x01 (3-byte). We always output with the original start code
/// bytes preserved (i.e. whatever the stream used). The relay never rewrites
/// the body, so the headset decodes the exact bytes Isaac produced.
pub struct NalParser {
    buffer: Vec<u8>,
}

impl Default for NalParser {
    fn default() -> Self {
        Self::new()
    }
}

impl NalParser {
    pub fn new() -> Self {
        Self {
            buffer: Vec::with_capacity(256 * 1024),
        }
    }

    /// Feed raw H.264 bytestream data. Returns any complete NAL units found.
    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(data);
        let mut nals = Vec::new();

        while let Some(first) = find_start_code(&self.buffer, 0) {
            // Find first start code in buffer.
            // Find next start code after the first one.
            let search_from = first.offset + first.len;
            match find_start_code(&self.buffer, search_from) {
                Some(second) => {
                    // Extract the NAL unit between first and second start codes.
                    let nal = self.buffer[first.offset..second.offset].to_vec();
                    if nal.len() > 4 {
                        // Only emit non-trivial NALs.
                        nals.push(nal);
                    }
                    // Remove consumed data up to the second start code.
                    self.buffer.drain(..second.offset);
                }
                None => break, // Incomplete NAL, wait for more data.
            }
        }

        // Prevent unbounded buffer growth.
        if self.buffer.len() > 4 * 1024 * 1024 {
            tracing::warn!(
                "NAL parser buffer overflow ({}B), clearing",
                self.buffer.len()
            );
            self.buffer.clear();
        }

        nals
    }
}

struct StartCode {
    offset: usize,
    len: usize,
}

/// Find the next Annex B start code (0x00 0x00 0x01 or 0x00 0x00 0x00 0x01).
fn find_start_code(data: &[u8], from: usize) -> Option<StartCode> {
    if data.len() < from + 3 {
        return None;
    }
    for i in from..data.len() - 2 {
        if data[i] == 0x00 && data[i + 1] == 0x00 {
            if data[i + 2] == 0x01 {
                // 3-byte start code
                return Some(StartCode { offset: i, len: 3 });
            }
            if i + 3 < data.len() && data[i + 2] == 0x00 && data[i + 3] == 0x01 {
                // 4-byte start code
                return Some(StartCode { offset: i, len: 4 });
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// NAL type classification helpers
// ---------------------------------------------------------------------------

/// H.264 NAL unit type for a sequence parameter set.
pub const NAL_TYPE_SPS: u8 = 7;
/// H.264 NAL unit type for a picture parameter set.
pub const NAL_TYPE_PPS: u8 = 8;
/// H.264 NAL unit type for an IDR (instantaneous decoder refresh) coded slice.
pub const NAL_TYPE_IDR: u8 = 5;

/// HEVC NAL unit type for a video parameter set.
pub const HEVC_NAL_VPS: u8 = 32;
/// HEVC NAL unit type for a sequence parameter set.
pub const HEVC_NAL_SPS: u8 = 33;
/// HEVC NAL unit type for a picture parameter set.
pub const HEVC_NAL_PPS: u8 = 34;
/// HEVC access-unit delimiter NAL type.
pub const HEVC_NAL_AUD: u8 = 35;
/// First HEVC IRAP (intra random-access point) VCL NAL type (BLA_W_LP).
pub const HEVC_NAL_IRAP_FIRST: u8 = 16;
/// Last HEVC IRAP VCL NAL type (RSV_IRAP_VCL23). IDR/BLA/CRA all live in
/// `16..=23`; any of them can start a clean GOP.
pub const HEVC_NAL_IRAP_LAST: u8 = 23;

/// Length of the Annex-B start code at the front of `nal` (3 or 4 bytes).
/// Returns 0 if `nal` doesn't begin with a recognisable start code.
fn start_code_len(nal: &[u8]) -> usize {
    if nal.len() >= 4 && nal[0] == 0 && nal[1] == 0 && nal[2] == 0 && nal[3] == 1 {
        4
    } else if nal.len() >= 3 && nal[0] == 0 && nal[1] == 0 && nal[2] == 1 {
        3
    } else {
        0
    }
}

/// Extract the H.264 NAL unit type (lower 5 bits of the byte that follows the
/// Annex-B start code). Returns `None` if the NAL has no start code / is empty.
pub fn nal_type(nal: &[u8]) -> Option<u8> {
    let sc = start_code_len(nal);
    if sc == 0 {
        // Allow a raw NAL with no start code: first byte is the header.
        return nal.first().map(|b| b & 0x1F);
    }
    nal.get(sc).map(|b| b & 0x1F)
}

/// True if `nal` is an IDR (key) slice.
pub fn is_idr(nal: &[u8]) -> bool {
    nal_type(nal) == Some(NAL_TYPE_IDR)
}

/// True if `nal` is a parameter set (SPS or PPS).
pub fn is_param(nal: &[u8]) -> bool {
    matches!(nal_type(nal), Some(NAL_TYPE_SPS) | Some(NAL_TYPE_PPS))
}

/// Codec-aware NAL unit type extraction.
///
/// H.264 puts the type in the low 5 bits of the byte after the start code
/// (`byte & 0x1F`); HEVC's NAL header is 2 bytes and the type is bits 6..1 of
/// the first byte (`(byte >> 1) & 0x3F`). Returns `None` if the NAL is empty.
pub fn nal_type_of(nal: &[u8], codec: Codec) -> Option<u8> {
    let sc = start_code_len(nal);
    // With a start code the header byte follows it; without one (a raw NAL) the
    // first byte is the header.
    let header = if sc == 0 {
        *nal.first()?
    } else {
        *nal.get(sc)?
    };
    Some(match codec {
        Codec::H264 => header & 0x1F,
        Codec::Hevc => (header >> 1) & 0x3F,
    })
}

/// True if `nal` is a keyframe slice that can start a clean GOP: an IDR for
/// H.264, or any IRAP (IDR/BLA/CRA, types `16..=23`) for HEVC.
pub fn is_keyframe(nal: &[u8], codec: Codec) -> bool {
    match codec {
        Codec::H264 => nal_type_of(nal, codec) == Some(NAL_TYPE_IDR),
        Codec::Hevc => matches!(
            nal_type_of(nal, codec),
            Some(HEVC_NAL_IRAP_FIRST..=HEVC_NAL_IRAP_LAST)
        ),
    }
}

/// True if `nal` is a parameter set the headset needs before configuring its
/// decoder: SPS/PPS for H.264; VPS/SPS/PPS for HEVC.
pub fn is_param_set(nal: &[u8], codec: Codec) -> bool {
    match codec {
        Codec::H264 => matches!(nal_type_of(nal, codec), Some(NAL_TYPE_SPS | NAL_TYPE_PPS)),
        Codec::Hevc => matches!(
            nal_type_of(nal, codec),
            Some(HEVC_NAL_VPS | HEVC_NAL_SPS | HEVC_NAL_PPS)
        ),
    }
}

/// Thread-safe cache of the latest parameter sets seen on a single feed.
///
/// A late-joining headset needs the parameter sets (SPS + PPS for H.264; VPS +
/// SPS + PPS for HEVC) before it can configure its decoder, and a keyframe to
/// start a clean GOP. The fan-out consults this cache to prime new subscribers
/// (see `fanout.rs`). The cache carries its feed's [`Codec`] so classification
/// and the ordered priming output match the stream.
#[derive(Clone, Default)]
pub struct ParamSetCache {
    inner: Arc<Mutex<ParamSets>>,
    codec: Codec,
}

#[derive(Default)]
struct ParamSets {
    /// HEVC only — H.264 has no VPS.
    vps: Option<Vec<u8>>,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
}

impl ParamSetCache {
    /// New cache for an H.264 feed (the historical default).
    pub fn new() -> Self {
        Self::default()
    }

    /// New cache for a feed of the given codec.
    pub fn with_codec(codec: Codec) -> Self {
        Self {
            inner: Arc::default(),
            codec,
        }
    }

    /// Codec this cache classifies for.
    pub fn codec(&self) -> Codec {
        self.codec
    }

    /// Inspect a NAL; if it is a parameter set for this feed's codec, store it
    /// as the latest. Returns `true` if the NAL was a parameter set.
    pub fn observe(&self, nal: &[u8]) -> bool {
        let typ = nal_type_of(nal, self.codec);
        match (self.codec, typ) {
            (Codec::H264, Some(NAL_TYPE_SPS)) => {
                self.inner.lock().unwrap().sps = Some(nal.to_vec());
                true
            }
            (Codec::H264, Some(NAL_TYPE_PPS)) => {
                self.inner.lock().unwrap().pps = Some(nal.to_vec());
                true
            }
            (Codec::Hevc, Some(HEVC_NAL_VPS)) => {
                self.inner.lock().unwrap().vps = Some(nal.to_vec());
                true
            }
            (Codec::Hevc, Some(HEVC_NAL_SPS)) => {
                self.inner.lock().unwrap().sps = Some(nal.to_vec());
                true
            }
            (Codec::Hevc, Some(HEVC_NAL_PPS)) => {
                self.inner.lock().unwrap().pps = Some(nal.to_vec());
                true
            }
            _ => false,
        }
    }

    /// Latest cached VPS, if any (HEVC only).
    pub fn vps(&self) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().vps.clone()
    }

    /// Latest cached SPS, if any.
    pub fn sps(&self) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().sps.clone()
    }

    /// Latest cached PPS, if any.
    pub fn pps(&self) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().pps.clone()
    }

    /// The SPS + PPS pair in order, if both are present. Kept for the H.264
    /// readiness checks in tests/examples; for the full ordered priming set
    /// (which includes the HEVC VPS) use [`Self::ordered_param_nals`].
    pub fn param_nals(&self) -> Option<(Vec<u8>, Vec<u8>)> {
        let g = self.inner.lock().unwrap();
        match (&g.sps, &g.pps) {
            (Some(s), Some(p)) => Some((s.clone(), p.clone())),
            _ => None,
        }
    }

    /// All parameter sets in decode order, ready to prime a new client:
    /// `[SPS, PPS]` for H.264, `[VPS, SPS, PPS]` for HEVC. Empty until every
    /// required set has been observed (so a client is never primed with a
    /// partial configuration).
    pub fn ordered_param_nals(&self) -> Vec<Vec<u8>> {
        let g = self.inner.lock().unwrap();
        match self.codec {
            Codec::H264 => match (&g.sps, &g.pps) {
                (Some(s), Some(p)) => vec![s.clone(), p.clone()],
                _ => Vec::new(),
            },
            Codec::Hevc => match (&g.vps, &g.sps, &g.pps) {
                (Some(v), Some(s), Some(p)) => vec![v.clone(), s.clone(), p.clone()],
                _ => Vec::new(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- NalParser (ported from robot/src/video/ffmpeg.rs) ----

    #[test]
    fn test_nal_parser_splits_correctly() {
        let mut parser = NalParser::new();

        // Feed a bytestream with two NAL units.
        let data = vec![
            0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x1E, // SPS
            0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80, // PPS
            0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, // IDR (incomplete, no end)
        ];

        let nals = parser.feed(&data);
        assert_eq!(nals.len(), 2);
        assert_eq!(nals[0], &[0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x1E]);
        assert_eq!(nals[1], &[0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80]);

        // Feed more data that completes the IDR and starts a new NAL.
        let data2 = vec![
            0x40, // more IDR data
            0x00, 0x00, 0x00, 0x01, 0x41, 0x88, // P-slice start
        ];
        let nals2 = parser.feed(&data2);
        assert_eq!(nals2.len(), 1);
        // IDR: start code + 0x65 0x88 0x80 0x40
        assert_eq!(nals2[0], &[0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, 0x40]);
    }

    #[test]
    fn test_nal_parser_handles_3byte_start_code() {
        let mut parser = NalParser::new();

        let data = vec![
            0x00, 0x00, 0x01, 0x67, 0x42, // 3-byte start code SPS
            0x00, 0x00, 0x01, 0x68, 0xCE, // 3-byte start code PPS
            0x00, 0x00, 0x01, 0x65, // 3-byte start code IDR (incomplete)
        ];

        let nals = parser.feed(&data);
        assert_eq!(nals.len(), 2);
    }

    #[test]
    fn test_nal_parser_partial_buffer_across_feeds() {
        // A start code split across two feed() calls must still parse once
        // the full second start code arrives.
        let mut parser = NalParser::new();

        // First chunk: SPS start + body + the first two bytes of the next
        // start code (0x00 0x00) but NOT the 0x01 yet.
        let chunk1 = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0, 0x00, 0x00];
        let nals1 = parser.feed(&chunk1);
        assert_eq!(nals1.len(), 0, "no complete NAL until next start code seen");

        // Second chunk completes the 3-byte start code (00 00 01) for the
        // PPS and then a 4-byte start code for the IDR. Now two complete NALs
        // are delimited: the SPS (terminated by the PPS start code) and the
        // PPS (terminated by the IDR start code).
        let chunk2 = vec![0x01, 0x68, 0xCE, 0x38, 0x00, 0x00, 0x00, 0x01, 0x65];
        let nals2 = parser.feed(&chunk2);
        assert_eq!(nals2.len(), 2);
        // First NAL is the SPS only (start code + 0x67 0x42 0xC0).
        assert_eq!(nals2[0], &[0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0]);
        // Second NAL is the PPS (3-byte start code + 0x68 0xCE 0x38).
        assert_eq!(nals2[1], &[0x00, 0x00, 0x01, 0x68, 0xCE, 0x38]);
    }

    // ---- NAL type classification ----

    #[test]
    fn classifies_nal_types() {
        let sps = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0x42];
        let pps = vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xCE];
        let idr = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x88];
        let p = vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x88];

        assert_eq!(nal_type(&sps), Some(NAL_TYPE_SPS));
        assert_eq!(nal_type(&pps), Some(NAL_TYPE_PPS));
        assert_eq!(nal_type(&idr), Some(NAL_TYPE_IDR));
        assert_eq!(nal_type(&p), Some(1));

        assert!(is_param(&sps));
        assert!(is_param(&pps));
        assert!(!is_param(&idr));
        assert!(!is_param(&p));

        assert!(is_idr(&idr));
        assert!(!is_idr(&p));
        assert!(!is_idr(&sps));
    }

    #[test]
    fn classifies_3byte_start_code_nal() {
        let idr = vec![0x00, 0x00, 0x01, 0x65, 0x88];
        assert!(is_idr(&idr));
        let sps = vec![0x00, 0x00, 0x01, 0x67];
        assert!(is_param(&sps));
    }

    // ---- ParamSetCache ----

    #[test]
    fn param_set_cache_holds_latest_sps_pps() {
        let cache = ParamSetCache::new();

        // Distinct payloads so "latest wins" is observable.
        let sps_a = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0xAA];
        let pps_a = vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xBB];
        let idr = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x01];
        let p1 = vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x01];
        let p2 = vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x02];
        let sps_b = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0xCC];
        let pps_b = vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xDD];
        let idr2 = vec![0x00, 0x00, 0x00, 0x01, 0x65, 0x02];
        let p3 = vec![0x00, 0x00, 0x00, 0x01, 0x41, 0x03];

        // Sequence: [7,8,5,1,1,7,8,5,1].
        let stream = [&sps_a, &pps_a, &idr, &p1, &p2, &sps_b, &pps_b, &idr2, &p3];
        for nal in stream {
            cache.observe(nal);
        }

        // Cache holds the LATEST SPS/PPS (the _b variants).
        assert_eq!(cache.sps(), Some(sps_b.clone()));
        assert_eq!(cache.pps(), Some(pps_b.clone()));
        assert_eq!(cache.param_nals(), Some((sps_b, pps_b)));

        // observe() reports param vs non-param classification.
        assert!(cache.observe(&[0x00, 0x00, 0x00, 0x01, 0x67, 0x99]));
        assert!(cache.observe(&[0x00, 0x00, 0x00, 0x01, 0x68, 0x99]));
        assert!(!cache.observe(&idr));
        assert!(!cache.observe(&p1));
    }

    #[test]
    fn param_nals_none_until_both_present() {
        let cache = ParamSetCache::new();
        assert_eq!(cache.param_nals(), None);
        cache.observe(&[0x00, 0x00, 0x00, 0x01, 0x67, 0xAA]);
        assert_eq!(cache.param_nals(), None, "SPS only is not enough");
        cache.observe(&[0x00, 0x00, 0x00, 0x01, 0x68, 0xBB]);
        assert!(cache.param_nals().is_some());
    }

    #[test]
    fn ordered_param_nals_h264_is_sps_then_pps() {
        let cache = ParamSetCache::new();
        assert!(cache.ordered_param_nals().is_empty());
        let sps = vec![0x00, 0x00, 0x00, 0x01, 0x67, 0xAA];
        let pps = vec![0x00, 0x00, 0x00, 0x01, 0x68, 0xBB];
        cache.observe(&sps);
        assert!(
            cache.ordered_param_nals().is_empty(),
            "SPS only is not enough"
        );
        cache.observe(&pps);
        assert_eq!(cache.ordered_param_nals(), vec![sps, pps]);
    }

    // ---- Codec parsing ----

    #[test]
    fn codec_parse_is_lenient() {
        assert_eq!(Codec::parse("hevc"), Codec::Hevc);
        assert_eq!(Codec::parse("H265"), Codec::Hevc);
        assert_eq!(Codec::parse("x265"), Codec::Hevc);
        assert_eq!(Codec::parse(" HEVC "), Codec::Hevc);
        assert_eq!(Codec::parse("h264"), Codec::H264);
        assert_eq!(Codec::parse(""), Codec::H264);
        assert_eq!(
            Codec::parse("nonsense"),
            Codec::H264,
            "typo falls back to H.264"
        );
        assert_eq!(Codec::default(), Codec::H264);
        assert_eq!(Codec::H264.as_str(), "h264");
        assert_eq!(Codec::Hevc.as_str(), "hevc");
    }

    // ---- HEVC NAL classification ----
    //
    // HEVC NAL header is 2 bytes; the type is bits 6..1 of the first byte,
    // i.e. `(byte0 >> 1) & 0x3F`. The forbidden-zero bit is the MSB. So a
    // first header byte of `(type << 1)` encodes `type`:
    //   VPS(32)=0x40  SPS(33)=0x42  PPS(34)=0x44  AUD(35)=0x46
    //   IDR_W_RADL(19)=0x26  TRAIL_R(1)=0x02  CRA(21)=0x2A

    #[test]
    fn classifies_hevc_nal_types() {
        let vps = vec![0x00, 0x00, 0x00, 0x01, 0x40, 0x01];
        let sps = vec![0x00, 0x00, 0x00, 0x01, 0x42, 0x01];
        let pps = vec![0x00, 0x00, 0x00, 0x01, 0x44, 0x01];
        let idr = vec![0x00, 0x00, 0x00, 0x01, 0x26, 0x01];
        let trail = vec![0x00, 0x00, 0x00, 0x01, 0x02, 0x01];

        assert_eq!(nal_type_of(&vps, Codec::Hevc), Some(HEVC_NAL_VPS));
        assert_eq!(nal_type_of(&sps, Codec::Hevc), Some(HEVC_NAL_SPS));
        assert_eq!(nal_type_of(&pps, Codec::Hevc), Some(HEVC_NAL_PPS));
        assert_eq!(nal_type_of(&idr, Codec::Hevc), Some(19));
        assert_eq!(nal_type_of(&trail, Codec::Hevc), Some(1));

        assert!(is_param_set(&vps, Codec::Hevc));
        assert!(is_param_set(&sps, Codec::Hevc));
        assert!(is_param_set(&pps, Codec::Hevc));
        assert!(!is_param_set(&idr, Codec::Hevc));
        assert!(!is_param_set(&trail, Codec::Hevc));

        assert!(is_keyframe(&idr, Codec::Hevc));
        assert!(!is_keyframe(&trail, Codec::Hevc));
        assert!(!is_keyframe(&vps, Codec::Hevc));

        // The same bytes interpreted as H.264 must NOT be mistaken for AVC
        // parameter sets (guards against codec-confusion in the relay).
        assert!(!is_param_set(&vps, Codec::H264));
    }

    #[test]
    fn hevc_param_set_cache_holds_vps_sps_pps() {
        let cache = ParamSetCache::with_codec(Codec::Hevc);
        assert!(cache.ordered_param_nals().is_empty());

        let vps = vec![0x00, 0x00, 0x00, 0x01, 0x40, 0x10];
        let sps = vec![0x00, 0x00, 0x00, 0x01, 0x42, 0x20];
        let pps = vec![0x00, 0x00, 0x00, 0x01, 0x44, 0x30];

        assert!(cache.observe(&vps));
        assert!(cache.observe(&sps));
        assert!(
            cache.ordered_param_nals().is_empty(),
            "VPS+SPS without PPS is not enough to prime"
        );
        assert!(cache.observe(&pps));

        // HEVC priming order is VPS, SPS, PPS.
        assert_eq!(
            cache.ordered_param_nals(),
            vec![vps.clone(), sps.clone(), pps.clone()]
        );
        assert_eq!(cache.vps(), Some(vps));
        assert_eq!(cache.sps(), Some(sps));
        assert_eq!(cache.pps(), Some(pps));

        // A trailing (non-param) slice is not cached.
        assert!(!cache.observe(&[0x00, 0x00, 0x00, 0x01, 0x02, 0x01]));
    }
}
