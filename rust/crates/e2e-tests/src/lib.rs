//! Cross-process end-to-end tests for the bridge/adapter split.
//!
//! This crate has no library code of its own — it exists only to host
//! integration tests (in `tests/`) that depend on BOTH `xr-bridge` and
//! `robot-adapter` so they can drive a real `AdapterClient` against a real
//! adapter `serve` loop over a real socket. Keeping these here preserves the
//! clean dependency direction: neither product crate depends on the other.
