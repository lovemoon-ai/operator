//! Shared, language-neutral Operator SDK core.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;
use thiserror::Error;
use tokio::sync::watch;

use teleop_protocol::{AdapterToBridge, BridgeToAdapter};
pub use teleop_protocol::{
    Blueprint, BlueprintComponent, BlueprintEvent, BlueprintState, BlueprintTransform,
    DeviceDescriptor, BLUEPRINT_CAPABILITY, BLUEPRINT_SPEC_HASH_CAPABILITY, SPEC_SHA256,
    SPEC_VERSION,
};

#[derive(Debug, Error)]
pub enum OperatorError {
    #[error("invalid {kind} JSON: {source}")]
    Json {
        kind: &'static str,
        #[source]
        source: serde_json::Error,
    },
    #[error("invalid Blueprint: {0}")]
    Blueprint(String),
    #[error("invalid BlueprintState: {0}")]
    BlueprintState(String),
    #[error("no active Blueprint")]
    NoBlueprint,
    #[error("no published BlueprintState")]
    NoBlueprintState,
    #[error("Blueprint state sequence overflow")]
    SequenceOverflow,
    #[error("Blueprint state sequence must increase")]
    NonIncreasingSequence,
    #[error("message is not a BlueprintEvent")]
    NotBlueprintEvent,
    #[error("internal Operator state lock poisoned")]
    LockPoisoned,
}

#[derive(Default)]
struct PublisherState {
    blueprint: Option<Arc<Blueprint>>,
    state: Option<Arc<BlueprintState>>,
    values: HashMap<String, Value>,
    sequence: u64,
}

pub struct BlueprintPublisher {
    inner: Mutex<PublisherState>,
    blueprint_tx: watch::Sender<Option<Arc<Blueprint>>>,
    state_tx: watch::Sender<Option<Arc<BlueprintState>>>,
}

impl Default for BlueprintPublisher {
    fn default() -> Self {
        Self::new()
    }
}

impl BlueprintPublisher {
    pub fn new() -> Self {
        let (blueprint_tx, _) = watch::channel(None);
        let (state_tx, _) = watch::channel(None);
        Self {
            inner: Mutex::new(PublisherState::default()),
            blueprint_tx,
            state_tx,
        }
    }

    pub fn blueprint_receiver(&self) -> watch::Receiver<Option<Arc<Blueprint>>> {
        self.blueprint_tx.subscribe()
    }

    pub fn state_receiver(&self) -> watch::Receiver<Option<Arc<BlueprintState>>> {
        self.state_tx.subscribe()
    }

    pub fn active_blueprint(&self) -> Result<Option<Arc<Blueprint>>, OperatorError> {
        self.inner
            .lock()
            .map_err(|_| OperatorError::LockPoisoned)
            .map(|inner| inner.blueprint.clone())
    }

    pub fn set_blueprint_json(&self, payload: &str) -> Result<(), OperatorError> {
        let blueprint: Blueprint =
            serde_json::from_str(payload).map_err(|source| OperatorError::Json {
                kind: "Blueprint",
                source,
            })?;
        blueprint.validate().map_err(OperatorError::Blueprint)?;
        let blueprint = Arc::new(blueprint);
        let mut inner = self.inner.lock().map_err(|_| OperatorError::LockPoisoned)?;
        inner.blueprint = Some(blueprint.clone());
        inner.state = None;
        inner.values.clear();
        inner.sequence = 0;
        self.state_tx.send_replace(None);
        self.blueprint_tx.send_replace(Some(blueprint));
        Ok(())
    }

    pub fn clear(&self) -> Result<(), OperatorError> {
        let mut inner = self.inner.lock().map_err(|_| OperatorError::LockPoisoned)?;
        *inner = PublisherState::default();
        self.blueprint_tx.send_replace(None);
        self.state_tx.send_replace(None);
        Ok(())
    }

    pub fn publish_state_json(&self, payload: &str) -> Result<u64, OperatorError> {
        let state: BlueprintState =
            serde_json::from_str(payload).map_err(|source| OperatorError::Json {
                kind: "BlueprintState",
                source,
            })?;
        let mut inner = self.inner.lock().map_err(|_| OperatorError::LockPoisoned)?;
        let blueprint = inner.blueprint.as_ref().ok_or(OperatorError::NoBlueprint)?;
        blueprint
            .validate_state(&state)
            .map_err(OperatorError::BlueprintState)?;
        if inner.state.is_some() && state.sequence <= inner.sequence {
            return Err(OperatorError::NonIncreasingSequence);
        }
        inner.sequence = state.sequence;
        inner.values = state.values.clone();
        let sequence = state.sequence;
        let state = Arc::new(state);
        inner.state = Some(state.clone());
        self.state_tx.send_replace(Some(state));
        Ok(sequence)
    }

    pub fn update_values_json(
        &self,
        payload: &str,
        timestamp_ns: u64,
    ) -> Result<u64, OperatorError> {
        let patch: HashMap<String, Value> =
            serde_json::from_str(payload).map_err(|source| OperatorError::Json {
                kind: "Blueprint values",
                source,
            })?;
        let mut inner = self.inner.lock().map_err(|_| OperatorError::LockPoisoned)?;
        let blueprint = inner.blueprint.clone().ok_or(OperatorError::NoBlueprint)?;
        let sequence = inner
            .sequence
            .checked_add(1)
            .ok_or(OperatorError::SequenceOverflow)?;
        let mut next_values = inner.values.clone();
        next_values.extend(patch);
        let state = BlueprintState {
            schema: teleop_protocol::BLUEPRINT_STATE_SCHEMA.to_string(),
            blueprint_id: blueprint.blueprint_id.clone(),
            blueprint_revision: blueprint.revision,
            sequence,
            timestamp_ns,
            values: next_values.clone(),
        };
        blueprint
            .validate_state(&state)
            .map_err(OperatorError::BlueprintState)?;
        let state = Arc::new(state);
        inner.sequence = sequence;
        inner.values = next_values;
        inner.state = Some(state.clone());
        self.state_tx.send_replace(Some(state));
        Ok(sequence)
    }

