class_name WireProtocolContract
extends RefCounted
## v2 contracts: re-exports the wire-format constants owned by XRoboProtocol
## (res://scripts/network/protocol.gd). No byte-format change — this file
## exists so core/sink modules can reference wire constants without importing
## the network implementation.

const PIPELINE_MODE_V4L2_HW := XRoboProtocol.PIPELINE_MODE_V4L2_HW
const PIPELINE_MODE_FFMPEG := XRoboProtocol.PIPELINE_MODE_FFMPEG

const UDP_FRAGMENT_HEADER_SIZE := XRoboProtocol.UDP_FRAGMENT_HEADER_SIZE
const UDP_FRAGMENT_MAGIC_0 := XRoboProtocol.UDP_FRAGMENT_MAGIC_0
const UDP_FRAGMENT_MAGIC_1 := XRoboProtocol.UDP_FRAGMENT_MAGIC_1
const UDP_FRAGMENT_MAGIC_2 := XRoboProtocol.UDP_FRAGMENT_MAGIC_2
const UDP_FRAGMENT_MAGIC_3 := XRoboProtocol.UDP_FRAGMENT_MAGIC_3
const UDP_FRAGMENT_VERSION := XRoboProtocol.UDP_FRAGMENT_VERSION
const UDP_FRAGMENT_FLAG_LAST := XRoboProtocol.UDP_FRAGMENT_FLAG_LAST
const UDP_FRAGMENT_FLAG_FIRST := XRoboProtocol.UDP_FRAGMENT_FLAG_FIRST

const TIMED_VIDEO_HEADER_SIZE := XRoboProtocol.TIMED_VIDEO_HEADER_SIZE
