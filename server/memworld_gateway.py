#!/usr/bin/env python3
"""Quest pose gateway, MemWorld scheduler, QR page, and live dashboard."""

from __future__ import annotations

import argparse
import asyncio
import base64
from copy import deepcopy
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
import secrets
from threading import Lock, Thread
import time
from typing import Any

from PIL import Image
import qrcode

if __package__ in (None, ""):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from server.memworld_chunks import (
    LatestWindowQueue,
    ProjectedSample,
)
from server.memworld_geometry import CameraCalibration, render_hand_skeleton
from server.memworld_worker_client import (
    MemWorldNVStreamClient,
    MemWorldWorkerClient,
    WorkerResult,
    build_worker_client,
)
from server.pose_inference_protocol import pack_image_frame


MAX_POSE_JSON_BYTES = 256 * 1024
POSE_STALE_NS = 500_000_000
FRAMES_PER_CHUNK = 17
NEW_FRAMES_PER_CHUNK = FRAMES_PER_CHUNK - 1
CAPTURE_HZ = 20.0
CHUNK_DURATION_SECONDS = NEW_FRAMES_PER_CHUNK / CAPTURE_HZ
PROJECTION_HZ = CAPTURE_HZ
MODEL_FPS = CAPTURE_HZ
PLAYBACK_FPS = CAPTURE_HZ
PREVIEW_HZ = CAPTURE_HZ


def configure_capture_hz(capture_hz: float) -> None:
    """Apply the workstation-selected cadence to capture, output and playback."""
    value = float(capture_hz)
    if not 1.0 <= value <= 120.0:
        raise ValueError("capture_hz must be in [1,120]")
    global CAPTURE_HZ, CHUNK_DURATION_SECONDS, PROJECTION_HZ
    global MODEL_FPS, PLAYBACK_FPS, PREVIEW_HZ
    CAPTURE_HZ = value
    CHUNK_DURATION_SECONDS = NEW_FRAMES_PER_CHUNK / value
    PROJECTION_HZ = value
    MODEL_FPS = value
    PLAYBACK_FPS = value
    PREVIEW_HZ = value


def build_qr_payload(websocket_url: str, token: str) -> dict[str, str]:
    return {"mode": "memWorld", "url": websocket_url, "token": token}


def is_websocket_path(path: str) -> bool:
    return path == "/memworld"


def validate_client_message(
    message: dict[str, Any],
    token: str,
) -> tuple[str, CameraCalibration | None]:
    if not isinstance(message, dict):
        raise ValueError("message must be an object")
    message_type = message.get("type")
    if message_type == "hello":
        if not secrets.compare_digest(str(message.get("token", "")), token):
            raise ValueError("invalid token")
        if message.get("protocol") != "operator.memworld.v1":
            raise ValueError("unsupported Quest memWorld protocol")
        return "hello", CameraCalibration.from_json(message.get("calibration"))
    if message_type == "pose":
        if not isinstance(message.get("frame_id"), int):
            raise ValueError("pose requires integer frame_id")
        if not isinstance(message.get("capture_time_ns"), int):
            raise ValueError("pose requires integer capture_time_ns")
        return "pose", None
    raise ValueError("unsupported message type")


