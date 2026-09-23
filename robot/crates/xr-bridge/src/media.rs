//! Host-session media relay: OLCP `media_up` (headset → host) and
//! `media_down` (host → headset) on the bridge's own port group.
//!
//! A capture-capable headset learns the ports and a per-connection
//! `auth_token` from the bridge-injected `DeviceDescriptor.media` block
//! ([`MediaTransport`]); the address is always the peer it is connected to.
//! Frames keep the OLCP v1 envelope, so the headset's live-push writer and
//! live-pull client talk to the bridge exactly as to an ingest server:
//!
//! * `media_up`: the first frame must be `session_start` whose JSON carries
//!   the current token. Every frame (including `session_start` /
//!   `session_end`) is then queued opaquely for the host. A full queue sheds
//!   the oldest droppable frame (RGB packets, depth frames, poses, inputs,
//!   hands), never `session_start` / `session_end` / `rgb_csd` /
//!   `depth_metadata`. A newer authenticated connection replaces the previous
//!   one. `pts_ns` passes through untouched (headset `godot_ticks_ns`).
//! * `media_down`: the headset sends `result_hello` with the token and gets
//!   `result_welcome`; host frames are then written in order. Results sent
//!   while no headset is connected are not replayed.
//!
//! A token is valid only while its headset ctrl connection owns the session;
//! when that connection ends or is replaced, both media connections close. A
//! replaced headset that is still connected owns the session again once the
//! newer one leaves.

use std::collections::VecDeque;
use std::future::Future;
use std::net::SocketAddr;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use anyhow::{anyhow, bail, ensure, Context, Result};
use bytes::{Buf, BufMut, Bytes, BytesMut};
use futures::{SinkExt, StreamExt};
use tokio::io::AsyncRead;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;
use tokio_util::codec::{Decoder, Encoder, FramedRead, FramedWrite};

use teleop_protocol::{MediaTransport, MEDIA_PROTOCOL};

pub const OLCP_MAGIC: &[u8; 4] = b"OLCP";
pub const OLCP_VERSION: u8 = 1;
/// magic(4) version(1) frame_type(1) flags(u16) pts_ns(u64) duration_ns(u64)
/// payload_size(u32), all big-endian.
pub const OLCP_HEADER_LEN: usize = 28;
/// Largest `media_up` / `media_down` payload the relay accepts.
pub const MAX_MEDIA_PAYLOAD: usize = 32 * 1024 * 1024;

pub const TYPE_SESSION_START: u8 = 1;
pub const TYPE_RGB_CSD: u8 = 2;
pub const TYPE_RGB_PACKET: u8 = 3;
pub const TYPE_DEPTH_METADATA: u8 = 4;
pub const TYPE_DEPTH_FRAME: u8 = 5;
pub const TYPE_HEAD_POSE: u8 = 6;
pub const TYPE_SESSION_END: u8 = 10;
pub const TYPE_RESULT_HELLO: u8 = 100;
pub const TYPE_RESULT_WELCOME: u8 = 102;

pub const RESULT_HELLO_SCHEMA: &str = "operator.result_hello.v1";
pub const RESULT_WELCOME_SCHEMA: &str = "operator.result_welcome.v1";

/// Bound on the handshake frames read before a peer is authenticated.
const MAX_SESSION_START_PAYLOAD: usize = 64 * 1024;
const MAX_RESULT_HELLO_PAYLOAD: usize = 4096;
const AUTH_TIMEOUT: Duration = Duration::from_secs(5);
/// A headset that stops reading results is dropped after this long.
const DOWN_WRITE_TIMEOUT: Duration = Duration::from_secs(15);
const UP_QUEUE_FRAMES: usize = 256;
const UP_QUEUE_BYTES: usize = 64 * 1024 * 1024;
const DOWN_QUEUE_FRAMES: usize = 64;
const TOKEN_BYTES: usize = 16;

/// One OLCP frame, relayed opaquely.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaFrame {
    pub frame_type: u8,
    pub flags: u16,
    pub pts_ns: u64,
    pub duration_ns: u64,
    pub payload: Bytes,
}

