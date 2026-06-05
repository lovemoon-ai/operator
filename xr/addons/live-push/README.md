# live-push

`live-push` owns the XR-to-server data path for Live Capture.

It exports the Android `LivePushPlugin`, which implements the
`SpatialDataSink` contract consumed by `QuestCapturePlugin`. RGB CSD and HEVC
packets flow directly from the Android capture provider into the socket writer.
Depth, head pose, controller, hand, and input samples are passed through
`LivePushWriter` from GDScript.

RGB CSD payloads explicitly advertise `codec="hevc"`,
`bitstream_format="hevc_annexb"`, and `packet_format="access_unit"`. Each
`rgb_packet` payload is one MediaCodec HEVC output access unit forwarded as an
Annex-B elementary-stream packet.

Current wire format is OLCP v1:

```text
"OLCP" version frame_type flags pts_ns duration_ns payload_size payload
```

The addon keeps a legacy `LiveCaptureServerPlugin` singleton available for
older scenes, but new code should bind `LivePushPlugin`.