class DashboardState:
    def __init__(self) -> None:
        self._lock = Lock()
        self._status: dict[str, Any] = {
            "quest": "waiting",
            "worker": "offline",
            "worker_error": "",
            "pose_rx_hz": 0.0,
            "preview_tx_hz": 0.0,
            "pose_to_projection_ms": 0.0,
            "window_fill": 0,
            "running_chunk": None,
            "pending_chunk": None,
            "skipped_chunks": 0,
            "skipped_samples": 0,
            "skeleton_frame_id": None,
            "output_chunk_id": None,
            "playing_chunk_id": None,
            "model_frame_index": None,
            "model_frame_count": 0,
            "model_playback_fps": PLAYBACK_FPS,
            "inference_ms": None,
            "jpeg_encode_ms": None,
            "frame_zip_bytes": None,
            "frame_zip_receive_ms": None,
            "frame_zip_unpack_ms": None,
            "output_first_frame_id": None,
            "output_last_frame_id": None,
            "output_age_ms": None,
        }
        self._skeleton = b""
        self._model_frames: tuple[bytes, ...] = ()
        self._model_started_at = 0.0
        self._model_playback_fps = PLAYBACK_FPS

    def update_status(self, **values: Any) -> None:
        with self._lock:
            self._status.update(values)

    def update_skeleton(self, jpeg: bytes, *, frame_id: int) -> None:
        with self._lock:
            self._skeleton = bytes(jpeg)
            self._status["skeleton_frame_id"] = int(frame_id)

    def update_model_frames(
        self,
        frames: tuple[bytes, ...],
        *,
        chunk_id: int,
        inference_ms: float,
        playback_fps: float,
        started_at: float | None = None,
        drop_first_frame: bool = False,
        **values: Any,
    ) -> None:
        if len(frames) not in {
            NEW_FRAMES_PER_CHUNK,
            FRAMES_PER_CHUNK,
        }:
            raise ValueError(
                "model playback requires 16 new frames or 17 "
                f"anchor-overlapped frames, "
                f"got {len(frames)}"
            )
        if playback_fps <= 0:
            raise ValueError("model playback FPS must be greater than zero")
        with self._lock:
            playback_frames = frames[1:] if drop_first_frame else frames
            if not playback_frames:
                raise ValueError("model playback has no frames after anchor removal")
            self._model_frames = tuple(bytes(frame) for frame in playback_frames)
            self._model_started_at = (
                time.monotonic() if started_at is None else float(started_at)
            )
            self._model_playback_fps = float(playback_fps)
            self._status.update(values)
            self._status["output_chunk_id"] = int(chunk_id)
            self._status["playing_chunk_id"] = int(chunk_id)
            self._status["model_frame_index"] = 0
            self._status["model_frame_count"] = len(self._model_frames)
            self._status["model_playback_fps"] = self._model_playback_fps
            self._status["inference_ms"] = float(inference_ms)

    def _model_frame_locked(self, now: float) -> bytes:
        if not self._model_frames:
            return b""
        elapsed = max(0.0, now - self._model_started_at)
        index = min(
            int(elapsed * self._model_playback_fps),
            len(self._model_frames) - 1,
        )
        self._status["model_frame_index"] = index
        return self._model_frames[index]

    def status_json(self, *, now: float | None = None) -> str:
        with self._lock:
            self._model_frame_locked(time.monotonic() if now is None else now)
            return json.dumps(self._status, separators=(",", ":"), ensure_ascii=False)

    def skeleton(self) -> bytes:
        with self._lock:
            return self._skeleton

    def model_frame(self, *, now: float | None = None) -> bytes:
        with self._lock:
            return self._model_frame_locked(
                time.monotonic() if now is None else now
            )


def dashboard_html(config: dict[str, str]) -> bytes:
    config_text = json.dumps(config, separators=(",", ":"))
    qr = qrcode.make(config_text)
    output = io.BytesIO()
    qr.save(output, format="PNG")
    qr_data = base64.b64encode(output.getvalue()).decode("ascii")
    template = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MemWorld · Live Inference</title>