impl MediaFrame {
    pub fn new(
        frame_type: u8,
        flags: u16,
        pts_ns: u64,
        duration_ns: u64,
        payload: impl Into<Bytes>,
    ) -> Self {
        Self {
            frame_type,
            flags,
            pts_ns,
            duration_ns,
            payload: payload.into(),
        }
    }

    /// Whether back-pressure may shed this frame. Lifecycle and stream
    /// configuration frames are low-rate and must survive.
    pub fn droppable(&self) -> bool {
        !matches!(
            self.frame_type,
            TYPE_SESSION_START | TYPE_RGB_CSD | TYPE_DEPTH_METADATA | TYPE_SESSION_END
        )
    }

    fn json(&self) -> Option<serde_json::Value> {
        serde_json::from_slice::<serde_json::Value>(&self.payload)
            .ok()
            .filter(serde_json::Value::is_object)
    }
}

/// OLCP v1 framing with a payload bound.
#[derive(Debug, Clone, Copy)]
pub struct OlcpCodec {
    max_payload: usize,
}

impl OlcpCodec {
    pub fn new(max_payload: usize) -> Self {
        Self { max_payload }
    }
}

impl Default for OlcpCodec {
    fn default() -> Self {
        Self::new(MAX_MEDIA_PAYLOAD)
    }
}

fn invalid(message: String) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message)
}

impl Decoder for OlcpCodec {
    type Item = MediaFrame;
    type Error = std::io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> std::io::Result<Option<MediaFrame>> {
        if src.len() < OLCP_HEADER_LEN {
            return Ok(None);
        }
        if &src[..4] != OLCP_MAGIC {
            return Err(invalid(format!("invalid OLCP magic {:?}", &src[..4])));
        }
        if src[4] != OLCP_VERSION {
            return Err(invalid(format!("unsupported OLCP version {}", src[4])));
        }
        let payload_len = u32::from_be_bytes([src[24], src[25], src[26], src[27]]) as usize;
        if payload_len > self.max_payload {
            return Err(invalid(format!(
                "OLCP payload too large: {payload_len} bytes (maximum {})",
                self.max_payload
            )));
        }
        // Buffer grows with received bytes only: a header alone never makes
        // the relay allocate the declared payload.
        if src.len() < OLCP_HEADER_LEN + payload_len {
            return Ok(None);
        }
        let mut header = src.split_to(OLCP_HEADER_LEN);
        header.advance(5);
        let frame_type = header.get_u8();
        let flags = header.get_u16();
        let pts_ns = header.get_u64();
        let duration_ns = header.get_u64();
        Ok(Some(MediaFrame {
            frame_type,
            flags,
            pts_ns,
            duration_ns,
            payload: src.split_to(payload_len).freeze(),
        }))
    }
}

impl Encoder<MediaFrame> for OlcpCodec {
    type Error = std::io::Error;

    fn encode(&mut self, frame: MediaFrame, dst: &mut BytesMut) -> std::io::Result<()> {
        if frame.payload.len() > self.max_payload {
            return Err(invalid(format!(
                "OLCP payload too large: {} bytes (maximum {})",
                frame.payload.len(),
                self.max_payload
            )));
        }
        dst.reserve(OLCP_HEADER_LEN + frame.payload.len());
        dst.put_slice(OLCP_MAGIC);
        dst.put_u8(OLCP_VERSION);
        dst.put_u8(frame.frame_type);
        dst.put_u16(frame.flags);
        dst.put_u64(frame.pts_ns);
        dst.put_u64(frame.duration_ns);
        dst.put_u32(frame.payload.len() as u32);
        dst.put_slice(&frame.payload);
        Ok(())
    }
}

/// Why a host frame could not be sent on `media_down`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaDownError {
    /// No authenticated headset result connection (or it just closed).
    NotConnected,
    TooLarge(usize),
}

impl std::fmt::Display for MediaDownError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConnected => f.write_str("no headset media_down connection"),
            Self::TooLarge(size) => write!(
                f,
                "media_down payload too large: {size} bytes (maximum {MAX_MEDIA_PAYLOAD})"
            ),
        }
    }
}

