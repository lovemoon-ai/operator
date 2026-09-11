//! Generated from specs/blueprint/v1.json. Do not edit.

pub const SPEC_SHA256: &str = "a69dce013dd149209be713bf3a063d75347e22777a0ffd51fc5704eae9c943b0";
pub const BLUEPRINT_SCHEMA: &str = "operator.blueprint.v1";
pub const BLUEPRINT_STATE_SCHEMA: &str = "operator.blueprint_state.v1";
pub const BLUEPRINT_EVENT_SCHEMA: &str = "operator.blueprint_event.v1";
pub const BLUEPRINT_CAPABILITY: &str = "blueprint_v1";
pub const BLUEPRINT_SPEC_CAPABILITY: &str =
    "blueprint_v1@sha256:a69dce013dd149209be713bf3a063d75347e22777a0ffd51fc5704eae9c943b0";
pub const BLUEPRINT_SPEC_HASH_CAPABILITY: &str = "blueprint_spec_sha256";
pub const BLUEPRINT_COMMAND: &str = "Blueprint";
pub const BLUEPRINT_STATE_COMMAND: &str = "BlueprintState";
pub const BLUEPRINT_EVENT_COMMAND: &str = "BlueprintEvent";
pub const MAX_BLUEPRINT_COMPONENTS: usize = 256;
pub const MAX_BLUEPRINT_STATE_VALUES: usize = 1024;
pub const MAX_BLUEPRINT_WIRE_INTEGER: u64 = 9223372036854775807;
pub const DEFAULT_BLUEPRINT_POSITION: [f64; 3] = [0.0, 0.0, 0.0];
pub const DEFAULT_BLUEPRINT_ROTATION: [f64; 4] = [0.0, 0.0, 0.0, 1.0];
pub const DEFAULT_BLUEPRINT_SCALE: [f64; 3] = [1.0, 1.0, 1.0];
pub const SUPPORTED_ANCHORS: &[&str] = &[
    "world",
    "head",
    "left_controller",
    "right_controller",
    "left_palm",
    "right_palm",
];
pub const SUPPORTED_PRIMITIVES: &[&str] = &[
    "label",
    "status_lamp",
    "palm_menu",
    "fingertip_tactile",
    "video_panel",
    "controller_help",
    "control_frame",
    "operation_trajectory",
];
pub const EXTERNAL_VIEW_PRIMITIVES: &[&str] = &[
    "video_panel",
    "controller_help",
    "control_frame",
    "operation_trajectory",
];
pub const BLUEPRINT_SPEC_JSON: &str = r###"{"schema":"operator.blueprint_primitive_spec.v1","version":1,"wire":{"capability":"blueprint_v1","spec_hash_capability":"blueprint_spec_sha256","blueprint_schema":"operator.blueprint.v1","state_schema":"operator.blueprint_state.v1","event_schema":"operator.blueprint_event.v1","commands":{"blueprint":"Blueprint","state":"BlueprintState","event":"BlueprintEvent"}},"limits":{"components":256,"state_values":1024,"wire_integer_max":9223372036854775807},"value_type_conformance":{"boolean":{"valid":[true,false],"invalid":[0,1,"true",null]},"string":{"valid":["","ready"],"invalid":[0,true,null,[]]},"integer":{"valid":[0,-1,1.0],"invalid":[1.5,true,"1",null]},"number":{"valid":[0,-1,1.5],"invalid":[true,"1",null,[]]},"color":{"valid":["#fff","#ffffff","#ffffffff",[1,0.5,0],[1.0,0.5,0.0,1.0]],"invalid":["red","#12","#gggggg",true,[1,0],[1,0,"blue"],null]},"color_map":{"valid":[{},{"active":"#00ff00","error":[1,0,0,1]}],"invalid":[[],{"active":true},null]},"number_array":{"valid":[[],[0,1.5,-2]],"invalid":[0,[1,true],["1"],null]},"integer_array":{"valid":[[],[0,1.0,-2]],"invalid":[0,[1.5],[true],null]}},"wire_integer_conformance":{"valid":[0,1,9223372036854775807],"invalid":[-1,1.0,true,"1",null]},"anchors":{"world":{"tracking":"origin"},"head":{"tracking":"head"},"left_controller":{"tracking":"controller"},"right_controller":{"tracking":"controller"},"left_palm":{"tracking":"hand"},"right_palm":{"tracking":"hand"}},"transform":{"position":{"type":"vector3","default":[0.0,0.0,0.0]},"rotation":{"type":"quaternion","default":[0.0,0.0,0.0,1.0]},"scale":{"type":"positive_vector3","default":[1.0,1.0,1.0]}},"primitives":{"label":{"host":"node3d","implementation":"label","singleton":false,"default_anchor":"world","anchors":["world","head","left_controller","right_controller","left_palm","right_palm"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""},"text":{"type":"string","default":""},"font_size":{"type":"integer","default":32,"minimum":8,"maximum":96},"pixel_size":{"type":"number","default":0.0015,"minimum":0.0002,"maximum":0.01},"outline_size":{"type":"integer","default":6,"minimum":0,"maximum":24},"no_depth_test":{"type":"boolean","default":true},"color":{"type":"color","default":"#ffffff"}},"bindings":{"visible":{"type":"boolean","required":false},"text":{"type":"string","required":false},"color":{"type":"color","required":false}},"events":{}},"status_lamp":{"host":"node3d","implementation":"status_lamp","singleton":false,"default_anchor":"world","anchors":["world","head","left_controller","right_controller","left_palm","right_palm"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""},"text":{"type":"string","default":""},"font_size":{"type":"integer","default":24,"minimum":8,"maximum":72},"pixel_size":{"type":"number","default":0.001,"minimum":0.0002,"maximum":0.01},"radius":{"type":"number","default":0.012,"minimum":0.003,"maximum":0.05},"colors":{"type":"color_map","default":{}}},"bindings":{"visible":{"type":"boolean","required":false},"state":{"type":"string","required":true},"text":{"type":"string","required":false}},"events":{}},"palm_menu":{"host":"node3d","implementation":"palm_menu","singleton":false,"default_anchor":"left_palm","anchors":["left_palm","right_palm"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""},"title":{"type":"string","required":true},"action":{"type":"string","required":true},"locked_text":{"type":"string","default":"Unlock"},"unlocked_text":{"type":"string","default":"Lock"},"unavailable_text":{"type":"string","default":"Unavailable"}},"bindings":{"visible":{"type":"boolean","required":false},"value":{"type":"boolean","required":true},"available":{"type":"boolean","required":false}},"events":{"action":{"action_property":"action","value_type":"boolean"}}},"fingertip_tactile":{"host":"node3d","implementation":"fingertip_tactile","singleton":false,"default_anchor":"world","anchors":["world"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""}},"bindings":{"visible":{"type":"boolean","required":false},"left_normal":{"type":"number_array","length":5,"required":false},"left_tangential":{"type":"number_array","length":5,"required":false},"left_direction":{"type":"number_array","length":5,"required":false},"left_proximity":{"type":"number_array","length":5,"required":false},"left_status":{"type":"integer_array","length":5,"required":false},"right_normal":{"type":"number_array","length":5,"required":false},"right_tangential":{"type":"number_array","length":5,"required":false},"right_direction":{"type":"number_array","length":5,"required":false},"right_proximity":{"type":"number_array","length":5,"required":false},"right_status":{"type":"integer_array","length":5,"required":false},"sample":{"type":"integer","minimum":0,"required":false,"semantics":"refresh_token"}},"binding_groups":{"left_hand":["left_normal","left_tangential","left_direction","left_proximity","left_status"],"right_hand":["right_normal","right_tangential","right_direction","right_proximity","right_status"]},"constraints":{"at_least_one_complete_binding_group":true},"events":{}},"video_panel":{"host":"external_view","implementation":"video_panel","singleton":true,"default_anchor":"world","anchors":["world"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""},"follow_camera":{"type":"boolean","default":true},"distance":{"type":"number","default":3.0,"minimum":0.1,"maximum":20.0}},"bindings":{"visible":{"type":"boolean","required":false},"follow_camera":{"type":"boolean","required":false}},"events":{}},"controller_help":{"host":"external_view","implementation":"controller_help","singleton":true,"default_anchor":"world","anchors":["world"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""}},"bindings":{"visible":{"type":"boolean","required":false}},"events":{}},"control_frame":{"host":"external_view","implementation":"control_frame","singleton":true,"default_anchor":"world","anchors":["world"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""}},"bindings":{"visible":{"type":"boolean","required":false}},"events":{}},"operation_trajectory":{"host":"external_view","implementation":"operation_trajectory","singleton":true,"default_anchor":"world","anchors":["world"],"user_visibility_override":true,"properties":{"visible":{"type":"boolean","default":true},"settings_label":{"type":"string","default":""}},"bindings":{"visible":{"type":"boolean","required":false}},"events":{}}}}"###;
