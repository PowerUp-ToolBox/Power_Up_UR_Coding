import XCTest
@testable import PowerUp

final class IntentMapperTests: XCTestCase {

    // MARK: Mapping vocabulary → intents

    func testHoldActionsProduceBeginEndPairs() {
        XCTAssertEqual(IntentMapper.intent(for: .pushToTalk, phase: .began), .beginVoiceCapture(.send))
        XCTAssertEqual(IntentMapper.intent(for: .pushToTalk, phase: .ended), .endVoiceCapture)
        XCTAssertEqual(IntentMapper.intent(for: .pushToTalkDraft, phase: .began), .beginVoiceCapture(.draft))
        XCTAssertEqual(IntentMapper.intent(for: .pushToTalkDraft, phase: .ended), .endVoiceCapture)
    }

    func testNonHoldActionsFireOnPressOnly() {
        let expectations: [(Action, Intent)] = [
            (.sendPrompt("Continue"), .sendPrompt("Continue")),
            (.sendDraft, .sendDraft),
            (.approve, .approve),
            (.reject, .reject),
            (.interrupt, .interrupt),
            (.stopSpeaking, .stopSpeaking),
            (.replayLastReply, .replayLastReply),
            (.toggleTTS, .toggleTTS),
            (.newSession, .newSession),
            (.showWindow, .showWindow),
            (.cycleModel, .cycleModel),
            (.cycleEffort, .cycleEffort),
            (.cyclePermissionMode, .cyclePermissionMode),
            (.cycleProject, .cycleProject),
            (.cycleFocus, .cycleFocus),
            (.toggleControlMode, .toggleControlMode),
        ]
        for (action, intent) in expectations {
            XCTAssertEqual(IntentMapper.intent(for: action, phase: .began), intent)
            XCTAssertNil(IntentMapper.intent(for: action, phase: .ended),
                         "\(action) must not fire again on release")
        }
    }

    func testNoneMapsToNothing() {
        XCTAssertNil(IntentMapper.intent(for: .none, phase: .began))
        XCTAssertNil(IntentMapper.intent(for: .none, phase: .ended))
    }

    // MARK: Protocol wire names → intents (the core's name table, through the bridge)

    func testProtocolNamesMapToIntents() {
        XCTAssertEqual(CoreBridge.protocolIntent(name: "approve", text: nil), .approve)
        XCTAssertEqual(CoreBridge.protocolIntent(name: "interrupt", text: nil), .interrupt)
        XCTAssertEqual(CoreBridge.protocolIntent(name: "cycleModel", text: nil), .cycleModel)
        XCTAssertEqual(CoreBridge.protocolIntent(name: "cycleProject", text: nil), .cycleProject)
        XCTAssertEqual(CoreBridge.protocolIntent(name: "cycleFocus", text: nil), .cycleFocus)
        XCTAssertEqual(CoreBridge.protocolIntent(name: "sendPrompt", text: "run tests"),
                       .sendPrompt("run tests"))
    }

    func testSendPromptRequiresNonEmptyText() {
        XCTAssertNil(CoreBridge.protocolIntent(name: "sendPrompt", text: nil))
        XCTAssertNil(CoreBridge.protocolIntent(name: "sendPrompt", text: "   "))
    }

    func testVoiceCaptureIsNotReachableOverTheProtocol() {
        for name in ["beginVoiceCapture", "endVoiceCapture", "pushToTalk", "pushToTalkDraft"] {
            XCTAssertNil(CoreBridge.protocolIntent(name: name, text: nil),
                         "\(name) must not be a protocol intent — the mic is local")
        }
    }

    func testNoProtocolNameGrantsPermissionEscalation() {
        // Safety invariant (docs/protocol.md): the only permission-related
        // wire intent is the cycle, whose fixed order excludes bypass.
        for name in ["setPermissionMode", "bypassPermissions", "permissionMode", "setModel", "sudo"] {
            XCTAssertNil(CoreBridge.protocolIntent(name: name, text: "bypassPermissions"))
        }
        XCTAssertFalse(AppConfig.permissionModeCycle.contains("bypassPermissions"))
    }

    func testUnknownNamesReturnNil() {
        XCTAssertNil(CoreBridge.protocolIntent(name: "", text: nil))
        XCTAssertNil(CoreBridge.protocolIntent(name: "definitelyNotAThing", text: nil))
    }
}

final class HarnessEventMappingTests: XCTestCase {

    func testEveryClaudeEventNormalizes() {
        let cases: [(ClaudeEvent, HarnessEvent)] = [
            (.ready(sessionID: "s1", model: "m1"), .sessionReady(sessionID: "s1", model: "m1")),
            (.textDelta("chunk"), .replyDelta("chunk")),
            (.assistantMessage("hello"), .reply("hello")),
            (.toolUse(name: "Edit", detail: "a.swift"), .toolUse(name: "Edit", detail: "a.swift")),
            (.turnCompleted(resultText: "done", costUSD: 0.5, isError: false, subtype: "success"),
             .turnCompleted(resultText: "done", costUSD: 0.5, isError: false, detail: "success")),
            (.controlResult(action: "set_model", ok: true, detail: "", value: "opus"),
             .controlResult(action: "set_model", ok: true, detail: "", value: "opus")),
            (.processError("boom"), .runtimeError("boom")),
            (.terminated(exitCode: 3), .ended(exitCode: 3)),
        ]
        for (wire, normalized) in cases {
            XCTAssertEqual(HarnessEvent.from(wire), normalized)
        }
    }
}