impl std::error::Error for MediaDownError {}

/// Media connection counters for host diagnostics.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MediaStats {
    pub up_connected: bool,
    pub down_connected: bool,
    /// Frames accepted from `media_up` (including later-dropped ones).
    pub up_frames: u64,
    /// Frames shed by the `media_up` queue under back-pressure, plus the
    /// backlog dropped with a session whose headset was replaced.
    pub up_dropped: u64,
}

/// Host side of the session media relay, shared by the bridge tasks, the
/// headset ctrl connection that owns the session, and the host consumer.
#[derive(Clone)]
pub struct MediaChannels {
    inner: Arc<Inner>,
}

struct Inner {
    state: Mutex<State>,
    up_ready: Condvar,
    /// Bumped whenever ownership or an installed connection changes, so
    /// media connection tasks re-check that they are still current.
    changed: watch::Sender<u64>,
    server_instance_id: String,
}

#[derive(Default)]
struct State {
    /// `(push_port, result_port)` once the relay listeners are bound.
    ports: Option<(u16, u16)>,
    next_id: u64,
    /// Attached headset ctrl connections and their tokens, oldest first. The
    /// newest owns the session; when it leaves, the previous one still
    /// connected owns it again.
    owners: Vec<(u64, String)>,
    up_conn: Option<u64>,
    down: Option<(u64, mpsc::Sender<MediaFrame>)>,
    queue: VecDeque<MediaFrame>,
    queued_bytes: usize,
    up_frames: u64,
    up_dropped: u64,
    closed: bool,
}

impl State {
    fn next_id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    fn token_matches(&self, token: Option<&str>) -> bool {
        match (self.owners.last(), token) {
            (Some((_, expected)), Some(token)) => tokens_match(expected, token),
            _ => false,
        }
    }

    /// Queue `frame`; shed the oldest droppable *earlier* frame while over
    /// budget. Protected frames may overflow (they are low-rate).
    fn enqueue(&mut self, frame: MediaFrame) {
        self.up_frames += 1;
        self.queued_bytes += frame.payload.len();
        self.queue.push_back(frame);
        while self.queue.len() > UP_QUEUE_FRAMES || self.queued_bytes > UP_QUEUE_BYTES {
            let newest = self.queue.len() - 1;
            let Some(index) = self
                .queue
                .iter()
                .take(newest)
                .position(MediaFrame::droppable)
            else {
                break;
            };
            if let Some(dropped) = self.queue.remove(index) {
                self.queued_bytes -= dropped.payload.len();
                self.up_dropped += 1;
            }
        }
    }
}

impl Default for MediaChannels {
    fn default() -> Self {
        Self::new()
    }
}

impl MediaChannels {
    pub fn new() -> Self {
        let (changed, _) = watch::channel(0);
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                up_ready: Condvar::new(),
                changed,
                server_instance_id: random_hex(TOKEN_BYTES)
                    .unwrap_or_else(|| format!("{:x}", std::process::id() as u128 ^ now_nanos())),
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn bump(&self) {
        self.inner.changed.send_modify(|version| *version += 1);
    }

    /// Serve `listeners` as this session's media transport. The ports are
    /// advertised immediately; the returned future runs the relay.
    pub fn serve(
        &self,
        listeners: MediaListeners,
    ) -> Result<impl Future<Output = Result<()>> + Send + 'static> {
        let ports = (
            listeners.up.local_addr()?.port(),
            listeners.down.local_addr()?.port(),
        );
        self.lock().ports = Some(ports);
        let channels = self.clone();
        Ok(async move {
            tokio::try_join!(
                accept_loop(listeners.up, channels.clone(), handle_up),
                accept_loop(listeners.down, channels, handle_down),
            )?;
            Ok(())
        })
    }