    pub fn descriptor_message_json(&self, payload: &str) -> Result<String, OperatorError> {
        let mut descriptor: DeviceDescriptor =
            serde_json::from_str(payload).map_err(|source| OperatorError::Json {
                kind: "DeviceDescriptor",
                source,
            })?;
        descriptor
            .capabilities
            .insert(BLUEPRINT_CAPABILITY.to_string(), Value::Bool(true));
        descriptor.capabilities.insert(
            BLUEPRINT_SPEC_HASH_CAPABILITY.to_string(),
            Value::String(SPEC_SHA256.to_string()),
        );
        serde_json::to_string(&AdapterToBridge::Descriptor(Box::new(descriptor))).map_err(
            |source| OperatorError::Json {
                kind: "Descriptor message",
                source,
            },
        )
    }

    pub fn definition_message_json(&self) -> Result<String, OperatorError> {
        let blueprint = self
            .inner
            .lock()
            .map_err(|_| OperatorError::LockPoisoned)?
            .blueprint
            .clone()
            .ok_or(OperatorError::NoBlueprint)?;
        serde_json::to_string(&AdapterToBridge::Blueprint {
            blueprint: Some(Box::new((*blueprint).clone())),
        })
        .map_err(|source| OperatorError::Json {
            kind: "Blueprint message",
            source,
        })
    }

    pub fn state_message_json(&self) -> Result<String, OperatorError> {
        let state = self
            .inner
            .lock()
            .map_err(|_| OperatorError::LockPoisoned)?
            .state
            .clone()
            .ok_or(OperatorError::NoBlueprintState)?;
        serde_json::to_string(&AdapterToBridge::BlueprintState {
            state: Box::new((*state).clone()),
        })
        .map_err(|source| OperatorError::Json {
            kind: "BlueprintState message",
            source,
        })
    }

    pub fn parse_event_message_json(&self, payload: &str) -> Result<String, OperatorError> {
        let message: BridgeToAdapter =
            serde_json::from_str(payload).map_err(|source| OperatorError::Json {
                kind: "adapter message",
                source,
            })?;
        let BridgeToAdapter::BlueprintEvent { event } = message else {
            return Err(OperatorError::NotBlueprintEvent);
        };
        let inner = self.inner.lock().map_err(|_| OperatorError::LockPoisoned)?;
        let blueprint = inner.blueprint.as_ref().ok_or(OperatorError::NoBlueprint)?;
        blueprint
            .validate_event(&event)
            .map_err(OperatorError::Blueprint)?;
        serde_json::to_string(event.as_ref()).map_err(|source| OperatorError::Json {
            kind: "BlueprintEvent",
            source,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BLUEPRINT: &str = r#"{"schema":"operator.blueprint.v1","blueprint_id":"test","revision":1,"components":[{"id":"status","type":"status_lamp","bindings":{"state":"status"}}]}"#;

    #[test]
    fn publisher_validates_and_builds_wire_messages() {
        let publisher = BlueprintPublisher::new();
        let descriptor = publisher
            .descriptor_message_json(
                r#"{"device":{"type":"test","name":"Test"},"control_schema":{}}"#,
            )
            .unwrap();
        assert!(descriptor.contains(SPEC_SHA256));
        publisher.set_blueprint_json(BLUEPRINT).unwrap();
        assert!(publisher
            .definition_message_json()
            .unwrap()
            .contains("Blueprint"));
        assert_eq!(
            publisher
                .update_values_json(r#"{"status":"active"}"#, 10)
                .unwrap(),
            1
        );
        assert!(publisher
            .state_message_json()
            .unwrap()
            .contains("BlueprintState"));
        assert_eq!(
            publisher
                .active_blueprint()
                .unwrap()
                .as_ref()
                .map(|blueprint| blueprint.blueprint_id.as_str()),
            Some("test")
        );
    }

    #[test]
    fn failed_patch_does_not_mutate_publisher_state() {
        let publisher = BlueprintPublisher::new();
        publisher.set_blueprint_json(BLUEPRINT).unwrap();
        assert_eq!(
            publisher
                .update_values_json(r#"{"status":"active"}"#, 10)
                .unwrap(),
            1
        );
        assert!(publisher
            .update_values_json(r#"{"unknown":true}"#, 11)
            .is_err());
        assert_eq!(
            publisher
                .update_values_json(r#"{"status":"idle"}"#, 12)
                .unwrap(),
            2
        );
        let message: serde_json::Value =
            serde_json::from_str(&publisher.state_message_json().unwrap()).unwrap();
        assert_eq!(message["state"]["values"]["status"], "idle");
        assert!(message["state"]["values"].get("unknown").is_none());
    }

    #[test]
    fn explicit_state_sequences_must_increase() {
        let publisher = BlueprintPublisher::new();
        publisher.set_blueprint_json(BLUEPRINT).unwrap();
        let state = |sequence| {
            format!(
                r#"{{"schema":"operator.blueprint_state.v1","blueprint_id":"test","blueprint_revision":1,"sequence":{sequence},"timestamp_ns":10,"values":{{"status":"active"}}}}"#
            )
        };
        publisher.publish_state_json(&state(3)).unwrap();
        assert!(matches!(
            publisher.publish_state_json(&state(3)),
            Err(OperatorError::NonIncreasingSequence)
        ));
    }
}
