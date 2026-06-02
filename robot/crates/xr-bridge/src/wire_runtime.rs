//! Bridge-internal runtime glue shared by the XR network servers.
//!
//! Holds the [`TimedCommand`] envelope (a bridge-internal type, not on any
//! wire) and the [`build_descriptor_frame`] handshake helper. The legacy
//! [`TimedCommand`] lived in `robot/src/device/command.rs`; here it carries the
//! shared `teleop_protocol::DeviceCommand` instead of the robo-agent's local
//! type.

use teleop_protocol::DeviceCommand;

use crate::protocol::CommandFrame;

/// `DeviceCommand` plus the latency-probe timestamps captured at the XR
/// network boundary. Used as the `watch` payload between the pose servers
/// (`pose_server` + `pose_udp_server`) and the [`forward`](crate::forward)
/// control loop, so the forwarder can complete a `LatencyFrame` when the
/// adapter write returns.
///
/// Keeping this wrapper out of `DeviceCommand` itself avoids polluting the
/// wire format with bridge-internal timestamps.
#[derive(Debug, Clone)]
pub struct TimedCommand {
    /// The decoded command.
    pub cmd: DeviceCommand,
    /// Sequence number assigned at decode time (TCP path) or carried from the
    /// UDP packet (`pose_udp_server`). Used by the aggregator to detect gaps.
    pub seq: u64,
    /// Robot wall clock (ns since UNIX epoch) at the moment the command was
    /// decoded off the socket.
    pub t_rx_ns: u64,
}

/// Build a [`CommandFrame`] containing the serialised `DeviceDescriptor`,
/// ready to send back to the headset in response to a "Hello".
pub fn build_descriptor_frame(descriptor: &teleop_protocol::DeviceDescriptor) -> CommandFrame {
    let json = serde_json::to_vec(descriptor).unwrap_or_default();
    CommandFrame {
        command: "DeviceDescriptor".to_string(),
        data: json,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use teleop_protocol::{ControlSchema, DeviceDescriptor, DeviceInfo};

    fn descriptor() -> DeviceDescriptor {
        DeviceDescriptor {
            device: DeviceInfo {
                device_type: "dummy".into(),
                name: "Test Bot".into(),
                icon: String::new(),
                model_url: String::new(),
            },
            control_schema: ControlSchema::default(),
            input_mapping: vec![],
            telemetry_schema: Default::default(),
            video_feeds: vec![],
            safety: Default::default(),
        }
    }

    #[test]
    fn descriptor_frame_is_named_and_parses_back() {
        let desc = descriptor();
        let frame = build_descriptor_frame(&desc);
        assert_eq!(frame.command, "DeviceDescriptor");
        let parsed: DeviceDescriptor =
            serde_json::from_slice(&frame.data).expect("descriptor round-trips through JSON");
        assert_eq!(parsed.device.name, "Test Bot");
        assert_eq!(parsed.device.device_type, "dummy");
    }
}
