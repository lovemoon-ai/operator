# Quest pose-rate logging design

## Goal

Measure the highest pose upload rate the Quest can sustain and inspect one
representative head-and-hands payload without flooding the terminal.

## Behavior

- Remove the Quest client's 20 Hz pose-send limiter. While the WebSocket is
  open and tracking is available, send one pose on every Godot process frame.
- Keep server-to-Quest placeholder JPEG generation capped at 20 Hz so image
  work does not grow with pose rate.
- Print exactly one full received pose as a compact JSON line prefixed with
  `POSE_SAMPLE` for each WebSocket connection.
- Extend the once-per-second `POSE_STATS` line with:
  - `head_tracked_fps`
  - `left_hand_tracked_fps`
  - `right_hand_tracked_fps`
- A tracked FPS counter increments only when that component reports a true
  tracking flag in an accepted pose message. `pose_rx_fps` remains the total
  accepted message rate.

## Data flow

The Quest samples head and both hands into the existing pose JSON structure on
each Godot process frame. The server validates the envelope, updates the
latest-only inference slot, records per-component tracking counters, and logs
the first complete pose. Placeholder image output continues independently at
20 Hz using the newest available pose.

## Verification

Server unit tests cover tracked-rate accounting, reset behavior, and exactly
one compact sample per connection. The full server test suite must pass on the
remote host. Quest runtime frequency is then measured from `POSE_STATS`.
