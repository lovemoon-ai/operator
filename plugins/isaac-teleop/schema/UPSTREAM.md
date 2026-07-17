# IsaacTeleop schema snapshot

These FlatBuffers schema definitions are copied from NVIDIA IsaacTeleop
`v1.3.131`, commit
`7002ed63d69454ae4f15c0ee19f803fd2846592b`:

<https://github.com/NVIDIA/IsaacTeleop/tree/v1.3.131/src/core/schema/fbs>

The field, enum, include and root-type definitions are unchanged; explanatory
comments are compacted. The files retain their NVIDIA copyright and
Apache-2.0 SPDX headers. They are vendored so the Operator XR encoder, gateway
and Isaac Sim receiver can verify one schema revision instead of following the
upstream `main` branch.

`operator-canonical-v1` is the bootstrap ingress codec. It is a compact custom
layout, not FlatBuffers; the host converts its tracking values immediately to
the public standard TensorGroups corresponding to these schemas. Envelope
codec value `2` is reserved for direct FlatBuffers records generated from this
snapshot.
