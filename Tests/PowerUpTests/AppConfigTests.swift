import XCTest
@testable import PowerUp

/// The config decoder must stay tolerant forever: a config.json written by any
/// older build (or hand-edited into a partial state) must keep loading with
/// sensible defaults instead of being thrown away.
final class AppConfigTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    // MARK: v2.7 A - the on-disk config bytes do not move

    /// config.json exactly as the pre-rename build wrote it: captured from
    /// that build's writer (pretty-printed, key-sorted; note the escaped
    /// slashes). Renaming the mapping vocabulary must not move a single byte
    /// on disk.
    private let onDiskConfigFixture = #"""
    {
      "acpAgent" : "opencode",
      "acpCustomCommand" : "",
      "audioInputUID" : "BuiltInMicrophoneDevice",
      "audioOutputUID" : "BuiltInSpeakerDevice",
      "claudePath" : "\/usr\/local\/bin\/claude",
      "controlMode" : "remote",
      "deviceMappings" : {
        "dualsense" : {
          "circle" : {
            "interrupt" : {
    
            }
          },
          "create" : {
            "showWindow" : {
    
            }
          },
          "cross" : {
            "approve" : {
    
            }
          },
          "dpadDown" : {
            "sendPrompt" : {
              "_0" : "Explain what you just did, briefly"
            }
          },
          "dpadLeft" : {
            "sendPrompt" : {
              "_0" : "Undo the last change you made"
            }
          },
          "dpadRight" : {
            "sendPrompt" : {
              "_0" : "Commit the current changes with a good message"
            }
          },
          "dpadUp" : {
            "sendPrompt" : {
              "_0" : "Run the tests and report the results"
            }
          },
          "l1" : {
            "sendDraft" : {
    
            }
          },
          "l2" : {
            "pushToTalkDraft" : {
    
            }
          },
          "l3" : {
            "cycleModel" : {
    
            }
          },
          "options" : {
            "newSession" : {
    
            }
          },
          "ps" : {
            "none" : {
    
            }
          },
          "r1" : {
            "toggleTTS" : {
    
            }
          },
          "r2" : {
            "pushToTalk" : {
    
            }
          },
          "r3" : {
            "cycleEffort" : {
    
            }
          },
          "square" : {
            "sendPrompt" : {
              "_0" : "Run the tests"
            }
          },
          "touchpad" : {
            "cyclePermissionMode" : {
    
            }
          },
          "triangle" : {
            "stopSpeaking" : {
    
            }
          }
        },
        "streamdeck-test" : {
          "key-1" : {
            "approve" : {
    
            }
          }
        }
      },
      "effort" : "high",
      "hapticsEnabled" : true,
      "harnessKind" : "claude",
      "lastSessionID" : "3f2b1a4c-1111-2222-3333-444455556666",
      "lightEnabled" : true,
      "listenerPort" : 48738,
      "listenerToken" : "0B7C1D5E-8A9F-4C3D-B2E1-66778899AABB",
      "localeID" : "en-US",
      "maxSpokenChars" : 900,
      "model" : "opus",
      "modelCycle" : [
        "sonnet",
        "opus",
        "haiku",
        "fable"
      ],
      "onDeviceRecognition" : false,
      "permissionMode" : "plan",
      "projectDir" : "\/Users\/someone\/Projects\/demo",
      "recentProjectDirs" : [
        "\/Users\/someone\/Projects\/demo",
        "\/tmp\/other"
      ],
      "remoteAutoSubmit" : true,
      "remoteCmuxWorkspace" : "workspace:11",
      "remoteTargetKind" : "cmux",
      "sessionIDsByProject" : {
        "\/Users\/someone\/Projects\/demo" : "3f2b1a4c-1111-2222-3333-444455556666"
      },
      "speakSummaries" : false,
      "summaryModel" : "haiku",
      "ttsEnabled" : false,
      "ttsRate" : 0.5
    }
    """#

    func testExistingOnDiskConfigReencodesByteIdentically() throws {
        let fixture = Data(onDiskConfigFixture.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: fixture)
        XCTAssertEqual(try ConfigStore.encode(config), fixture,
                       "the rename must not move a byte of an existing config.json")
        // The renamed vocabulary resolves the same bindings the fixture holds.
        let resolved: Action = config.action(onProfile: DeviceProfile.dualSenseID,
                                             control: "square")
        XCTAssertEqual(resolved, .sendPrompt("Run the tests"))
        XCTAssertEqual(config.action(onProfile: DeviceProfile.dualSenseID, control: "r2"),
                       .pushToTalk)
        XCTAssertEqual(config.action(onProfile: "streamdeck-test", control: "key-1"), .approve)
        let bridge: [ControllerButton: Action] = config.mapping
        XCTAssertEqual(bridge[.r2], .pushToTalk)
    }

    // MARK: v2.7 B - the Controller slot pin

    /// DESIGN v2.7 section B's `controllerDeviceID` is the Controller slot:
    /// nil means Automatic, and it is the field that pins one pad across
    /// restarts. A config written before the slot existed must read as
    /// Automatic, not fail.
    func testConfigWithoutControllerDeviceIDDecodesAsAutomatic() throws {
        XCTAssertNil(AppConfig.defaultConfig().controllerDeviceID)
        XCTAssertNil(try decode("{}").controllerDeviceID,
                     "a config written before the Controller slot existed must read as Automatic")
        let legacy = try decode(#"{"model":"opus","audioInputUID":"BuiltInMicrophoneDevice"}"#)
        XCTAssertEqual(legacy.model, "opus")
        XCTAssertNil(legacy.controllerDeviceID)
    }

    /// An empty string is not a pin: it reads as Automatic, exactly like the
    /// other optional device ids.
    func testEmptyControllerDeviceIDReadsAsAutomatic() throws {
        XCTAssertNil(try decode(#"{"controllerDeviceID":""}"#).controllerDeviceID)
    }

    /// The pin survives an encode -> decode round trip AND is actually
    /// written: a build that dropped the key would silently unpin the pad.
    func testControllerDeviceIDSurvivesEncodeDecodeRoundTrip() throws {
        var config = AppConfig.defaultConfig()
        config.controllerDeviceID = "dualsense-B0:1C:30:11:22:33"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.controllerDeviceID, "dualsense-B0:1C:30:11:22:33")
        XCTAssertEqual(decoded, config, "the whole config survives the round trip")

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["controllerDeviceID"] as? String, "dualsense-B0:1C:30:11:22:33",
                       "the pinned id must be on disk, not dropped by the encoder")
    }

    /// While the pin is nil the key is absent entirely — that is what keeps an
    /// existing config.json byte-identical (see the fixture test above).
    func testNilControllerDeviceIDIsOmittedFromTheEncodedConfig() throws {
        let config = AppConfig.defaultConfig()
        XCTAssertNil(config.controllerDeviceID)

        let data = try ConfigStore.encode(config)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["controllerDeviceID"],
                     "an Automatic Controller slot must not write the key at all")
    }

    // MARK: v2.7 A - the deprecated alias (source compatibility)

    /// The old type name must keep compiling for one release: an out-of-tree
    /// caller gets a deprecation warning, not a break. This reference is the
    /// compile-time proof of the alias — it builds only while
    /// `ControllerAction` still names `Action`, and the compiler reports
    /// "'ControllerAction' is deprecated" for each line below.
    func testDeprecatedControllerActionAliasStillNamesAction() {
        let alias: ControllerAction = .approve
        XCTAssertEqual(alias, Action.approve)
        XCTAssertEqual(alias.displayName, Action.approve.displayName)
        XCTAssertTrue(ControllerAction.pushToTalk.isHoldAction)
        XCTAssertFalse(ControllerAction.sendDraft.isHoldAction)
        let migrated: [ControllerButton: ControllerAction] = [.cross: .approve]
        XCTAssertEqual(Array(migrated.values), [Action.approve])
    }

    // MARK: Default mapping (pinned to the v1.3 layout)

    func testDefaultMappingCoversEveryButton() {
        let mapping = AppConfig.defaultMapping()
        for button in ControllerButton.allCases {
            XCTAssertNotNil(mapping[button], "\(button.rawValue) has no default mapping entry")
        }
    }

    func testDefaultMappingCoreControls() {
        let mapping = AppConfig.defaultMapping()
        XCTAssertEqual(mapping[.r2], .pushToTalk)
        XCTAssertEqual(mapping[.l2], .pushToTalkDraft)
        XCTAssertEqual(mapping[.l1], .sendDraft)
        XCTAssertEqual(mapping[.l3], .cycleModel)
        XCTAssertEqual(mapping[.r3], .cycleEffort)
        XCTAssertEqual(mapping[.touchpad], .cyclePermissionMode)
        XCTAssertEqual(mapping[.ps], Action.none)
        XCTAssertEqual(mapping[.cross], .approve)
        XCTAssertEqual(mapping[.circle], .interrupt)
        XCTAssertEqual(mapping[.square], .sendPrompt("Continue"))
    }

    func testHoldActions() {
        XCTAssertTrue(Action.pushToTalk.isHoldAction)
        XCTAssertTrue(Action.pushToTalkDraft.isHoldAction)
        XCTAssertFalse(Action.sendDraft.isHoldAction)
        XCTAssertFalse(Action.approve.isHoldAction)
    }

    func testEffortCycleEndsAtUltra() {
        XCTAssertEqual(AppConfig.effortCycle, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(AppConfig.effortOptions.contains("max"))
        XCTAssertFalse(AppConfig.effortCycle.contains("default"))
        XCTAssertEqual(AppConfig.effortDisplayName("max"), "Ultra")
        XCTAssertEqual(AppConfig.effortDisplayName("xhigh"), "Extra High")
    }

    func testMultiProjectFieldsDecodeTolerantly() throws {
        let decoded = try decode("{}")
        XCTAssertEqual(decoded.recentProjectDirs, [])
        XCTAssertEqual(decoded.sessionIDsByProject, [:])

        let populated = try decode(#"{"recentProjectDirs":["/a","/b"],"sessionIDsByProject":{"/a":"s1"}}"#)
        XCTAssertEqual(populated.recentProjectDirs, ["/a", "/b"])
        XCTAssertEqual(populated.sessionIDsByProject["/a"], "s1")

        let wrongTypes = try decode(#"{"recentProjectDirs":"nope","sessionIDsByProject":[1]}"#)
        XCTAssertEqual(wrongTypes.recentProjectDirs, [])
        XCTAssertEqual(wrongTypes.sessionIDsByProject, [:])
    }

    func testPermissionCycleNeverContainsBypass() {
        XCTAssertFalse(AppConfig.permissionModeCycle.contains("bypassPermissions"),
                       "a stray button press must never escalate to auto-approve-everything")
    }

    // MARK: Round trip

    func testEncodeDecodeRoundTrip() throws {
        var config = AppConfig.defaultConfig()
        config.projectDir = "/tmp/proj"
        config.model = "opus"
        config.listenerToken = "secret"
        config.mapping[.ps] = .sendPrompt("hello there")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testMappingEncodesAsKeyedObject() throws {
        // Since ADR 0006 the stored shape is deviceMappings:
        // {profileId: {controlId: action}} — keyed objects all the way down.
        let config = AppConfig.defaultConfig()
        let data = try JSONEncoder().encode(config)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profiles = try XCTUnwrap(root["deviceMappings"] as? [String: Any],
                                     "deviceMappings must encode as {profileId: …}")
        let dualsense = try XCTUnwrap(profiles[DeviceProfile.dualSenseID] as? [String: Any],
                                      "a profile's mapping must encode as {controlId: action}, not a flat array")
        XCTAssertNotNil(dualsense["r2"])
    }

    // MARK: Tolerant decoding

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), AppConfig.defaultConfig())
    }

    func testOldConfigWithoutNewKeysKeepsItsValues() throws {
        let decoded = try decode(#"{"model":"opus","ttsEnabled":false,"maxSpokenChars":600}"#)
        XCTAssertEqual(decoded.model, "opus")
        XCTAssertFalse(decoded.ttsEnabled)
        XCTAssertEqual(decoded.maxSpokenChars, 600)
        // Newer keys fall back to defaults.
        XCTAssertEqual(decoded.effort, "default")
        XCTAssertEqual(decoded.modelCycle, AppConfig.defaultModelCycle)
        XCTAssertEqual(decoded.controlMode, "builtin")
        XCTAssertEqual(decoded.remoteTargetKind, "cmux")
    }

    func testWrongTypesFallBackToDefaults() throws {
        let decoded = try decode(#"{"model":42,"ttsEnabled":"yes","mapping":[1,2,3]}"#)
        XCTAssertEqual(decoded.model, "default")
        XCTAssertTrue(decoded.ttsEnabled)
        XCTAssertEqual(decoded.mapping, AppConfig.defaultMapping())
    }

    func testUnknownFixedVocabularyValuesFallBackToDefaults() throws {
        let decoded = try decode(#"{"controlMode":"telepathy","remoteTargetKind":"pigeon"}"#)
        XCTAssertEqual(decoded.controlMode, "builtin")
        XCTAssertEqual(decoded.remoteTargetKind, "cmux")
    }

    func testOutOfRangeListenerPortFallsBackToDefault() throws {
        XCTAssertEqual(try decode(#"{"listenerPort":0}"#).listenerPort, AppConfig.defaultListenerPort)
        XCTAssertEqual(try decode(#"{"listenerPort":99999}"#).listenerPort, AppConfig.defaultListenerPort)
        XCTAssertEqual(try decode(#"{"listenerPort":8080}"#).listenerPort, 8080)
    }

    func testEmptyOptionalStringsBecomeNil() throws {
        let decoded = try decode(#"{"projectDir":"","claudePath":"","lastSessionID":""}"#)
        XCTAssertNil(decoded.projectDir)
        XCTAssertNil(decoded.claudePath)
        XCTAssertNil(decoded.lastSessionID)
    }

    func testUnknownActionInMappingFallsBackToDefaultMapping() throws {
        // A mapping containing an action this build doesn't know (from a newer
        // build) fails that key's decode; the tolerant layer falls back to the
        // default mapping rather than throwing the whole config away.
        let decoded = try decode(#"{"model":"haiku","mapping":{"r2":{"warpSpeed":{}}}}"#)
        XCTAssertEqual(decoded.model, "haiku")
        XCTAssertEqual(decoded.mapping, AppConfig.defaultMapping())
    }
}
