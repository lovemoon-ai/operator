# CLAW

`claw/` is the current architecture documentation area for Operator.

Historical issue trackers, RFC drafts, agent notes, lessons, and old planning
documents have been removed. The current XR layout is now the implementation,
so design intent belongs in the live architecture docs.

## Current Docs

- `architecture/overview.md` - system map and ownership boundaries.
- `architecture/xr-client.md` - Godot XR client layout and mode wiring.
- `architecture/build-and-deploy.md` - host setup, APK builds, installs, and
  device tests.
- `architecture/wire-protocol.md` - teleop, video, live-feed, and ego-upload
  wire contracts.
- `architecture/live-feed-cloud.md` - Live Feed server integration.
- `architecture/rust-agent.md` - Rust crates and runtime responsibilities.
- `sop/add-new-video-source.md` - procedure for adding a video source.

Keep these files short enough to stay useful. If a decision becomes
implemented, update the relevant architecture doc instead of adding a new
historical design record.
