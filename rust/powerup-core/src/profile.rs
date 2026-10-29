//! Device profiles (ADR 0006, DESIGN v2.7 A and D): a device described as
//! data, its identity plus its controls. String ids are the stable identity,
//! so a profile can cross the protocol, live in a bundled file and mean the
//! same thing to every OS app. The DualSense ships as the first built-in
//! profile.

use serde::de::{self, DeserializeOwned, Deserializer};
use serde::ser::Serializer;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The built-in DualSense profile's id, under which its mapping is stored.
pub const DUALSENSE_PROFILE_ID: &str = "dualsense";

/// The DualSense controls in the Swift app's `ControllerButton.allCases`
/// order, with the display name and SF Symbol name the mapping editor shows
/// (HK-006). The ids are the keys the config stores, so they never change.
const DUALSENSE_CONTROLS: [(&str, &str, &str); 18] = [
    ("cross", "Cross (✕)", "xmark.circle"),
    ("circle", "Circle (○)", "circle.circle"),
    ("square", "Square (□)", "square.circle"),
    ("triangle", "Triangle (△)", "triangle.circle"),
    ("dpadUp", "D-Pad Up", "dpad.up.filled"),
    ("dpadDown", "D-Pad Down", "dpad.down.filled"),
    ("dpadLeft", "D-Pad Left", "dpad.left.filled"),
    ("dpadRight", "D-Pad Right", "dpad.right.filled"),
    ("l1", "L1 Bumper", "l1.button.roundedbottom.horizontal"),
    ("r1", "R1 Bumper", "r1.button.roundedbottom.horizontal"),
    ("l2", "L2 Trigger", "l2.button.roundedtop.horizontal"),
    ("r2", "R2 Trigger", "r2.button.roundedtop.horizontal"),
    ("l3", "L3 (Left Stick Click)", "l3.button.horizontal"),
    ("r3", "R3 (Right Stick Click)", "r3.button.horizontal"),
    ("create", "Create", "plus.rectangle"),
    ("options", "Options", "line.3.horizontal"),
    ("touchpad", "Touchpad", "rectangle.and.hand.point.up.left"),
    ("ps", "PS Button", "playstation.logo"),
];

/// The DualSense control ids, in profile order. A legacy button-keyed mapping
/// may use only these keys.
pub const DUALSENSE_CONTROL_IDS: [&str; 18] = dualsense_control_ids();

const fn dualsense_control_ids() -> [&'static str; 18] {
    let mut ids = [""; 18];
    let mut index = 0;
    while index < ids.len() {
        ids[index] = DUALSENSE_CONTROLS[index].0;
        index += 1;
    }
    ids
}

/// What a control is physically. Whether an action holds belongs to the
/// action, never to the control (DESIGN v2.7 C), so there is no hold kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ControlKind {
    Button,
    Axis,
    Key,
}

impl ControlKind {
    /// The kind a profile file's string reads as. The pre-v2.7 `"hold"` reads
    /// as a button, so an older profile still loads (HK-005); anything else,
    /// a different spelling included, is not a kind.
    pub fn from_wire(name: &str) -> Option<ControlKind> {
        match name {
            "button" | "hold" => Some(ControlKind::Button),
            "axis" => Some(ControlKind::Axis),
            "key" => Some(ControlKind::Key),
            _ => None,
        }
    }

    /// The name written back, which is never `"hold"`.
    pub fn wire_name(self) -> &'static str {
        match self {
            ControlKind::Button => "button",
            ControlKind::Axis => "axis",
            ControlKind::Key => "key",
        }
    }
}

impl Serialize for ControlKind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.wire_name())
    }
}

impl<'de> Deserialize<'de> for ControlKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        ControlKind::from_wire(&name)
            .ok_or_else(|| de::Error::custom(format!("unknown control kind \"{name}\"")))
    }
}

/// One control on a device. Every field is required.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlDescriptor {
    pub id: String,
    pub kind: ControlKind,
    pub display_name: String,
    pub symbol_name: String,
}