<style>
:root {
  color-scheme: dark;
  --ink: #f4f8ff;
  --muted: #8797ae;
  --faint: #526279;
  --line: rgba(132,186,255,.18);
  --panel: rgba(12,20,33,.84);
  --blue: #75bcff;
  --green: #69f0b3;
  --red: #ff7c8f;
  --shadow: 0 24px 80px rgba(0,0,0,.44);
}
* { box-sizing: border-box; }
html { min-width: 320px; background: #070b12; }
body {
  min-height: 100vh;
  margin: 0;
  color: var(--ink);
  background:
    radial-gradient(circle at 78% -12%,rgba(59,141,235,.22),transparent 39%),
    radial-gradient(circle at -8% 105%,rgba(23,91,132,.13),transparent 34%),
    linear-gradient(145deg,#0d1421 0%,#080c13 48%,#06090e 100%);
  font-family: Bahnschrift,"Aptos Narrow","Segoe UI Variable",sans-serif;
  letter-spacing: .01em;
}
body::before {
  position: fixed;
  inset: 0;
  z-index: -1;
  pointer-events: none;
  opacity: .3;
  background-image:
    linear-gradient(rgba(153,197,255,.025) 1px,transparent 1px),
    linear-gradient(90deg,rgba(153,197,255,.025) 1px,transparent 1px);
  background-size: 38px 38px;
  mask-image: linear-gradient(to bottom,black,transparent 72%);
  content: "";
}
.shell {
  width: min(1680px,calc(100% - 48px));
  margin: 0 auto;
  padding: 28px 0 44px;
}
.masthead {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 24px;
  margin-bottom: 18px;
}
.eyebrow {
  margin: 0 0 7px;
  color: var(--blue);
  font-size: 11px;
  font-weight: 600;
  letter-spacing: .2em;
  text-transform: uppercase;
}
h1 {
  margin: 0;
  font-size: clamp(25px,3vw,48px);
  font-weight: 480;
  line-height: .96;
  letter-spacing: -.045em;
}
.route {
  margin: 9px 0 0;
  color: var(--muted);
  font: 11px "Cascadia Mono","SFMono-Regular",monospace;
}
.state-cluster {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 8px;
}
.state-chip {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 32px;
  padding: 0 12px;
  border: 1px solid var(--line);
  border-radius: 4px;
  color: var(--muted);
  background: rgba(9,15,25,.64);
  font: 10px "Cascadia Mono",monospace;
  letter-spacing: .08em;
  text-transform: uppercase;
}
.state-chip::before {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--faint);
  content: "";
}
.state-chip.online {
  color: #dfffee;
  border-color: rgba(105,240,179,.3);
}
.state-chip.online::before {
  background: var(--green);
  box-shadow: 0 0 13px rgba(105,240,179,.85);
}
.stage {
  display: grid;
  grid-template-columns: minmax(0,2.48fr) minmax(300px,.82fr);
  gap: 14px;
  align-items: stretch;
}
.panel {
  position: relative;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 7px;
  background: linear-gradient(145deg,rgba(17,28,46,.9),rgba(7,12,20,.92));
  box-shadow: var(--shadow);
}
.panel::after {
  position: absolute;
  inset: 0;
  z-index: 2;
  pointer-events: none;
  border-radius: inherit;
  box-shadow: inset 0 1px rgba(255,255,255,.035);
  content: "";
}
.panel-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 46px;
  padding: 0 14px;
  border-bottom: 1px solid var(--line);
  background: rgba(10,17,28,.82);
}
.panel-title {
  display: flex;
  align-items: center;
  gap: 9px;
  margin: 0;
  font-size: 11px;
  font-weight: 570;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.panel-title::before {
  width: 3px;
  height: 14px;
  border-radius: 2px;
  background: var(--blue);
  box-shadow: 0 0 12px rgba(117,188,255,.5);
  content: "";
}
.panel-note {
  color: var(--faint);
  font: 9px "Cascadia Mono",monospace;
  letter-spacing: .08em;
}
.viewport {
  position: relative;
  aspect-ratio: 640/352;
  overflow: hidden;
  background:
    radial-gradient(circle at 50% 42%,rgba(72,116,166,.12),transparent 42%),
    #04070b;
}
.viewport img {
  position: relative;
  z-index: 1;
  display: block;
  width: 100%;
  height: 100%;
  object-fit: contain;
  opacity: 0;
  transition: opacity .24s ease;
}
.viewport img.ready { opacity: 1; }
.placeholder {
  position: absolute;
  inset: 0;
  display: grid;
  place-content: center;
  gap: 9px;
  color: #52657c;
  text-align: center;
  font: 10px "Cascadia Mono",monospace;
  letter-spacing: .14em;
  text-transform: uppercase;
}
.placeholder::before {
  width: 24px;
  height: 24px;
  margin: auto;
  border: 1px solid #3a4d63;
  border-top-color: var(--blue);
  border-radius: 50%;
  animation: spin 1.4s linear infinite;
  content: "";
}
@keyframes spin { to { transform: rotate(360deg); } }
.hero-foot {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 41px;
  padding: 0 14px;
  border-top: 1px solid var(--line);
  color: var(--faint);
  background: rgba(7,12,20,.88);
  font: 9px "Cascadia Mono",monospace;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.rail {
  display: grid;
  grid-template-rows: auto 1fr;
  gap: 14px;
  min-width: 0;
}
.pose-panel .panel-head { min-height: 40px; }
.telemetry {
  display: flex;
  flex-direction: column;
  min-height: 0;
  padding: 15px;
}
.telemetry-label {
  margin: 0 0 12px;
  color: var(--muted);
  font-size: 10px;
  letter-spacing: .15em;
  text-transform: uppercase;
}
.metrics {
  display: grid;
  gap: 8px;
}
.metric {
  position: relative;
  overflow: hidden;
  min-height: 84px;
  padding: 13px 12px 11px;
  border: 1px solid rgba(132,186,255,.14);
  border-radius: 5px;
  background:
    linear-gradient(100deg,rgba(61,128,204,.11),transparent 78%),
    rgba(16,28,46,.6);
}
.metric::before {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: 2px;
  background: var(--blue);
  content: "";
}
.metric-name {
  color: var(--muted);
  font-size: 9px;
  font-weight: 570;
  letter-spacing: .11em;
  text-transform: uppercase;
}
.metric-value {
  display: block;
  margin-top: 5px;
  font: 460 clamp(22px,2.2vw,34px)/1 "Cascadia Mono",monospace;
  letter-spacing: -.06em;
}
.metric-unit {
  margin-left: 5px;
  color: var(--blue);
  font-size: 10px;
  letter-spacing: .04em;
}
.telemetry-note {
  margin: auto 0 0;
  padding-top: 14px;
  border-top: 1px solid var(--line);
  color: var(--faint);
  font: 9px/1.6 "Cascadia Mono",monospace;
  letter-spacing: .04em;
  text-transform: uppercase;
}
.error {
  display: none;
  margin-top: 14px;
  padding: 11px 14px;
  border: 1px solid rgba(255,124,143,.32);
  border-left: 3px solid var(--red);
  border-radius: 4px;
  color: #ffd9df;
  background: rgba(89,23,34,.35);
  font: 11px/1.5 "Cascadia Mono",monospace;
}
.error.visible { display: block; }
.pairing {
  display: grid;
  grid-template-columns: auto minmax(0,1fr) auto;
  align-items: center;
  gap: 22px;
  margin-top: 14px;
  padding: 18px 22px;
  border: 1px solid var(--line);
  border-radius: 7px;
  background:
    linear-gradient(90deg,rgba(33,71,115,.16),transparent 44%),
    rgba(9,15,24,.84);
  box-shadow: 0 18px 55px rgba(0,0,0,.3);
}
.qr-shell {
  padding: 7px;
  border-radius: 4px;
  background: white;
  box-shadow: 0 0 32px rgba(117,188,255,.17);
}
.qr-shell img {
  display: block;
  width: 128px;
  height: 128px;
}
.pairing h2 {
  margin: 0;
  font-size: clamp(20px,2.2vw,32px);
  font-weight: 470;
  letter-spacing: -.035em;
}
.pairing p {
  max-width: 620px;
  margin: 7px 0 0;
  color: var(--muted);
  font-size: 12px;
  line-height: 1.55;
}
.pairing-index {
  color: rgba(117,188,255,.16);
  font: 700 clamp(52px,7vw,96px)/.8 "Cascadia Mono",monospace;
  letter-spacing: -.1em;
}
@media (max-width:1060px) {
  .stage { grid-template-columns: 1fr; }
  .rail {
    grid-template-columns: minmax(0,1.1fr) minmax(300px,.9fr);
    grid-template-rows: none;
  }
}
@media (max-width:720px) {
  .shell { width: min(100% - 24px,1680px); padding-top: 18px; }
  .masthead { align-items: flex-start; flex-direction: column; }
  .state-cluster { justify-content: flex-start; }
  .rail { grid-template-columns: 1fr; }
  .pairing { grid-template-columns: auto 1fr; padding: 15px; }
  .qr-shell img { width: 96px; height: 96px; }
  .pairing-index { display: none; }
}
</style>
</head>
<body>
<main class="shell">
  <header class="masthead">
    <div>
      <p class="eyebrow">Live world model / demonstration</p>
      <h1>MemWorld inference</h1>
      <p class="route">QUEST → WORKSTATION → NV CLOUD</p>
    </div>
    <div class="state-cluster" aria-label="Connection status">
      <span id="quest-state" class="state-chip">Quest · waiting</span>
      <span id="worker-state" class="state-chip">NV worker · offline</span>
    </div>
  </header>

  <section class="stage" aria-label="Live inference stage">
    <article class="panel hero-panel">
      <header class="panel-head">
        <h2 class="panel-title">Generated world</h2>
        <span class="panel-note">RGB / 640×352</span>
      </header>
      <div class="viewport">
        <div class="placeholder">Awaiting generated frames</div>
        <img id="model-view" alt="Live generated RGB output">
      </div>
      <footer class="hero-foot">
        <span id="playback-label">Playback · —</span>
        <span id="age-label">Output age · —</span>
      </footer>
    </article>

    <aside class="rail">
      <article class="panel pose-panel">
        <header class="panel-head">
          <h2 class="panel-title">Hand pose RGB</h2>
          <span class="panel-note">PROJECTED INPUT</span>
        </header>
        <div class="viewport">
          <div class="placeholder">Awaiting Quest pose</div>
          <img id="pose-view" alt="Projected Quest hand pose input">
        </div>
      </article>

      <article class="panel telemetry">
        <p class="telemetry-label">Live telemetry</p>
        <div class="metrics">
          <div class="metric">
            <span class="metric-name">Pose update rate</span>
            <span id="pose-rate" class="metric-value">—<small class="metric-unit">Hz</small></span>
          </div>
          <div class="metric">
            <span class="metric-name">Inference throughput</span>
            <span id="inference-fps" class="metric-value">—<small class="metric-unit">FPS</small></span>
          </div>
          <div class="metric">
            <span class="metric-name">Send latency</span>
            <span id="send-latency" class="metric-value">—<small class="metric-unit">ms</small></span>
          </div>
        </div>
        <p class="telemetry-note">Pose receive → projection → cloud input<br>Newest completed model output replaces playback immediately</p>
      </article>
    </aside>
  </section>

  <div id="error-banner" class="error" role="alert"></div>

  <section class="pairing" aria-label="Quest pairing">
    <div class="qr-shell">
      <img id="pairing-qr" src="data:image/png;base64,__QR_DATA__" alt="Quest connection QR code">
    </div>
    <div>
      <p class="eyebrow">Pair headset</p>
      <h2>Scan with Operator on Quest</h2>
      <p>The QR code carries the authenticated live endpoint. Keep this page open while the headset connects and the model streams.</p>
    </div>
    <div class="pairing-index" aria-hidden="true">01</div>
  </section>
</main>

<script>
let lastSkeleton=null;
const modelView=document.getElementById("model-view");
const poseView=document.getElementById("pose-view");

function refreshModel(){
  modelView.src="/model.jpg?"+Date.now();
}
function formatMetric(value,digits=1){
  const number=Number(value);
  return Number.isFinite(number)&&number>0?number.toFixed(digits):"—";
}
function setMetric(id,value,unit){
  document.getElementById(id).innerHTML=
    `${formatMetric(value)}<small class="metric-unit">${unit}</small>`;
}
function setStateChip(id,label,value,onlineValues){
  const chip=document.getElementById(id);
  const normalized=String(value||"waiting").toLowerCase();
  chip.textContent=`${label} · ${normalized}`;
  chip.classList.toggle("online",onlineValues.includes(normalized));
}
async function tick(){
  try{
    const response=await fetch("/status.json?"+Date.now(),{cache:"no-store"});
    if(!response.ok)throw new Error(`status HTTP ${response.status}`);
    const status=await response.json();
    const frameCount=Number(status.model_frame_count||0);
    const inferenceMs=Number(status.inference_ms||0);
    const inferenceFps=inferenceMs>0?frameCount*1000/inferenceMs:null;
    setMetric("pose-rate",status.pose_rx_hz,"Hz");
    setMetric("inference-fps",inferenceFps,"FPS");
    setMetric("send-latency",status.pose_to_projection_ms,"ms");
    setStateChip("quest-state","Quest",status.quest,["connected","ready"]);
    setStateChip("worker-state","NV worker",status.worker,["ready","streaming"]);
    document.getElementById("playback-label").textContent=
      `Playback · ${formatMetric(status.model_playback_fps)} FPS`;
    document.getElementById("age-label").textContent=
      `Output age · ${formatMetric(status.output_age_ms)} ms`;
    if(status.skeleton_frame_id!==lastSkeleton){
      lastSkeleton=status.skeleton_frame_id;
      poseView.src="/skeleton.jpg?"+Date.now();
    }
    const error=status.worker_error||status.projection_error||"";
    const banner=document.getElementById("error-banner");
    banner.textContent=error;
    banner.classList.toggle("visible",Boolean(error));
  }catch(error){
    const banner=document.getElementById("error-banner");
    banner.textContent=`Dashboard status unavailable: ${error.message}`;
    banner.classList.add("visible");
  }
}
modelView.addEventListener("load",()=>modelView.classList.add("ready"));
modelView.addEventListener("error",()=>modelView.classList.remove("ready"));
poseView.addEventListener("load",()=>poseView.classList.add("ready"));
poseView.addEventListener("error",()=>poseView.classList.remove("ready"));
setInterval(refreshModel,1000/__PLAYBACK_FPS__);refreshModel();
setInterval(tick,500);tick();
</script>
</body>
</html>"""
    return (
        template.replace("__QR_DATA__", qr_data)
        .replace("__PLAYBACK_FPS__", str(PLAYBACK_FPS))
        .encode("utf-8")
    )


class DashboardHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], state: DashboardState, config: dict[str, str]):
        self.dashboard_state = state
        self.config = config
        super().__init__(address, DashboardRequestHandler)


class DashboardRequestHandler(BaseHTTPRequestHandler):
    server: DashboardHTTPServer

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def _send(self, status: HTTPStatus, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(HTTPStatus.OK, "text/html; charset=utf-8", dashboard_html(self.server.config))
        elif path == "/status.json":
            self._send(HTTPStatus.OK, "application/json", self.server.dashboard_state.status_json().encode("utf-8"))
        elif path == "/skeleton.jpg":
            payload = self.server.dashboard_state.skeleton()
            self._send(HTTPStatus.OK if payload else HTTPStatus.NOT_FOUND, "image/jpeg", payload or b"waiting")
        elif path == "/model.jpg":
            payload = self.server.dashboard_state.model_frame()
            self._send(HTTPStatus.OK if payload else HTTPStatus.NOT_FOUND, "image/jpeg", payload or b"waiting")
        else:
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"not found")


@dataclass
class PreviewFrame:
    frame_id: int
    capture_time_ns: int
    server_received_ns: int
    jpeg: bytes


class SessionState:
    def __init__(self) -> None:
        self.latest_pose: dict[str, Any] | None = None
        self.latest_preview: PreviewFrame | None = None
        self.pose_count = 0
        self.model_sample_count = 0
        self.preview_count = 0
        self.stats_started = time.monotonic()
        self.last_projection_ms = 0.0

    def accept_pose(self, message: dict[str, Any], *, received_ns: int) -> None:
        accepted = deepcopy(message)
        accepted["_server_received_ns"] = int(received_ns)
        self.latest_pose = accepted
        self.pose_count += 1

    def stats_if_due(self) -> dict[str, float] | None:
        now = time.monotonic()
        elapsed = now - self.stats_started
        if elapsed < 1.0:
            return None
        result = {
            "pose_rx_hz": round(self.pose_count / elapsed, 1),
            "model_sample_hz": round(self.model_sample_count / elapsed, 1),
            "preview_tx_hz": round(self.preview_count / elapsed, 1),
            "pose_to_projection_ms": round(self.last_projection_ms, 1),
        }
        self.pose_count = 0
        self.model_sample_count = 0
        self.preview_count = 0
        self.stats_started = now
        return result


def _encode_skeleton_png(image: Image.Image) -> bytes:
    output = io.BytesIO()
    image.save(output, format="PNG", compress_level=3)
    return output.getvalue()


def _encode_skeleton_jpeg(image: Image.Image) -> bytes:
    output = io.BytesIO()
    image.save(
        output,
        format="JPEG",
        quality=95,
        subsampling=0,
        optimize=False,
    )
    return output.getvalue()


async def projection_loop(
    state: SessionState,
    calibration: CameraCalibration,
    slot: LatestWindowQueue,
    dashboard: DashboardState,
) -> None:
    loop = asyncio.get_running_loop()
    next_at = loop.time()
    while True:
        await asyncio.sleep(max(0.0, next_at - loop.time()))
        next_at += 1.0 / PROJECTION_HZ
        if next_at < loop.time():
            next_at = loop.time()
        pose = state.latest_pose
        if pose is None:
            continue
        received_ns = int(pose["_server_received_ns"])
        if time.perf_counter_ns() - received_ns > POSE_STALE_NS:
            dashboard.update_status(quest="pose stale")
            continue
        try:
            rendered = await asyncio.to_thread(render_hand_skeleton, pose, calibration)
            png, jpeg = await asyncio.gather(
                asyncio.to_thread(
                    _encode_skeleton_png,
                    rendered.image,
                ),
                asyncio.to_thread(
                    _encode_skeleton_jpeg,
                    rendered.image,
                ),
            )
        except Exception as error:
            dashboard.update_status(projection_error=str(error))
            continue
        state.last_projection_ms = (time.perf_counter_ns() - received_ns) / 1_000_000
        state.latest_preview = PreviewFrame(
            frame_id=rendered.frame_id,
            capture_time_ns=rendered.capture_time_ns,
            server_received_ns=received_ns,
            jpeg=jpeg,
        )
        sample = ProjectedSample(
            frame_id=rendered.frame_id,
            capture_time_ns=rendered.capture_time_ns,
            server_received_ns=received_ns,
            calibration_id=rendered.calibration_id,
            c2w=rendered.model_c2w,
            keypoint_png=png,
        )
        slot.add(sample)
        state.model_sample_count += 1
        slot_status = slot.snapshot()
        dashboard.update_skeleton(jpeg, frame_id=rendered.frame_id)
        dashboard.update_status(
            quest="connected",
            calibration_id=calibration.calibration_id,
            tracked_joints=rendered.drawn_joints,
            **slot_status,
        )
        rates = state.stats_if_due()
        if rates is not None:
            dashboard.update_status(**rates)
            print(
                "MEMWORLD_STATS "
                + " ".join(f"{key}={value}" for key, value in rates.items())
                + f" frame_id={rendered.frame_id} "
                + f"window={slot_status['window_fill']}/{FRAMES_PER_CHUNK} "
                + f"running={slot_status['running_chunk']} pending={slot_status['pending_chunk']} "
                + f"skipped_samples={slot_status['skipped_samples']}",
                flush=True,
            )


async def preview_loop(
    connection: Any,
    state: SessionState,
    dashboard: DashboardState,
) -> None:
    loop = asyncio.get_running_loop()
    next_at = loop.time()
    while True:
        await asyncio.sleep(max(0.0, next_at - loop.time()))
        next_at += 1.0 / PREVIEW_HZ
        if next_at < loop.time():
            next_at = loop.time()
        pose = state.latest_pose
        if pose is None:
            continue
        received_ns = int(pose["_server_received_ns"])
        if time.perf_counter_ns() - received_ns > POSE_STALE_NS:
            continue
        jpeg = dashboard.model_frame()
        if not jpeg:
            continue
        await connection.send(pack_image_frame(
            int(pose["frame_id"]),
            int(pose["capture_time_ns"]),
            640,
            352,
            jpeg,
        ))
        state.preview_count += 1


async def websocket_handler(
    connection: Any,
    *,
    token: str,
    worker_url: str,
    initial_rgb: str,
    static_memory: str,
    dashboard: DashboardState,
    inference_options: dict[str, Any],
    ffmpeg_bin: str = (
        "/home/evophys/miniconda3/envs/"
        "memworld-egoquest/bin/ffmpeg"
    ),
    worker_session_chunks: int = 0,
) -> None:
    if not is_websocket_path(connection.request.path):
        await connection.close(1008, "use /memworld")
        return
    state = SessionState()
    # Model playback is connection-local. The HTTP dashboard remains shared,
    # but a Quest must never read frames produced for another Quest.
    session_dashboard = DashboardState()
    slot = LatestWindowQueue(
        frames_per_chunk=FRAMES_PER_CHUNK,
        stride=NEW_FRAMES_PER_CHUNK,
    )
    tasks: list[asyncio.Task[Any]] = []
    worker: MemWorldWorkerClient | MemWorldNVStreamClient | None = None
    authenticated = False
    calibration: CameraCalibration | None = None
    try:
        async for raw in connection:
            if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_POSE_JSON_BYTES:
                await connection.close(1003, "expected bounded JSON messages")
                return
            message = json.loads(raw)
            kind, parsed_calibration = validate_client_message(message, token)
            if kind == "hello":
                if authenticated:
                    await connection.close(1008, "hello already received")
                    return
                authenticated = True
                calibration = parsed_calibration
                session_id = f"quest-{secrets.token_hex(6)}"
                session_start = {
                    "type": "session.start",
                    "protocol": "memworld-live-v1",
                    "session_id": session_id,
                    "width": 640,
                    "height": 352,
                    "fps": MODEL_FPS,
                    "playback_fps": PLAYBACK_FPS,
                    "frames_per_chunk": FRAMES_PER_CHUNK,
                    "initial_rgb": initial_rgb,
                    "static_memory": [static_memory],
                    "ffmpeg_bin": ffmpeg_bin,
                    "worker_session_chunks": worker_session_chunks,
                    **inference_options,
                }
                worker = build_worker_client(
                    url=worker_url,
                    session_start=session_start,
                    slot=slot,
                    on_result=lambda result: _on_worker_result(
                        result,
                        session_dashboard,
                        mirror=dashboard,
                    ),
                    on_status=lambda status, error: _update_worker_status(
                        status,
                        error,
                        session_dashboard,
                        dashboard,
                    ),
                )
                tasks = [
                    asyncio.create_task(
                        projection_loop(
                            state,
                            calibration,
                            slot,
                            dashboard,
                        )
                    ),
                    asyncio.create_task(preview_loop(connection, state, session_dashboard)),
                    asyncio.create_task(worker.run()),
                ]
                dashboard.update_status(quest="connected", calibration_id=calibration.calibration_id)
                await connection.send(json.dumps({
                    "type": "ready",
                    "projection_hz": PROJECTION_HZ,
                    "playback_fps": PLAYBACK_FPS,
                    "preview_hz": PREVIEW_HZ,
                    "frames_per_chunk": FRAMES_PER_CHUNK,
                    "calibration_id": calibration.calibration_id,
                }, separators=(",", ":")))
                print(f"MEMWORLD_QUEST_CONNECTED calibration_id={calibration.calibration_id}", flush=True)
                continue
            if not authenticated:
                await connection.close(1008, "send hello before pose")
                return
            state.accept_pose(message, received_ns=time.perf_counter_ns())
    except (json.JSONDecodeError, ValueError) as error:
        await connection.close(1008, str(error))
    finally:
        dashboard.update_status(quest="disconnected")
        if worker is not None:
            worker.stop()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


def _update_worker_status(
    status: str,
    error: str | None,
    session_dashboard: DashboardState,
    shared_dashboard: DashboardState,
) -> None:
    values = {"worker": status, "worker_error": error}
    session_dashboard.update_status(**values)
    shared_dashboard.update_status(**values)


def _on_worker_result(
    result: WorkerResult,
    dashboard: DashboardState,
    *,
    mirror: DashboardState | None = None,
) -> None:
    metadata = result.metadata
    output_age_ms = None
    source_received_ns = metadata.get("_source_server_received_ns")
    if isinstance(source_received_ns, int):
        output_age_ms = round(
            (time.perf_counter_ns() - source_received_ns) / 1_000_000,
            1,
        )
    update_values = dict(
        chunk_id=result.chunk_id,
        inference_ms=float(metadata.get("inference_ms", 0.0)),
        playback_fps=float(metadata.get("fps", PLAYBACK_FPS)),
        drop_first_frame=bool(metadata.get("drop_first_frame", False)),
        jpeg_encode_ms=metadata.get("jpeg_encode_ms"),
        frame_zip_bytes=metadata.get("frame_zip_bytes"),
        frame_zip_receive_ms=metadata.get("frame_zip_receive_ms"),
        frame_zip_unpack_ms=metadata.get("frame_zip_unpack_ms"),
        mp4_bytes=metadata.get("mp4_bytes"),
        mp4_decode_ms=metadata.get("mp4_decode_ms"),
        worker_transport=metadata.get("transport", "websocket"),
        checkpoint_sha256=metadata.get("checkpoint_sha256"),
        temporal_kv=metadata.get("temporal_kv"),
        output_first_frame_id=metadata.get("first_frame_id"),
        output_last_frame_id=metadata.get("last_frame_id"),
        output_age_ms=output_age_ms,
    )
    dashboard.update_model_frames(result.frames, **update_values)
    if mirror is not None and mirror is not dashboard:
        mirror.update_model_frames(result.frames, **update_values)
    print(
        "MEMWORLD_OUTPUT "
        f"chunk={result.chunk_id} frames={len(result.frames)} "
        f"zip_bytes={metadata.get('frame_zip_bytes')} "
        f"jpeg_encode_ms={metadata.get('jpeg_encode_ms')} "
        f"zip_receive_ms={metadata.get('frame_zip_receive_ms')} "
        f"zip_unpack_ms={metadata.get('frame_zip_unpack_ms')} "
        f"inference_ms={metadata.get('inference_ms')}",
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=63920)
    parser.add_argument("--dashboard-port", type=int, default=63921)
    parser.add_argument("--public-host", required=True)
    parser.add_argument("--worker-url", default="ws://127.0.0.1:8765")
    parser.add_argument("--token", default=os.environ.get("MEMWORLD_TOKEN", ""))
    parser.add_argument(
        "--initial-rgb",
        default="/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg",
    )
    parser.add_argument(
        "--static-memory",
        default="/home/evophys/code/MemWorld-direct-dmd1000/anchor.jpg",
    )
    parser.add_argument("--num-inference-steps", type=int, default=4)
    parser.add_argument("--cfg-scale", type=float, default=1.0)
    parser.add_argument(
        "--ffmpeg-bin",
        default=(
            "/home/evophys/miniconda3/envs/"
            "memworld-egoquest/bin/ffmpeg"
        ),
    )
    parser.add_argument(
        "--capture-hz",
        type=float,
        default=float(os.environ.get("MEMWORLD_CAPTURE_HZ", "20")),
        help="Quest projection, NV encode and local playback cadence.",
    )
    parser.add_argument(
        "--worker-session-chunks",
        type=int,
        default=0,
        help="0 keeps one generated-memory session until disconnect.",
    )
    parser.add_argument("--print-config", action="store_true")
    return parser.parse_args()


async def main() -> None:
    args = parse_args()
    configure_capture_hz(args.capture_hz)
    if args.worker_session_chunks < 0:
        raise ValueError("worker_session_chunks must be zero or positive")
    token = args.token or secrets.token_urlsafe(24)
    config = build_qr_payload(
        f"ws://{args.public_host}:{args.port}/memworld",
        token,
    )
    if args.print_config:
        print(json.dumps(config, indent=2))
        return
    state = DashboardState()
    dashboard_server = DashboardHTTPServer(
        (args.host, args.dashboard_port),
        state,
        config,
    )
    dashboard_thread = Thread(target=dashboard_server.serve_forever, daemon=True)
    dashboard_thread.start()
    from websockets.asyncio.server import serve
    inference_options = {
        "num_inference_steps": args.num_inference_steps,
        "cfg_scale": args.cfg_scale,
    }
    print(f"memWorld dashboard: http://{args.public_host}:{args.dashboard_port}/", flush=True)
    print(f"MEMWORLD_TOKEN={token}", flush=True)
    try:
        async with serve(
            lambda connection: websocket_handler(
                connection,
                token=token,
                worker_url=args.worker_url,
                initial_rgb=args.initial_rgb,
                static_memory=args.static_memory,
                dashboard=state,
                inference_options=inference_options,
                ffmpeg_bin=args.ffmpeg_bin,
                worker_session_chunks=args.worker_session_chunks,
            ),
            args.host,
            args.port,
            max_size=MAX_POSE_JSON_BYTES,
            ping_interval=20,
            ping_timeout=30,
        ):
            await asyncio.Future()
    finally:
        dashboard_server.shutdown()
        dashboard_server.server_close()
        dashboard_thread.join(timeout=2.0)


if __name__ == "__main__":
    asyncio.run(main())