    /// Make a newly handshaken headset ctrl connection the media owner with
    /// a fresh token. `None` while the relay is not serving. Dropping the
    /// attachment revokes the token, closes its media connections and hands
    /// the session back to the previous headset still attached.
    pub(crate) fn attach(&self) -> Option<MediaAttachment> {
        let token = random_hex(TOKEN_BYTES)?;
        let mut state = self.lock();
        let (push_port, result_port) = state.ports.filter(|_| !state.closed)?;
        let owner = state.next_id();
        state.owners.push((owner, token.clone()));
        state.up_conn = None;
        state.down = None;
        // The previous headset's backlog belongs to a session the host has
        // already seen end. Delivering it after the new session_start would
        // interleave two headsets' frames and decode depth against the wrong
        // camera model, so it is dropped with the session that produced it.
        state.up_dropped += state.queue.len() as u64;
        state.queue.clear();
        state.queued_bytes = 0;
        drop(state);
        self.bump();
        Some(MediaAttachment {
            channels: self.clone(),
            owner,
            transport: MediaTransport {
                protocol: MEDIA_PROTOCOL.to_string(),
                push_port,
                result_port,
                auth_token: token,
            },
        })
    }

    /// Next `media_up` frame in arrival order. Blocks up to `timeout`
    /// (`None`: until a frame arrives or [`close`](Self::close)). Never call
    /// from an async task.
    pub fn recv_up(&self, timeout: Option<Duration>) -> Option<MediaFrame> {
        let state = self.lock();
        let waiting = |state: &mut State| state.queue.is_empty() && !state.closed;
        let mut state = match timeout {
            Some(timeout) => {
                self.inner
                    .up_ready
                    .wait_timeout_while(state, timeout, waiting)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0
            }
            None => self
                .inner
                .up_ready
                .wait_while(state, waiting)
                .unwrap_or_else(PoisonError::into_inner),
        };
        let frame = state.queue.pop_front()?;
        state.queued_bytes -= frame.payload.len();
        Some(frame)
    }

    /// Send one frame to the connected headset result client, in order.
    /// Blocks while the per-connection queue is full; the headset connection
    /// is dropped if it stops reading. Never call from an async task.
    pub fn send_down(&self, frame: MediaFrame) -> Result<(), MediaDownError> {
        if frame.payload.len() > MAX_MEDIA_PAYLOAD {
            return Err(MediaDownError::TooLarge(frame.payload.len()));
        }
        let sender = self
            .lock()
            .down
            .as_ref()
            .map(|(_, sender)| sender.clone())
            .ok_or(MediaDownError::NotConnected)?;
        sender
            .blocking_send(frame)
            .map_err(|_| MediaDownError::NotConnected)
    }

    pub fn stats(&self) -> MediaStats {
        let state = self.lock();
        MediaStats {
            up_connected: state.up_conn.is_some(),
            down_connected: state.down.is_some(),
            up_frames: state.up_frames,
            up_dropped: state.up_dropped,
        }
    }

    /// Stop serving: revoke the token, close media connections, and wake
    /// [`recv_up`](Self::recv_up) waiters.
    pub fn close(&self) {
        let mut state = self.lock();
        state.closed = true;
        state.owners.clear();
        state.up_conn = None;
        state.down = None;
        drop(state);
        self.inner.up_ready.notify_all();
        self.bump();
    }

    fn revoke(&self, owner: u64) {
        let mut state = self.lock();
        let Some(index) = state.owners.iter().position(|(id, _)| *id == owner) else {
            return;
        };
        state.owners.remove(index);
        if index < state.owners.len() {
            return; // A replaced headset left; the current owner is unchanged.
        }
        state.up_conn = None;
        state.down = None;
        drop(state);
        self.bump();
    }

    fn install_up(&self, token: Option<&str>) -> Option<u64> {
        let mut state = self.lock();
        if !state.token_matches(token) {
            return None;
        }
        let conn = state.next_id();
        state.up_conn = Some(conn);
        drop(state);
        self.bump();
        Some(conn)
    }

    fn push_up(&self, conn: u64, frame: MediaFrame) -> bool {
        let mut state = self.lock();
        if state.up_conn != Some(conn) {
            return false;
        }
        state.enqueue(frame);
        drop(state);
        self.inner.up_ready.notify_all();
        true
    }

