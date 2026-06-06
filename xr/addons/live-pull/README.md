# live-pull

`live-pull` owns the server-to-XR result path for Live Feed.

It provides:

- `LivePullClient`: connects to the result channel, parses OLCP result frames,
  assembles dense map fragments, and drops stale map versions.
- `LivePullDenseMapView`: renders committed dense map chunks as point-cloud
  `ArrayMesh` instances.

Supported result messages:

```text
110 algorithm_status
111 map_reset
112 dense_map_manifest
113 dense_map_fragment
114 dense_map_commit
115 camera_trajectory
116 map_transform
```

The renderer supports the current prototype's `f32xyz_u8rgba_f32conf` point
payload and uncompressed `quantized_u16xyz_rgba8_conf8` tiles. Compressed
`zstd` tiles are intentionally detected but not decoded in GDScript; production
builds should move that decode path to native code or an Android plugin.

`LivePullClient` releases dense chunk fragment/raw payload buffers once a commit
has been emitted. `LivePullDenseMapView` keeps rendered mesh memory bounded with
`max_rendered_chunks` and `max_rendered_points`; raise those exports only when
the target headset has enough memory for longer dense-map history.
