//! Declarative Blueprint protocol shared by Operator XR modes.
//!
//! A Blueprint describes which XR primitives to instantiate and how
//! their properties bind to a latest-wins state map. Interactive components
//! send small ordered events back to the Blueprint source.

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

use crate::blueprint_spec::{
    BLUEPRINT_EVENT_SCHEMA, BLUEPRINT_SCHEMA, BLUEPRINT_SPEC_JSON, BLUEPRINT_STATE_SCHEMA,
    DEFAULT_BLUEPRINT_POSITION, DEFAULT_BLUEPRINT_ROTATION, DEFAULT_BLUEPRINT_SCALE,
    MAX_BLUEPRINT_COMPONENTS, MAX_BLUEPRINT_STATE_VALUES, MAX_BLUEPRINT_WIRE_INTEGER,
};

fn primitive_spec(component_type: &str) -> Option<&'static Map<String, Value>> {
    static SPEC: OnceLock<Value> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(BLUEPRINT_SPEC_JSON).expect("generated Blueprint spec must be valid")
    })
    .get("primitives")?
    .get(component_type)?
    .as_object()
}

fn is_color_string(value: &str) -> bool {
    matches!(value.len(), 4 | 5 | 7 | 9)
        && value.starts_with('#')
        && value.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
}

pub fn blueprint_wire_integer_matches_type(value: &Value) -> bool {
    value
        .as_u64()
        .is_some_and(|number| number <= MAX_BLUEPRINT_WIRE_INTEGER)
}

pub fn blueprint_value_matches_type(value: &Value, value_type: &str) -> bool {
    match value_type {
        "boolean" => value.is_boolean(),
        "string" => value.is_string(),
        "integer" => {
            value.as_i64().is_some()
                || value.as_u64().is_some()
                || value
                    .as_f64()
                    .is_some_and(|number| number.is_finite() && number.fract() == 0.0)
        }
        "number" => value.as_f64().is_some_and(f64::is_finite),
        "color" => {
            value.as_str().is_some_and(is_color_string)
                || value.as_array().is_some_and(|channels| {
                    matches!(channels.len(), 3 | 4)
                        && channels
                            .iter()
                            .all(|channel| blueprint_value_matches_type(channel, "number"))
                })
        }
        "color_map" => value.as_object().is_some_and(|colors| {
            colors
                .values()
                .all(|color| blueprint_value_matches_type(color, "color"))
        }),
        "number_array" => value.as_array().is_some_and(|items| {
            items
                .iter()
                .all(|item| blueprint_value_matches_type(item, "number"))
        }),
        "integer_array" => value.as_array().is_some_and(|items| {
            items
                .iter()
                .all(|item| blueprint_value_matches_type(item, "integer"))
        }),
        "string_array" => value
            .as_array()
            .is_some_and(|items| items.iter().all(Value::is_string)),
        _ => false,
    }
}

fn validate_field(name: &str, value: &Value, field_spec: &Value) -> Result<(), String> {
    let value_type = field_spec
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Blueprint field {name:?} has no declared type"))?;
    if !blueprint_value_matches_type(value, value_type) {
        return Err(format!("Blueprint field {name:?} must be {value_type}"));
    }
    if let Some(number) = value.as_f64() {
        if let Some(minimum) = field_spec.get("minimum").and_then(Value::as_f64) {
            if number < minimum {
                return Err(format!("Blueprint field {name:?} must be >= {minimum}"));
            }
        }
        if let Some(maximum) = field_spec.get("maximum").and_then(Value::as_f64) {
            if number > maximum {
                return Err(format!("Blueprint field {name:?} must be <= {maximum}"));
            }
        }
    }
    if let Some(expected_length) = field_spec.get("length").and_then(Value::as_u64) {
        if value.as_array().map(Vec::len) != Some(expected_length as usize) {
            return Err(format!(
                "Blueprint field {name:?} must contain {expected_length} items"
            ));
        }
    }
    if let Some(max_length) = field_spec.get("max_length").and_then(Value::as_u64) {
        if value.as_array().map_or(0, Vec::len) as u64 > max_length {
            return Err(format!(
                "Blueprint field {name:?} must contain at most {max_length} items"
            ));
        }
    }
    Ok(())
}

fn default_position() -> [f64; 3] {
    DEFAULT_BLUEPRINT_POSITION
}

fn default_scale() -> [f64; 3] {
    DEFAULT_BLUEPRINT_SCALE
}

