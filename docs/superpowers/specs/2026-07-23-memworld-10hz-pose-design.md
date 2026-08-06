# MemWorld 10 Hz Pose Sampling Design

## Goal

Align the live demo input and playback clocks: sample the freshest Quest pose at
10 Hz, collect 33 samples over 3.3 seconds, and play the 33 generated frames at
10 Hz while the next chunk is inferred.

## Data flow

Quest continues publishing pose messages at its native rate (normally about
90 Hz). Operator keeps only the latest received pose and projects that pose at a
strict 10 Hz model clock. Every successful projection contributes one sample to
a non-overlapping 33-frame chunk, so a chunk represents `33 / 10 = 3.3`
seconds.

The projected skeleton preview also runs at 10 Hz so it does not resend the same
model sample twice. Operator reports both the native receive rate and the
effective model sampling rate.

Operator sends `fps=10`, `playback_fps=10`, and `frames_per_chunk=33` in
`session.start`. MemWorld validates the same live-session contract. The model
architecture and the number of generated frames do not change.

## Scheduling

There is one running chunk and one replaceable pending chunk. After the worker
returns a running chunk, Operator clears it and immediately starts the pending
chunk on the next scheduler iteration. There is no chunk-duration timer between
inferences. If inference falls behind, a newly completed input chunk replaces
the old pending chunk so stale work does not form an unbounded queue.

## Observability

`MEMWORLD_STATS` retains `pose_rx_hz` for native Quest traffic and adds
`model_sample_hz` for successful 10 Hz projections. `preview_tx_hz` should also
settle near 10 Hz. `window=X/33` remains the progress toward the next chunk.

## Verification

- Operator constants and session metadata are 10 Hz.
- A 33-frame model window has a duration of 3.3 seconds.
- MemWorld accepts a 10 Hz live session and rejects the old 24 Hz contract.
- Existing 33-frame chunk and latest-pending scheduling tests remain green.
- Source-level worker-client tests continue to prove immediate next-chunk
  scheduling without an added inter-chunk delay.

## Scope

This change does not replace the current MP4 result transport with per-frame
images. That is a separate transport/display change.