/// A device: its id, its name and its controls, in the file's order.
///
/// Keys a profile or a control does not define are read past and never
/// written. That includes `match` and `report`, which DESIGN v2.7 D reserves
/// for a later release: this build neither claims nor writes them, as the
/// Swift app does not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceProfile {
    pub id: String,
    pub display_name: String,
    pub controls: Vec<ControlDescriptor>,
}

// Hand-written so a profile and a control read only from a JSON object, as
// Swift's synthesized Decodable does. serde's derive would also accept the
// fields as a list, which would load a file the Swift app rejects.
impl<'de> Deserialize<'de> for ControlDescriptor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            id: String,
            kind: ControlKind,
            display_name: String,
            symbol_name: String,
        }
        let Fields {
            id,
            kind,
            display_name,
            symbol_name,
        } = from_object(deserializer)?;
        Ok(ControlDescriptor {
            id,
            kind,
            display_name,
            symbol_name,
        })
    }
}

impl<'de> Deserialize<'de> for DeviceProfile {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Fields {
            id: String,
            display_name: String,
            controls: Vec<ControlDescriptor>,
        }
        let Fields {
            id,
            display_name,
            controls,
        } = from_object(deserializer)?;
        Ok(DeviceProfile {
            id,
            display_name,
            controls,
        })
    }
}

/// Reads `T` from a JSON object and nothing else.
fn from_object<'de, D: Deserializer<'de>, T: DeserializeOwned>(
    deserializer: D,
) -> Result<T, D::Error> {
    let object = Map::<String, Value>::deserialize(deserializer)?;
    T::deserialize(Value::Object(object)).map_err(de::Error::custom)
}

/// The built-in DualSense profile: one button per DualSense button, in
/// [`DUALSENSE_CONTROL_IDS`] order.
pub fn dualsense_profile() -> DeviceProfile {
    DeviceProfile {
        id: DUALSENSE_PROFILE_ID.to_owned(),
        display_name: "DualSense".to_owned(),
        controls: DUALSENSE_CONTROLS
            .iter()
            .map(|(id, display_name, symbol_name)| ControlDescriptor {
                id: (*id).to_owned(),
                kind: ControlKind::Button,
                display_name: (*display_name).to_owned(),
                symbol_name: (*symbol_name).to_owned(),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reserved_profile_objects_are_read_past_and_never_written() {
        let file = json!({
            "id": "pad", "displayName": "Pad", "controls": [],
            "match": {"vendorID": 1356}, "report": {"layout": "usb"}
        });
        let profile: DeviceProfile = serde_json::from_value(file).unwrap();
        let written = serde_json::to_value(&profile).unwrap();
        assert_eq!(
            written,
            json!({"id": "pad", "displayName": "Pad", "controls": []})
        );
    }

    #[test]
    fn hold_reads_as_button_and_is_never_written() {
        assert_eq!(ControlKind::from_wire("hold"), Some(ControlKind::Button));
        let control: ControlDescriptor = serde_json::from_value(json!({
            "id": "p", "kind": "hold", "displayName": "P", "symbolName": "s"
        }))
        .unwrap();
        assert_eq!(serde_json::to_value(&control).unwrap()["kind"], "button");
    }

    #[test]
    fn a_profile_reads_only_from_an_object() {
        let list = json!(["pad", "Pad", []]);
        assert!(serde_json::from_value::<DeviceProfile>(list).is_err());
        let control = json!(["a", "button", "A", "s"]);
        assert!(serde_json::from_value::<ControlDescriptor>(control).is_err());
    }

    #[test]
    fn dualsense_ids_follow_the_control_table() {
        let profile = dualsense_profile();
        let ids: Vec<&str> = profile.controls.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, DUALSENSE_CONTROL_IDS);
        assert_eq!(DUALSENSE_CONTROL_IDS.first(), Some(&"cross"));
        assert_eq!(DUALSENSE_CONTROL_IDS.last(), Some(&"ps"));
    }
}