fn default_rotation() -> [f64; 4] {
    DEFAULT_BLUEPRINT_ROTATION
}

fn deserialize_present_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    String::deserialize(deserializer).map(Some)
}

fn deserialize_present_bool<'de, D>(deserializer: D) -> Result<Option<bool>, D::Error>
where
    D: Deserializer<'de>,
{
    bool::deserialize(deserializer).map(Some)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Blueprint {
    pub schema: String,
    pub blueprint_id: String,
    pub revision: u64,
    #[serde(default)]
    pub components: Vec<BlueprintComponent>,
}

impl Blueprint {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != BLUEPRINT_SCHEMA {
            return Err(format!(
                "unsupported blueprint schema {:?}; expected {BLUEPRINT_SCHEMA}",
                self.schema
            ));
        }
        if self.blueprint_id.trim().is_empty() {
            return Err("blueprint_id must not be empty".to_string());
        }
        if self.revision == 0 {
            return Err("blueprint revision must be greater than zero".to_string());
        }
        if self.revision > MAX_BLUEPRINT_WIRE_INTEGER {
            return Err(format!(
                "blueprint revision must be <= {MAX_BLUEPRINT_WIRE_INTEGER}"
            ));
        }
        if self.components.len() > MAX_BLUEPRINT_COMPONENTS {
            return Err(format!(
                "blueprint has {} components; maximum is {MAX_BLUEPRINT_COMPONENTS}",
                self.components.len()
            ));
        }

        let mut ids = HashSet::with_capacity(self.components.len());
        let mut singleton_types = HashSet::new();
        for component in &self.components {
            component.validate()?;
            if !ids.insert(component.id.as_str()) {
                return Err(format!(
                    "duplicate Blueprint component id {:?}",
                    component.id
                ));
            }
            let singleton = primitive_spec(&component.component_type)
                .and_then(|spec| spec.get("singleton"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if singleton && !singleton_types.insert(component.component_type.as_str()) {
                return Err(format!(
                    "duplicate singleton Blueprint primitive type {:?}",
                    component.component_type
                ));
            }
        }
        self.binding_specs()?;
        let mut shared: HashMap<String, Value> = HashMap::new();
        for component in &self.components {
            for (key, contract) in component.menu_contracts() {
                if key.is_empty() { continue; }
                if shared.get(&key).is_some_and(|previous| previous != &contract) {
                    return Err(format!("conflicting shared menu item: {key}"));
                }
                shared.insert(key, contract);
            }
        }
        Ok(())
    }

    pub fn binding_specs(&self) -> Result<HashMap<String, Value>, String> {
        let mut result = HashMap::new();
        for component in &self.components {
            let primitive = primitive_spec(&component.component_type).ok_or_else(|| {
                format!(
                    "unsupported Blueprint component type {:?}",
                    component.component_type
                )
            })?;
            let binding_specs = primitive
                .get("bindings")
                .and_then(Value::as_object)
                .expect("generated Blueprint bindings must be an object");
            for (property_name, state_key) in &component.bindings {
                let field_spec = binding_specs.get(property_name).ok_or_else(|| {
                    format!(
                        "unsupported {} binding {:?}",
                        component.component_type, property_name
                    )
                })?;
                let mut value_contract = field_spec.clone();
                value_contract
                    .as_object_mut()
                    .expect("generated Blueprint binding contract must be an object")
                    .remove("required");
                value_contract
                    .as_object_mut()
                    .expect("generated Blueprint binding contract must be an object")
                    .remove("semantics");
                if let Some(previous) = result.get(state_key) {
                    if previous != &value_contract {
                        return Err(format!(
                            "Blueprint state key {state_key:?} has conflicting contracts"
                        ));
                    }
                } else {
                    result.insert(state_key.clone(), value_contract);
                }
            }
        }
        Ok(result)
    }

    pub fn validate_state(&self, state: &BlueprintState) -> Result<(), String> {
        state.validate()?;
        if state.blueprint_id != self.blueprint_id || state.blueprint_revision != self.revision {
            return Err(
                "Blueprint state does not target the active Blueprint revision".to_string(),
            );
        }
        let binding_specs = self.binding_specs()?;
        for (state_key, value) in &state.values {
            let field_spec = binding_specs
                .get(state_key)
                .ok_or_else(|| format!("Blueprint state key {state_key:?} is not bound"))?;
            validate_field(state_key, value, field_spec)?;
        }
        Ok(())
    }

    pub fn validate_event(&self, event: &BlueprintEvent) -> Result<(), String> {
        event.validate()?;
        if event.blueprint_id != self.blueprint_id || event.blueprint_revision != self.revision {
            return Err(
                "Blueprint event does not target the active Blueprint revision".to_string(),
            );
        }
        let component = self
            .components
            .iter()
            .find(|component| component.id == event.component_id)
            .ok_or_else(|| {
                format!(
                    "Blueprint event references unknown component {:?}",
                    event.component_id
                )
            })?;
        let primitive = primitive_spec(&component.component_type)
            .expect("validated Blueprint component type must exist");
        let properties = primitive
            .get("properties")
            .and_then(Value::as_object)
            .expect("generated Blueprint properties must be an object");
        let events = primitive
            .get("events")
            .and_then(Value::as_object)
            .expect("generated Blueprint events must be an object");
        for event_spec in events.values() {
            let action_property = event_spec
                .get("action_property")
                .and_then(Value::as_str)
                .expect("generated Blueprint event action property must be a string");
            let action = component.properties.get(action_property).or_else(|| {
                properties
                    .get(action_property)
                    .and_then(|field_spec| field_spec.get("default"))
            });
            if action.and_then(Value::as_str) != Some(event.action.as_str()) {
                continue;
            }
            let value_type = event_spec
                .get("value_type")
                .and_then(Value::as_str)
                .expect("generated Blueprint event value type must be a string");
            if blueprint_value_matches_type(&event.value, value_type) {
                return Ok(());
            }
            return Err(format!(
                "Blueprint event value for action {:?} must be {value_type}",
                event.action
            ));
        }
        Err(format!(
            "Blueprint component {:?} does not declare action {:?}",
            event.component_id, event.action
        ))
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct BlueprintComponent {
    pub id: String,
    #[serde(rename = "type")]
    pub component_type: String,
    pub anchor: String,
    #[serde(default)]
    pub transform: BlueprintTransform,
    #[serde(default)]
    pub properties: HashMap<String, serde_json::Value>,
    #[serde(default)]
    pub bindings: HashMap<String, String>,
    pub user_overridable: bool,
}

#[derive(Deserialize)]
struct BlueprintComponentWire {
    id: String,
    #[serde(rename = "type")]
    component_type: String,
    #[serde(default, deserialize_with = "deserialize_present_string")]
    anchor: Option<String>,
    #[serde(default)]
    transform: BlueprintTransform,
    #[serde(default)]
    properties: HashMap<String, Value>,
    #[serde(default)]
    bindings: HashMap<String, String>,
    #[serde(default, deserialize_with = "deserialize_present_bool")]
    user_overridable: Option<bool>,
}

impl<'de> Deserialize<'de> for BlueprintComponent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = BlueprintComponentWire::deserialize(deserializer)?;
        let primitive = primitive_spec(&wire.component_type);
        let anchor = wire.anchor.unwrap_or_else(|| {
            primitive
                .and_then(|value| value.get("default_anchor"))
                .and_then(Value::as_str)
                .unwrap_or("world")
                .to_string()
        });
        let user_overridable = wire.user_overridable.unwrap_or_else(|| {
            primitive
                .and_then(|value| value.get("user_visibility_override"))
                .and_then(Value::as_bool)
                .unwrap_or(false)
        });
        Ok(Self {
            id: wire.id,
            component_type: wire.component_type,
            anchor,
            transform: wire.transform,
            properties: wire.properties,
            bindings: wire.bindings,
            user_overridable,
        })
    }
}

impl BlueprintComponent {
    fn menu_contracts(&self) -> Vec<(String, Value)> {
        let Some(primitive) = primitive_spec(&self.component_type) else { return vec![]; };
        if primitive["host"] != "system_menu" { return vec![]; }
        let property = |name: &str| -> Value {
            self.properties.get(name).cloned()
                .unwrap_or_else(|| primitive["properties"][name]["default"].clone())
        };
        let binding = |name: &str| self.bindings.get(name).cloned().unwrap_or_default();
        let mut rows = vec![];
        for event in primitive["events"].as_object().unwrap().keys() {
            let secondary = event == "secondary_action";
            let action = property(if secondary { "secondary_action" } else { "action" });
            if action.as_str().unwrap_or_default().is_empty() { continue; }
            rows.push((property(if secondary { "secondary_item_key" } else { "item_key" }).as_str().unwrap_or_default().into(), serde_json::json!({
                "action": action, "title": property("title"),
                "off": property(if secondary { "secondary_text" } else { "locked_text" }),
                "on": property(if secondary { "secondary_text" } else { "unlocked_text" }),
                "unavailable": property(if secondary { "secondary_text" } else { "unavailable_text" }),
                "value_binding": if secondary { String::new() } else { binding("value") },
                "available_binding": binding(if secondary { "secondary_available" } else { "available" }),
                "available_default": !secondary,
                "visible_binding": binding("visible"), "visible_default": property("visible"),
                "detail_binding": binding("detail"), "user_overridable": self.user_overridable,
            })));
        }
        rows
    }

    fn validate(&self) -> Result<(), String> {
        if self.id.trim().is_empty() {
            return Err("Blueprint component id must not be empty".to_string());
        }
        let primitive = primitive_spec(&self.component_type).ok_or_else(|| {
            format!(
                "unsupported Blueprint component type {:?}",
                self.component_type
            )
        })?;
        let anchors = primitive
            .get("anchors")
            .and_then(Value::as_array)
            .expect("generated Blueprint primitive anchors must be an array");
        if !anchors
            .iter()
            .any(|anchor| anchor.as_str() == Some(&self.anchor))
        {
            return Err(format!("unsupported Blueprint anchor {:?}", self.anchor));
        }
        if self.user_overridable
            && primitive
                .get("user_visibility_override")
                .and_then(Value::as_bool)
                != Some(true)
        {
            return Err(format!(
                "{} does not support headset visibility overrides",
                self.component_type
            ));
        }
        for (property, binding) in &self.bindings {
            if property.trim().is_empty() || binding.trim().is_empty() {
                return Err(format!(
                    "component {:?} contains an empty property binding",
                    self.id
                ));
            }
        }
        let property_specs = primitive
            .get("properties")
            .and_then(Value::as_object)
            .expect("generated Blueprint properties must be an object");
        let binding_specs = primitive
            .get("bindings")
            .and_then(Value::as_object)
            .expect("generated Blueprint bindings must be an object");
        for property in self.properties.keys() {
            if !property_specs.contains_key(property) {
                return Err(format!(
                    "unsupported {} property {:?}",
                    self.component_type, property
                ));
            }
        }
        for binding in self.bindings.keys() {
            if !binding_specs.contains_key(binding) {
                return Err(format!(
                    "unsupported {} binding {:?}",
                    self.component_type, binding
                ));
            }
        }
        for (name, field_spec) in property_specs {
            if field_spec.get("required").and_then(Value::as_bool) == Some(true)
                && !self.properties.contains_key(name)
            {
                return Err(format!(
                    "{} property {:?} is required",
                    self.component_type, name
                ));
            }
        }
        for (name, value) in &self.properties {
            validate_field(name, value, &property_specs[name])?;
        }
        for (name, field_spec) in binding_specs {
            if field_spec.get("required").and_then(Value::as_bool) == Some(true)
                && !self.bindings.contains_key(name)
            {
                return Err(format!(
                    "{} binding {:?} is required",
                    self.component_type, name
                ));
            }
        }
        let mut complete_groups = 0;
        if let Some(groups) = primitive.get("binding_groups").and_then(Value::as_object) {
            for (group_name, members) in groups {
                let members = members
                    .as_array()
                    .expect("generated Blueprint binding group must be an array");
                let present: Vec<bool> = members
                    .iter()
                    .map(|member| {
                        self.bindings
                            .contains_key(member.as_str().expect("binding name must be a string"))
                    })
                    .collect();
                if present.iter().any(|value| *value) && !present.iter().all(|value| *value) {
                    return Err(format!(
                        "{} binding group {:?} must be complete",
                        self.component_type, group_name
                    ));
                }
                if present.iter().all(|value| *value) {
                    complete_groups += 1;
                }
            }
        }
        if primitive
            .get("constraints")
            .and_then(|value| value.get("at_least_one_complete_binding_group"))
            .and_then(Value::as_bool)
            == Some(true)
            && complete_groups == 0
        {
            return Err(format!(
                "{} requires at least one complete binding group",
                self.component_type
            ));
        }
        self.transform.validate(&self.id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlueprintTransform {
    #[serde(default = "default_position")]
    pub position: [f64; 3],
    #[serde(default = "default_rotation")]
    pub rotation: [f64; 4],
    #[serde(default = "default_scale")]
    pub scale: [f64; 3],
}

impl Default for BlueprintTransform {
    fn default() -> Self {
        Self {
            position: DEFAULT_BLUEPRINT_POSITION,
            rotation: default_rotation(),
            scale: default_scale(),
        }
    }
}

impl BlueprintTransform {
    fn validate(&self, component_id: &str) -> Result<(), String> {
        if self
            .position
            .iter()
            .chain(self.rotation.iter())
            .chain(self.scale.iter())
            .any(|value| !value.is_finite())
        {
            return Err(format!(
                "component {component_id:?} transform must contain finite values"
            ));
        }
        if self.scale.iter().any(|value| *value <= 0.0) {
            return Err(format!(
                "component {component_id:?} transform scale must be positive"
            ));
        }
        let rotation_norm_squared = self.rotation.iter().map(|value| value * value).sum::<f64>();
        if rotation_norm_squared <= 1e-12 {
            return Err(format!(
                "component {component_id:?} transform rotation must be non-zero"
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlueprintState {
    pub schema: String,
    pub blueprint_id: String,
    pub blueprint_revision: u64,
    pub sequence: u64,
    pub timestamp_ns: u64,
    #[serde(default)]
    pub values: HashMap<String, serde_json::Value>,
}

impl BlueprintState {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != BLUEPRINT_STATE_SCHEMA {
            return Err(format!(
                "unsupported Blueprint state schema {:?}; expected {BLUEPRINT_STATE_SCHEMA}",
                self.schema
            ));
        }
        if self.blueprint_id.trim().is_empty() {
            return Err("Blueprint state blueprint_id must not be empty".to_string());
        }
        if self.blueprint_revision == 0 {
            return Err("Blueprint state blueprint_revision must be greater than zero".to_string());
        }
        if self.sequence == 0 {
            return Err("Blueprint state sequence must be greater than zero".to_string());
        }
        if self.blueprint_revision > MAX_BLUEPRINT_WIRE_INTEGER
            || self.sequence > MAX_BLUEPRINT_WIRE_INTEGER
            || self.timestamp_ns > MAX_BLUEPRINT_WIRE_INTEGER
        {
            return Err(format!(
                "Blueprint state integers must be <= {MAX_BLUEPRINT_WIRE_INTEGER}"
            ));
        }
        if self.values.len() > MAX_BLUEPRINT_STATE_VALUES {
            return Err(format!(
                "Blueprint state has {} values; maximum is {MAX_BLUEPRINT_STATE_VALUES}",
                self.values.len()
            ));
        }
        if self.values.keys().any(|key| key.trim().is_empty()) {
            return Err("Blueprint state keys must not be empty".to_string());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlueprintEvent {
    pub schema: String,
    pub blueprint_id: String,
    pub blueprint_revision: u64,
    pub sequence: u64,
    pub timestamp_ns: u64,
    pub component_id: String,
    pub action: String,
    #[serde(default)]
    pub value: serde_json::Value,
}

impl BlueprintEvent {
    pub fn validate(&self) -> Result<(), String> {
        if self.schema != BLUEPRINT_EVENT_SCHEMA {
            return Err(format!(
                "unsupported Blueprint event schema {:?}; expected {BLUEPRINT_EVENT_SCHEMA}",
                self.schema
            ));
        }
        if self.blueprint_id.trim().is_empty()
            || self.component_id.trim().is_empty()
            || self.action.trim().is_empty()
        {
            return Err(
                "Blueprint event blueprint_id, component_id, and action must not be empty"
                    .to_string(),
            );
        }
        if self.blueprint_revision == 0 {
            return Err("Blueprint event blueprint_revision must be greater than zero".to_string());
        }
        if self.sequence == 0 {
            return Err("Blueprint event sequence must be greater than zero".to_string());
        }
        if self.blueprint_revision > MAX_BLUEPRINT_WIRE_INTEGER
            || self.sequence > MAX_BLUEPRINT_WIRE_INTEGER
            || self.timestamp_ns > MAX_BLUEPRINT_WIRE_INTEGER
        {
            return Err(format!(
                "Blueprint event integers must be <= {MAX_BLUEPRINT_WIRE_INTEGER}"
            ));
        }
        Ok(())
    }
}
