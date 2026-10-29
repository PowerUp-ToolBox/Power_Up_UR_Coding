//! The mapping vocabulary (DESIGN v2.4 B, v2.7 A): the action bound to one
//! control in `config.json`. Its JSON shape is the one Swift's synthesized
//! enum `Codable` writes and reads, so a config file means the same thing to
//! the Swift app and to the core.

use serde::de::{self, Deserialize, Deserializer};
use serde::ser::{Serialize, Serializer};
use serde_json::{Map, Value};

use crate::intent::VoiceCaptureMode;
use crate::{wire, CoreError};

/// One mapped action. The variants are in Swift's declaration order.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Action {
    None,
    PushToTalk,
    SendPrompt(String),
    Approve,
    Reject,
    Interrupt,
    StopSpeaking,
    ReplayLastReply,
    ToggleTts,
    NewSession,
    ShowWindow,
    CycleModel,
    CycleEffort,
    CyclePermissionMode,
    CycleProject,
    CycleFocus,
    PushToTalkDraft,
    SendDraft,
    ToggleControlMode,
}

/// Every case name, as the config stores it. A key outside this list is not
/// a case, which is what makes an unknown sibling key invisible.
pub const WIRE_NAMES: [&str; 19] = [
    "none",
    "pushToTalk",
    "sendPrompt",
    "approve",
    "reject",
    "interrupt",
    "stopSpeaking",
    "replayLastReply",
    "toggleTTS",
    "newSession",
    "showWindow",
    "cycleModel",
    "cycleEffort",
    "cyclePermissionMode",
    "cycleProject",
    "cycleFocus",
    "pushToTalkDraft",
    "sendDraft",
    "toggleControlMode",
];

/// The key under which sendPrompt's payload object holds the prompt: Swift's
/// name for an unlabeled associated value.
const PROMPT_KEY: &str = "_0";

impl Action {
    /// The Swift case name, which is also the key the config stores.
    pub fn wire_name(&self) -> &'static str {
        match self {
            Action::None => "none",
            Action::PushToTalk => "pushToTalk",
            Action::SendPrompt(_) => "sendPrompt",
            Action::Approve => "approve",
            Action::Reject => "reject",
            Action::Interrupt => "interrupt",
            Action::StopSpeaking => "stopSpeaking",
            Action::ReplayLastReply => "replayLastReply",
            Action::ToggleTts => "toggleTTS",
            Action::NewSession => "newSession",
            Action::ShowWindow => "showWindow",
            Action::CycleModel => "cycleModel",
            Action::CycleEffort => "cycleEffort",
            Action::CyclePermissionMode => "cyclePermissionMode",
            Action::CycleProject => "cycleProject",
            Action::CycleFocus => "cycleFocus",
            Action::PushToTalkDraft => "pushToTalkDraft",
            Action::SendDraft => "sendDraft",
            Action::ToggleControlMode => "toggleControlMode",
        }
    }

    /// Whether the action records while its control is held and finishes on
    /// release. Only the two push-to-talk actions hold; holding belongs to the
    /// action, never to the control (DESIGN v2.7 C, HK-004).
    pub fn is_hold(&self) -> bool {
        self.capture_mode().is_some()
    }

    /// The capture a hold action starts, or `None` for an action that fires
    /// once on the press.
    pub fn capture_mode(&self) -> Option<VoiceCaptureMode> {
        match self {
            Action::PushToTalk => Some(VoiceCaptureMode::Send),
            Action::PushToTalkDraft => Some(VoiceCaptureMode::Draft),
            _ => None,
        }
    }

    /// Reads an action exactly as Swift's synthesized enum `Codable` does,
    /// which is what decides whether a stored binding survives:
    ///
    /// - the value must be an object;
    /// - keys that are not case names are invisible (a newer build's extra
    ///   key does not cost the binding);
    /// - exactly one case key must remain;
    /// - its payload must be an object, whose extra keys are ignored;
    /// - sendPrompt needs a string `"_0"` in its payload.
    ///
    /// Anything else is `None`: not an action this build knows.
    pub fn from_wire(value: &Value) -> Option<Action> {
        let object = value.as_object()?;
        let mut cases = object
            .iter()
            .filter(|(key, _)| WIRE_NAMES.contains(&key.as_str()));
        let (name, payload) = cases.next()?;
        if cases.next().is_some() {
            return None;
        }
        let payload = payload.as_object()?;
        if name == "sendPrompt" {
            let prompt = payload.get(PROMPT_KEY)?.as_str()?;
            return Some(Action::SendPrompt(prompt.to_owned()));
        }
        unit_case(name)
    }

    /// The JSON value Swift writes: `{"approve": {}}`, or
    /// `{"sendPrompt": {"_0": "…"}}`.
    pub fn to_wire(&self) -> Value {
        let mut payload = Map::new();
        if let Action::SendPrompt(prompt) = self {
            payload.insert(PROMPT_KEY.to_owned(), Value::String(prompt.clone()));
        }
        let mut object = Map::new();
        object.insert(self.wire_name().to_owned(), Value::Object(payload));
        Value::Object(object)
    }

    /// Compact JSON text byte-identical to Swift's `JSONEncoder` with
    /// `.sortedKeys` (see [`wire::to_swift_json`]).
    pub fn to_wire_json(&self) -> Result<String, CoreError> {
        wire::to_swift_json(self)
    }
}