    fn install_down(&self, token: Option<&str>, sender: mpsc::Sender<MediaFrame>) -> Option<u64> {
        let mut state = self.lock();
        if !state.token_matches(token) {
            return None;
        }
        let conn = state.next_id();
        state.down = Some((conn, sender));
        drop(state);
        self.bump();
        Some(conn)
    }

    fn up_is_current(&self, conn: u64) -> bool {
        self.lock().up_conn == Some(conn)
    }

    fn down_is_current(&self, conn: u64) -> bool {
        self.lock().down.as_ref().map(|(id, _)| *id) == Some(conn)
    }

    fn release(&self, conn: u64) {
        let mut state = self.lock();
        if state.up_conn == Some(conn) {
            state.up_conn = None;
        }
        if state.down.as_ref().map(|(id, _)| *id) == Some(conn) {
            state.down = None;
        }
    }
}

/// One headset ctrl connection's claim on the media transport.
pub(crate) struct MediaAttachment {
    channels: MediaChannels,
    owner: u64,
    transport: MediaTransport,
}

impl MediaAttachment {
    /// The `DeviceDescriptor.media` block for this connection.
    pub(crate) fn transport(&self) -> &MediaTransport {
        &self.transport
    }
}

impl Drop for MediaAttachment {
    fn drop(&mut self) {
        self.channels.revoke(self.owner);
    }
}

/// Bound `media_up` / `media_down` listeners.
pub struct MediaListeners {
    up: TcpListener,
    down: TcpListener,
}

impl MediaListeners {
    pub fn new(up: TcpListener, down: TcpListener) -> Self {
        Self { up, down }
    }

    /// Bind both ports on all interfaces; `None` when either port is 0
    /// (media disabled).
    pub async fn bind(up_port: u16, down_port: u16) -> Result<Option<Self>> {
        if up_port == 0 || down_port == 0 {
            return Ok(None);
        }
        let up = TcpListener::bind(("0.0.0.0", up_port))
            .await
            .with_context(|| format!("binding media_up TCP port {up_port}"))?;
        let down = TcpListener::bind(("0.0.0.0", down_port))
            .await
            .with_context(|| format!("binding media_down TCP port {down_port}"))?;
        Ok(Some(Self { up, down }))
    }
}

