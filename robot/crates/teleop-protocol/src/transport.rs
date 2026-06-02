//! Connection abstraction for the bridge<->adapter boundary.
//!
//! Both sides want to do `Framed::new(conn, codec)` without caring whether the
//! underlying transport is a Unix domain socket or a TCP socket. To make that
//! possible this module exposes:
//!
//! * [`Endpoint`] — where to listen / connect, parseable from a string like
//!   `"uds:/tmp/teleop-adapter.sock"` or `"tcp:127.0.0.1:63910"`.
//! * [`Conn`] — an enum that owns either a `UnixStream` or a `TcpStream` and
//!   implements `AsyncRead`/`AsyncWrite` by delegating to the inner stream.
//! * [`listen`] / [`Listener`] — bind + accept loop.
//! * [`connect`] — dial an endpoint, returning a [`Conn`].
//!
//! UDS is supported on Linux and macOS (the two target platforms).

use std::io;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::str::FromStr;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};

/// Default UDS path used when no endpoint is configured.
pub const DEFAULT_UDS_PATH: &str = "/tmp/teleop-adapter.sock";

/// Where the adapter protocol is reachable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Endpoint {
    /// Unix domain socket at the given filesystem path.
    Uds(PathBuf),
    /// TCP socket at the given address.
    Tcp(SocketAddr),
}

impl Default for Endpoint {
    fn default() -> Self {
        Endpoint::Uds(PathBuf::from(DEFAULT_UDS_PATH))
    }
}

/// Error returned when an [`Endpoint`] string fails to parse.
#[derive(Debug, thiserror::Error)]
pub enum EndpointParseError {
    #[error("missing scheme; expected 'uds:<path>' or 'tcp:<addr>', got {0:?}")]
    MissingScheme(String),
    #[error("unknown scheme {scheme:?}; expected 'uds' or 'tcp'")]
    UnknownScheme { scheme: String },
    #[error("empty uds path")]
    EmptyUdsPath,
    #[error("invalid tcp address {addr:?}: {source}")]
    InvalidTcpAddr {
        addr: String,
        source: std::net::AddrParseError,
    },
}

impl FromStr for Endpoint {
    type Err = EndpointParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let (scheme, rest) = s
            .split_once(':')
            .ok_or_else(|| EndpointParseError::MissingScheme(s.to_string()))?;
        match scheme {
            "uds" => {
                if rest.is_empty() {
                    return Err(EndpointParseError::EmptyUdsPath);
                }
                Ok(Endpoint::Uds(PathBuf::from(rest)))
            }
            "tcp" => {
                let addr = rest.parse::<SocketAddr>().map_err(|source| {
                    EndpointParseError::InvalidTcpAddr {
                        addr: rest.to_string(),
                        source,
                    }
                })?;
                Ok(Endpoint::Tcp(addr))
            }
            other => Err(EndpointParseError::UnknownScheme {
                scheme: other.to_string(),
            }),
        }
    }
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Endpoint::Uds(path) => write!(f, "uds:{}", path.display()),
            Endpoint::Tcp(addr) => write!(f, "tcp:{addr}"),
        }
    }
}

/// A transport-agnostic connection. Implements `AsyncRead` + `AsyncWrite` by
/// delegating to the underlying stream, so it plugs straight into
/// `tokio_util::codec::Framed`.
#[derive(Debug)]
pub enum Conn {
    Uds(UnixStream),
    Tcp(TcpStream),
}

impl AsyncRead for Conn {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Conn::Uds(s) => Pin::new(s).poll_read(cx, buf),
            Conn::Tcp(s) => Pin::new(s).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Conn {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.get_mut() {
            Conn::Uds(s) => Pin::new(s).poll_write(cx, buf),
            Conn::Tcp(s) => Pin::new(s).poll_write(cx, buf),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Conn::Uds(s) => Pin::new(s).poll_flush(cx),
            Conn::Tcp(s) => Pin::new(s).poll_flush(cx),
        }
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match self.get_mut() {
            Conn::Uds(s) => Pin::new(s).poll_shutdown(cx),
            Conn::Tcp(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}

/// A bound listener that accepts [`Conn`]s, regardless of transport.
#[derive(Debug)]
pub enum Listener {
    Uds(UnixListener),
    Tcp(TcpListener),
}

impl Listener {
    /// The endpoint this listener is actually bound to.
    ///
    /// For TCP this reflects the OS-assigned port (useful when the caller asked
    /// for an ephemeral `:0` port); for UDS it is the bound path.
    pub fn endpoint(&self) -> Endpoint {
        match self {
            Listener::Uds(l) => {
                // local_addr -> SocketAddr; recover the path if present.
                let path = l
                    .local_addr()
                    .ok()
                    .and_then(|a| a.as_pathname().map(|p| p.to_path_buf()))
                    .unwrap_or_else(|| PathBuf::from(DEFAULT_UDS_PATH));
                Endpoint::Uds(path)
            }
            Listener::Tcp(l) => Endpoint::Tcp(
                l.local_addr()
                    .unwrap_or_else(|_| "0.0.0.0:0".parse().unwrap()),
            ),
        }
    }

    /// Accept the next inbound connection.
    pub async fn accept(&self) -> io::Result<Conn> {
        match self {
            Listener::Uds(l) => {
                let (stream, _addr) = l.accept().await?;
                Ok(Conn::Uds(stream))
            }
            Listener::Tcp(l) => {
                let (stream, _addr) = l.accept().await?;
                Ok(Conn::Tcp(stream))
            }
        }
    }
}

/// Bind a [`Listener`] at `endpoint`.
///
/// For UDS, a stale socket file at the path is removed first (so restarts don't
/// fail with `EADDRINUSE`).
pub async fn listen(endpoint: &Endpoint) -> io::Result<Listener> {
    match endpoint {
        Endpoint::Uds(path) => {
            // Best-effort cleanup of a stale socket file.
            if path.exists() {
                let _ = std::fs::remove_file(path);
            }
            let listener = UnixListener::bind(path)?;
            Ok(Listener::Uds(listener))
        }
        Endpoint::Tcp(addr) => {
            let listener = TcpListener::bind(addr).await?;
            Ok(Listener::Tcp(listener))
        }
    }
}

/// Dial `endpoint`, returning a connected [`Conn`].
pub async fn connect(endpoint: &Endpoint) -> io::Result<Conn> {
    match endpoint {
        Endpoint::Uds(path) => {
            let stream = UnixStream::connect(path).await?;
            Ok(Conn::Uds(stream))
        }
        Endpoint::Tcp(addr) => {
            let stream = TcpStream::connect(addr).await?;
            Ok(Conn::Tcp(stream))
        }
    }
}
