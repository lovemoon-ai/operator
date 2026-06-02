//! H.264 Annex-B NAL parsing + parameter-set caching.
//!
//! `NalParser` is copied verbatim (byte-for-byte behaviour) from
//! `robot/src/video/ffmpeg.rs` during the bridge/adapter split — it splits a
//! continuous H.264 Annex-B bytestream into individual NAL units, always
//! re-emitting a 4-byte start code. `ParamSetCache` is new: it remembers the
//! most recent SPS (NAL type 7) and PPS (NAL type 8) seen on a stream so a
//! late-joining headset can be primed before the next IDR.

use std::sync::{Arc, Mutex};

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

        loop {
            // Find first start code in buffer.
            let first = match find_start_code(&self.buffer, 0) {
                Some(pos) => pos,
                None => break,
            };

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

/// Thread-safe cache of the latest SPS/PPS seen on a single feed.
///
/// A late-joining headset needs an SPS + PPS before it can configure its
/// decoder, and an IDR to start a clean GOP. The fan-out consults this cache
/// to prime new subscribers (see `fanout.rs`).
#[derive(Clone, Default)]
pub struct ParamSetCache {
    inner: Arc<Mutex<ParamSets>>,
}

#[derive(Default)]
struct ParamSets {
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
}

impl ParamSetCache {
    pub fn new() -> Self {
        Self::default()
    }

    /// Inspect a NAL; if it is an SPS or PPS, store it as the latest.
    ///
    /// Returns `true` if the NAL was a parameter set (and thus cached).
    pub fn observe(&self, nal: &[u8]) -> bool {
        match nal_type(nal) {
            Some(NAL_TYPE_SPS) => {
                self.inner.lock().unwrap().sps = Some(nal.to_vec());
                true
            }
            Some(NAL_TYPE_PPS) => {
                self.inner.lock().unwrap().pps = Some(nal.to_vec());
                true
            }
            _ => false,
        }
    }

    /// Latest cached SPS, if any.
    pub fn sps(&self) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().sps.clone()
    }

    /// Latest cached PPS, if any.
    pub fn pps(&self) -> Option<Vec<u8>> {
        self.inner.lock().unwrap().pps.clone()
    }

    /// Both parameter sets in (SPS, PPS) order if both are present.
    pub fn param_nals(&self) -> Option<(Vec<u8>, Vec<u8>)> {
        let g = self.inner.lock().unwrap();
        match (&g.sps, &g.pps) {
            (Some(s), Some(p)) => Some((s.clone(), p.clone())),
            _ => None,
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
        let stream = [
            &sps_a, &pps_a, &idr, &p1, &p2, &sps_b, &pps_b, &idr2, &p3,
        ];
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
}