/// The 18 cases without a payload, by wire name.
fn unit_case(name: &str) -> Option<Action> {
    Some(match name {
        "none" => Action::None,
        "pushToTalk" => Action::PushToTalk,
        "approve" => Action::Approve,
        "reject" => Action::Reject,
        "interrupt" => Action::Interrupt,
        "stopSpeaking" => Action::StopSpeaking,
        "replayLastReply" => Action::ReplayLastReply,
        "toggleTTS" => Action::ToggleTts,
        "newSession" => Action::NewSession,
        "showWindow" => Action::ShowWindow,
        "cycleModel" => Action::CycleModel,
        "cycleEffort" => Action::CycleEffort,
        "cyclePermissionMode" => Action::CyclePermissionMode,
        "cycleProject" => Action::CycleProject,
        "cycleFocus" => Action::CycleFocus,
        "pushToTalkDraft" => Action::PushToTalkDraft,
        "sendDraft" => Action::SendDraft,
        "toggleControlMode" => Action::ToggleControlMode,
        _ => return None,
    })
}

// Hand-written rather than derived: serde's derive cannot express Swift's
// rules (invisible sibling keys, an object payload even for unit cases).
impl Serialize for Action {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.to_wire().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Action {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        Action::from_wire(&value).ok_or_else(|| de::Error::custom("not an action this build knows"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unit_cases_round_trip() {
        for name in WIRE_NAMES {
            let value = if name == "sendPrompt" {
                json!({name: {"_0": "Continue"}})
            } else {
                json!({name: {}})
            };
            let action = Action::from_wire(&value).unwrap();
            assert_eq!(action.wire_name(), name);
            assert_eq!(action.to_wire(), value);
            let text = action.to_wire_json().unwrap();
            assert_eq!(serde_json::from_str::<Action>(&text).unwrap(), action);
        }
    }

    #[test]
    fn every_payload_free_wire_name_is_a_unit_case() {
        for name in WIRE_NAMES.iter().filter(|name| **name != "sendPrompt") {
            assert_eq!(unit_case(name).map(|a| a.wire_name()), Some(*name));
        }
        assert_eq!(unit_case("sendPrompt"), None);
    }

    #[test]
    fn unknown_sibling_keys_are_ignored() {
        let value = json!({"approve": {}, "fromTheFuture": {"x": 1}});
        assert_eq!(Action::from_wire(&value), Some(Action::Approve));
        let two = json!({"approve": {}, "reject": {}});
        assert_eq!(Action::from_wire(&two), None);
    }

    #[test]
    fn a_rejected_value_is_a_deserialize_error() {
        let error = serde_json::from_str::<Action>(r#"{"launchMissiles":{}}"#).unwrap_err();
        assert!(error.to_string().contains("not an action"));
    }

    #[test]
    fn only_push_to_talk_holds() {
        assert_eq!(
            Action::PushToTalk.capture_mode(),
            Some(VoiceCaptureMode::Send)
        );
        assert_eq!(
            Action::PushToTalkDraft.capture_mode(),
            Some(VoiceCaptureMode::Draft)
        );
        assert!(!Action::SendDraft.is_hold());
        assert!(!Action::None.is_hold());
    }
}