async fn accept_loop<F, Fut>(
    listener: TcpListener,
    channels: MediaChannels,
    handle: F,
) -> Result<()>
where
    F: Fn(TcpStream, SocketAddr, MediaChannels) -> Fut,
    Fut: Future<Output = Result<()>> + Send + 'static,
{
    // Connection tasks are aborted with the relay.
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                // One bad connection must never end the host session's relay.
                let (socket, addr) = match accepted {
                    Ok(accepted) => accepted,
                    Err(error) => {
                        tracing::warn!("media accept failed: {error}");
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                };
                if let Err(error) = socket.set_nodelay(true) {
                    tracing::warn!("media connection from {addr} dropped: {error}");
                    continue;
                }
                let connection = handle(socket, addr, channels.clone());
                connections.spawn(async move {
                    if let Err(error) = connection.await {
                        tracing::warn!("media connection from {addr} closed: {error:#}");
                    }
                });
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

async fn read_handshake<R: AsyncRead + Unpin>(
    frames: &mut FramedRead<R, OlcpCodec>,
    what: &str,
) -> Result<MediaFrame> {
    match tokio::time::timeout(AUTH_TIMEOUT, frames.next()).await {
        Ok(Some(frame)) => Ok(frame?),
        Ok(None) => bail!("connection closed before {what}"),
        Err(_) => bail!("no {what} within {AUTH_TIMEOUT:?}"),
    }
}

fn auth_token(value: &serde_json::Value) -> Option<&str> {
    value.get("auth_token").and_then(serde_json::Value::as_str)
}

async fn handle_up(socket: TcpStream, addr: SocketAddr, channels: MediaChannels) -> Result<()> {
    let mut changes = channels.inner.changed.subscribe();
    let mut frames = FramedRead::new(socket, OlcpCodec::new(MAX_SESSION_START_PAYLOAD));
    let first = read_handshake(&mut frames, "session_start").await?;
    ensure!(
        first.frame_type == TYPE_SESSION_START,
        "first media_up frame must be session_start, got type {}",
        first.frame_type
    );
    let token = first.json();
    let conn = channels
        .install_up(token.as_ref().and_then(auth_token))
        .ok_or_else(|| anyhow!("media_up session_start auth_token rejected"))?;
    changes.borrow_and_update();
    frames.decoder_mut().max_payload = MAX_MEDIA_PAYLOAD;
    tracing::info!("media_up connected from {addr}");
    let result: Result<()> = async {
        if !channels.push_up(conn, first) {
            return Ok(());
        }
        loop {
            tokio::select! {
                frame = frames.next() => match frame {
                    Some(frame) => {
                        if !channels.push_up(conn, frame?) {
                            return Ok(());
                        }
                    }
                    None => return Ok(()),
                },
                changed = changes.changed() => {
                    if changed.is_err() || !channels.up_is_current(conn) {
                        return Ok(());
                    }
                }
            }
        }
    }
    .await;
    channels.release(conn);
    tracing::info!("media_up disconnected from {addr}");
    result
}

async fn handle_down(socket: TcpStream, addr: SocketAddr, channels: MediaChannels) -> Result<()> {
    let mut changes = channels.inner.changed.subscribe();
    let (read_half, write_half) = socket.into_split();
    let mut reader = FramedRead::new(read_half, OlcpCodec::new(MAX_RESULT_HELLO_PAYLOAD));
    let mut writer = FramedWrite::new(write_half, OlcpCodec::default());
    let hello = read_handshake(&mut reader, "result_hello").await?;
    ensure!(
        hello.frame_type == TYPE_RESULT_HELLO,
        "expected result_hello, got frame type {}",
        hello.frame_type
    );
    let hello = hello
        .json()
        .ok_or_else(|| anyhow!("result_hello payload must be a JSON object"))?;
    ensure!(
        hello.get("schema").and_then(serde_json::Value::as_str) == Some(RESULT_HELLO_SCHEMA),
        "unsupported result_hello schema"
    );
    let token = auth_token(&hello);
    ensure!(
        channels.lock().token_matches(token),
        "media_down result_hello auth_token rejected"
    );
    let welcome = serde_json::json!({
        "schema": RESULT_WELCOME_SCHEMA,
        "protocol": "operator.live_feed.v2",
        "server_instance_id": channels.inner.server_instance_id,
    });
    writer
        .send(MediaFrame::new(
            TYPE_RESULT_WELCOME,
            0,
            0,
            0,
            serde_json::to_vec(&welcome)?,
        ))
        .await?;
    let (sender, mut outbound) = mpsc::channel(DOWN_QUEUE_FRAMES);
    let conn = channels
        .install_down(token, sender)
        .ok_or_else(|| anyhow!("media_down owner changed during handshake"))?;
    changes.borrow_and_update();
    tracing::info!("media_down connected from {addr}");
    let result: Result<()> = async {
        loop {
            tokio::select! {
                frame = outbound.recv() => {
                    let Some(frame) = frame else { return Ok(()) };
                    match tokio::time::timeout(DOWN_WRITE_TIMEOUT, writer.send(frame)).await {
                        Ok(sent) => sent?,
                        Err(_) => bail!("media_down write stalled for {DOWN_WRITE_TIMEOUT:?}"),
                    }
                }
                // The result channel carries nothing upstream after the
                // hello; reading only detects the headset closing it.
                incoming = reader.next() => match incoming {
                    Some(incoming) => { incoming?; }
                    None => return Ok(()),
                },
                changed = changes.changed() => {
                    if changed.is_err() || !channels.down_is_current(conn) {
                        return Ok(());
                    }
                }
            }
        }
    }
    .await;
    channels.release(conn);
    tracing::info!("media_down disconnected from {addr}");
    result
}

/// Constant-time token comparison.
fn tokens_match(expected: &str, supplied: &str) -> bool {
    expected.len() == supplied.len()
        && expected
            .bytes()
            .zip(supplied.bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

/// URL-safe (hex) random string of `bytes` random bytes.
fn random_hex(bytes: usize) -> Option<String> {
    let mut buffer = vec![0u8; bytes];
    if let Err(error) = getrandom::getrandom(&mut buffer) {
        tracing::warn!("cannot generate media token: {error}");
        return None;
    }
    Some(buffer.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(frame_type: u8, size: usize) -> MediaFrame {
        MediaFrame::new(frame_type, 0, frame_type as u64, 0, vec![0u8; size])
    }

    fn encode(frame: MediaFrame) -> BytesMut {
        let mut buffer = BytesMut::new();
        OlcpCodec::default().encode(frame, &mut buffer).unwrap();
        buffer
    }

    #[test]
    fn codec_matches_the_python_header_layout_and_round_trips() {
        let frame = MediaFrame::new(
            TYPE_RGB_PACKET,
            0x0102,
            0x0102_0304_0506_0708,
            9,
            &b"ab"[..],
        );
        let bytes = encode(frame.clone());
        // Python: struct ">4sBBHQQI"
        assert_eq!(
            &bytes[..],
            b"OLCP\x01\x03\x01\x02\x01\x02\x03\x04\x05\x06\x07\x08\0\0\0\0\0\0\0\x09\0\0\0\x02ab"
        );
        // Partial input waits for more bytes, then yields the frame.
        let mut partial = BytesMut::from(&bytes[..OLCP_HEADER_LEN + 1]);
        assert_eq!(OlcpCodec::default().decode(&mut partial).unwrap(), None);
        partial.extend_from_slice(&bytes[OLCP_HEADER_LEN + 1..]);
        assert_eq!(
            OlcpCodec::default().decode(&mut partial).unwrap(),
            Some(frame)
        );
        assert!(partial.is_empty());
    }

    #[test]
    fn codec_rejects_bad_magic_version_and_oversized_payloads() {
        let good = encode(frame(TYPE_HEAD_POSE, 8));
        let mut bad_magic = good.clone();
        bad_magic[0] = b'X';
        assert!(OlcpCodec::default().decode(&mut bad_magic).is_err());
        let mut bad_version = good.clone();
        bad_version[4] = 2;
        assert!(OlcpCodec::default().decode(&mut bad_version).is_err());
        // Rejected from the header alone, before the payload arrives.
        let mut header_only = BytesMut::from(&good[..OLCP_HEADER_LEN]);
        let error = OlcpCodec::new(4).decode(&mut header_only).unwrap_err();
        assert!(error.to_string().contains("too large"));
        assert!(OlcpCodec::new(4)
            .encode(frame(TYPE_HEAD_POSE, 5), &mut BytesMut::new())
            .is_err());
    }

    #[test]
    fn full_queue_sheds_oldest_droppable_frames_only() {
        let mut state = State::default();
        state.enqueue(frame(TYPE_SESSION_START, 1));
        state.enqueue(frame(TYPE_RGB_CSD, 1));
        state.enqueue(frame(TYPE_DEPTH_METADATA, 1));
        for _ in 0..UP_QUEUE_FRAMES {
            state.enqueue(frame(TYPE_RGB_PACKET, 1));
        }
        state.enqueue(frame(TYPE_SESSION_END, 1));
        assert_eq!(state.queue.len(), UP_QUEUE_FRAMES);
        assert_eq!(state.up_dropped, 4);
        assert_eq!(state.up_frames, UP_QUEUE_FRAMES as u64 + 4);
        let types: Vec<u8> = state.queue.iter().map(|frame| frame.frame_type).collect();
        assert_eq!(
            &types[..3],
            [TYPE_SESSION_START, TYPE_RGB_CSD, TYPE_DEPTH_METADATA]
        );
        assert_eq!(types.last(), Some(&TYPE_SESSION_END));

        // Protected frames overflow instead of being dropped.
        let mut protected = State::default();
        for _ in 0..=UP_QUEUE_FRAMES {
            protected.enqueue(frame(TYPE_SESSION_START, 1));
        }
        assert_eq!(protected.queue.len(), UP_QUEUE_FRAMES + 1);
        assert_eq!(protected.up_dropped, 0);

        // The byte budget sheds too.
        let mut large = State::default();
        let big = UP_QUEUE_BYTES / 2;
        for _ in 0..3 {
            large.enqueue(frame(TYPE_DEPTH_FRAME, big));
        }
        assert_eq!(large.queue.len(), 2);
        assert_eq!(large.queued_bytes, 2 * big);
    }

    #[test]
    fn tokens_are_per_attachment_and_revoked_on_drop() {
        let channels = MediaChannels::new();
        assert!(channels.attach().is_none(), "not serving yet");
        channels.lock().ports = Some((63905, 63906));
        let first = channels.attach().unwrap();
        let token = first.transport().auth_token.clone();
        assert_eq!(token.len(), 2 * TOKEN_BYTES);
        assert!(token.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(first.transport().protocol, MEDIA_PROTOCOL);
        assert_eq!(
            (first.transport().push_port, first.transport().result_port),
            (63905, 63906)
        );
        assert!(channels.install_up(Some("wrong")).is_none());
        assert!(channels.install_up(None).is_none());
        let up = channels.install_up(Some(token.as_str())).unwrap();
        assert!(channels.stats().up_connected);

        // A newer headset takes over: the old token and connection are gone.
        let second = channels.attach().unwrap();
        assert_ne!(second.transport().auth_token, token);
        assert!(!channels.up_is_current(up));
        assert!(channels.install_up(Some(token.as_str())).is_none());
        // Dropping the replaced attachment does not revoke the new owner.
        drop(first);
        assert!(channels
            .install_up(Some(second.transport().auth_token.as_str()))
            .is_some());
        drop(second);
        assert!(!channels.stats().up_connected);
        assert!(channels.lock().owners.is_empty());
    }

    #[test]
    fn the_previous_headset_owns_the_session_again_when_the_newest_leaves() {
        let channels = MediaChannels::new();
        channels.lock().ports = Some((63905, 63906));
        let first = channels.attach().unwrap();
        let second = channels.attach().unwrap();
        let second_up = channels
            .install_up(Some(second.transport().auth_token.as_str()))
            .unwrap();
        drop(second);
        assert!(!channels.up_is_current(second_up));
        assert!(channels
            .install_up(Some(first.transport().auth_token.as_str()))
            .is_some());
    }

    #[test]
    fn attaching_a_new_headset_drops_the_previous_backlog() {
        let channels = MediaChannels::new();
        channels.lock().ports = Some((63905, 63906));
        let first = channels.attach().unwrap();
        {
            let mut state = channels.lock();
            state.enqueue(frame(TYPE_SESSION_START, 1));
            state.enqueue(frame(TYPE_RGB_PACKET, 4));
        }
        assert_eq!(channels.stats().up_frames, 2);

        // The host must not receive the previous headset's frames after the
        // new session_start: they would interleave two sessions.
        let _second = channels.attach().unwrap();
        assert_eq!(channels.recv_up(Some(Duration::from_millis(10))), None);
        let stats = channels.stats();
        assert_eq!(stats.up_dropped, 2, "the stale backlog is accounted for");
        assert_eq!(channels.lock().queued_bytes, 0);
        drop(first);
    }

    #[test]
    fn recv_up_times_out_and_close_wakes_waiters() {
        let channels = MediaChannels::new();
        assert_eq!(channels.recv_up(Some(Duration::from_millis(10))), None);
        let waiter = {
            let channels = channels.clone();
            std::thread::spawn(move || channels.recv_up(None))
        };
        std::thread::sleep(Duration::from_millis(20));
        channels.close();
        assert_eq!(waiter.join().unwrap(), None);
        assert!(channels.attach().is_none());
        assert_eq!(
            channels.send_down(frame(TYPE_HEAD_POSE, 1)),
            Err(MediaDownError::NotConnected)
        );
        assert_eq!(
            channels.send_down(frame(TYPE_HEAD_POSE, MAX_MEDIA_PAYLOAD + 1)),
            Err(MediaDownError::TooLarge(MAX_MEDIA_PAYLOAD + 1))
        );
    }
}
