import XCTest
@testable import PowerUp

/// Table-driven tests for the product rules that used to live inside SwiftUI
/// views (#126): the push-to-talk hint chooser, the empty-transcript prompt,
/// the controller info chip text, the permission banner labels and the cost
/// chip visibility rule. Each table row is input state in, string (or nil)
/// out, with a reason that is printed when the row fails.
///
/// These are plain XCTest on purpose (epic #94): every UI reimplements them,
/// so there is no shared JSON fixture for the Rust core to replay.
final class ViewLogicTests: XCTestCase {

    // MARK: - Push-to-talk hint chooser

    func testPushToTalkButtonNameTable() {
        struct Row { let name: String; let mapping: [ControllerButton: Action]; let expected: String?; let reason: String }
        let rows: [Row] = [
            Row(name: "empty mapping",
                mapping: [:], expected: nil,
                reason: "Nothing mapped to push-to-talk, so the UI must not name a button."),
            Row(name: "only unrelated actions",
                mapping: [.cross: .approve, .circle: .reject, .r1: .sendPrompt("hi")], expected: nil,
                reason: "Only push-to-talk and dictate-to-draft count as a hint."),
            Row(name: "factory default R2",
                mapping: AppConfig.defaultMapping(), expected: "R2 Trigger",
                reason: "The shipped mapping holds R2 for push-to-talk."),
            Row(name: "remapped to Square",
                mapping: [.square: .pushToTalk], expected: "Square (□)",
                reason: "A remap must be reflected so the UI never names the wrong button (story 10)."),
            Row(name: "draft-only mapping falls back",
                mapping: [.l2: .pushToTalkDraft], expected: "L2 Trigger",
                reason: "A person who only mapped dictate-to-draft still gets a hint instead of none."),
            Row(name: "push-to-talk beats an earlier draft button",
                mapping: [.cross: .pushToTalkDraft, .r2: .pushToTalk], expected: "R2 Trigger",
                reason: "Push-to-talk wins over draft even when the draft button comes first in button order."),
            Row(name: "two push-to-talk buttons pick the first in button order",
                mapping: [.r2: .pushToTalk, .cross: .pushToTalk], expected: "Cross (✕)",
                reason: "Ties are broken by ControllerButton.allCases order, not by dictionary order."),
            Row(name: "two draft buttons pick the first in button order",
                mapping: [.ps: .pushToTalkDraft, .dpadUp: .pushToTalkDraft], expected: "D-Pad Up",
                reason: "The draft fallback uses the same button order."),
            Row(name: "none action is not a hint",
                mapping: [.r2: .none], expected: nil,
                reason: "An explicitly unmapped button is not a push-to-talk button."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.pushToTalkButtonName(in: row.mapping), row.expected,
                           "\(row.name): \(row.reason)")
        }
    }

    // MARK: - Empty-transcript prompt

    func testEmptyTranscriptPromptTable() {
        struct Row { let name: String; let hint: String?; let expected: String; let reason: String }
        let rows: [Row] = [
            Row(name: "no push-to-talk button",
                hint: nil,
                expected: "Click the mic (or press ⌘D) to dictate, or type a message below — no controller needed.",
                reason: "A controller-less launch must not read as a dead end (DESIGN v2.6 C)."),
            Row(name: "push-to-talk on R2",
                hint: "R2 Trigger",
                expected: "Hold R2 Trigger on the controller and speak, click the mic (or press ⌘D) to dictate, or type a message below.",
                reason: "With a mapped button, the prompt names it first, then the mouse and keyboard paths."),
            Row(name: "push-to-talk on a glyph button",
                hint: "Cross (✕)",
                expected: "Hold Cross (✕) on the controller and speak, click the mic (or press ⌘D) to dictate, or type a message below.",
                reason: "The button's display name is used verbatim, glyph included."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.emptyTranscriptPrompt(pushToTalkHint: row.hint), row.expected,
                           "\(row.name): \(row.reason)")
        }
    }

    // MARK: - Controller info chip

    func testControllerChipNameTable() {
        struct Row { let name: String; let controllerName: String?; let connected: Bool; let expected: String; let reason: String }
        let rows: [Row] = [
            Row(name: "nothing connected", controllerName: nil, connected: false,
                expected: "No controller", reason: "The resting chip says plainly that no pad is there."),
            Row(name: "connected without a vendor name", controllerName: nil, connected: true,
                expected: "Controller", reason: "A pad with no vendor name still reads as connected."),
            Row(name: "connected with an empty vendor name", controllerName: "", connected: true,
                expected: "Controller", reason: "An empty name is treated like a missing one."),
            Row(name: "connected DualSense", controllerName: "DualSense Wireless Controller", connected: true,
                expected: "DualSense Wireless Controller", reason: "The vendor name is shown as-is."),
            Row(name: "stale name while disconnected", controllerName: "Xbox Wireless Controller", connected: false,
                expected: "Xbox Wireless Controller",
                reason: "Current behavior: a non-empty name wins even when disconnected (ControllerService clears it on disconnect)."),
            Row(name: "empty name while disconnected", controllerName: "", connected: false,
                expected: "No controller", reason: "An empty name falls back to the disconnected wording."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.controllerChipName(controllerName: row.controllerName,
                                                        isConnected: row.connected),
                           row.expected, "\(row.name): \(row.reason)")
        }
    }

    func testControllerChipHelpTable() {
        struct Row { let name: String; let controllerName: String?; let connected: Bool; let dualSense: Bool; let expected: String; let reason: String }
        let pairing = "No controller connected — see the pairing steps in the sidebar"
        let rows: [Row] = [
            Row(name: "nothing connected", controllerName: nil, connected: false, dualSense: false,
                expected: pairing, reason: "Disconnected help points at the pairing steps."),
            Row(name: "disconnected beats a stale name", controllerName: "DualSense Wireless Controller",
                connected: false, dualSense: true,
                expected: pairing, reason: "Help text checks the connection first, unlike the chip name."),
            Row(name: "connected DualSense", controllerName: "DualSense Wireless Controller",
                connected: true, dualSense: true,
                expected: "DualSense Wireless Controller (DualSense)", reason: "A DualSense is labeled as such."),
            Row(name: "connected other pad", controllerName: "Xbox Wireless Controller",
                connected: true, dualSense: false,
                expected: "Xbox Wireless Controller", reason: "Other pads show just their name."),
            Row(name: "connected DualSense without a name", controllerName: nil,
                connected: true, dualSense: true,
                expected: "Controller (DualSense)", reason: "The fallback name is used in the help text too."),
            Row(name: "connected other pad without a name", controllerName: "",
                connected: true, dualSense: false,
                expected: "Controller", reason: "An empty name falls back to 'Controller'."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.controllerChipHelp(controllerName: row.controllerName,
                                                        isConnected: row.connected,
                                                        isDualSense: row.dualSense),
                           row.expected, "\(row.name): \(row.reason)")
        }
    }

    // MARK: - Permission banner

    func testPermissionAllowButtonTitleTable() {
        let rows: [(armed: Bool, expected: String, reason: String)] = [
            (false, "Allow", "A fresh request offers Allow (DESIGN v2.6 C)."),
            (true, "Confirm", "An armed destructive request is retitled Confirm for the second click."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.permissionAllowButtonTitle(armed: row.armed), row.expected,
                           "armed=\(row.armed): \(row.reason)")
        }
    }

    func testPermissionLegendTable() {
        let rows: [(armed: Bool, expected: String, reason: String)] = [
            (false, "✕ allow  ·  ○ deny", "The controller legend matches the Allow button."),
            (true, "✕ confirm  ·  ○ deny", "Once armed, ✕ confirms; ○ still denies."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.permissionLegend(armed: row.armed), row.expected,
                           "armed=\(row.armed): \(row.reason)")
        }
    }

    func testPermissionBannerTextTable() {
        struct Row { let name: String; let pending: AppState.PendingPermission; let expected: String; let reason: String }
        func pending(_ name: String, _ detail: String, destructive: Bool, armed: Bool) -> AppState.PendingPermission {
            AppState.PendingPermission(id: "req-1", name: name, detail: detail,
                                       isDestructive: destructive, armed: armed)
        }
        let rows: [Row] = [
            Row(name: "plain request with detail",
                pending: pending("Bash", "npm test", destructive: false, armed: false),
                expected: "The agent wants to: Bash — npm test",
                reason: "Tool name and detail are joined by an em dash."),
            Row(name: "plain request without detail",
                pending: pending("WebFetch", "", destructive: false, armed: false),
                expected: "The agent wants to: WebFetch",
                reason: "An empty detail drops the dash."),
            Row(name: "destructive, not yet armed",
                pending: pending("Bash", "rm -rf build", destructive: true, armed: false),
                expected: "DESTRUCTIVE: Bash — rm -rf build",
                reason: "Destructive requests are labeled loudly."),
            Row(name: "destructive and armed",
                pending: pending("Bash", "rm -rf build", destructive: true, armed: true),
                expected: "DESTRUCTIVE: Bash — rm -rf build — press ✕ again to confirm",
                reason: "Armed requests tell the person the next ✕ confirms."),
            Row(name: "destructive without detail, armed",
                pending: pending("delete", "", destructive: true, armed: true),
                expected: "DESTRUCTIVE: delete — press ✕ again to confirm",
                reason: "The confirm suffix does not depend on the detail."),
            Row(name: "armed but not destructive",
                pending: pending("Edit", "main.swift", destructive: false, armed: true),
                expected: "The agent wants to: Edit — main.swift",
                reason: "Only destructive requests get the confirm wording; armed alone does not change the text."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.permissionBannerText(row.pending), row.expected,
                           "\(row.name): \(row.reason)")
        }
    }

    // MARK: - Cost chip

    func testCostChipTable() {
        struct Row { let name: String; let reportsUSD: Bool; let usd: Double; let tokens: Int; let expected: ViewLogic.CostChip?; let reason: String }
        let dollarsHelp = "Total cost of this session so far (CLI estimate)"
        let tokensHelp = "Tokens this session — this harness doesn't report dollar cost"
        let rows: [Row] = [
            Row(name: "dollars at session start", reportsUSD: true, usd: 0, tokens: 0,
                expected: .init(label: "$0.0000", help: dollarsHelp),
                reason: "A harness that reports dollars always shows them, even before the first turn."),
            Row(name: "dollars under one", reportsUSD: true, usd: 0.0123, tokens: 0,
                expected: .init(label: "$0.0123", help: dollarsHelp),
                reason: "Below $1 the chip shows four decimals."),
            Row(name: "dollars at one", reportsUSD: true, usd: 1, tokens: 0,
                expected: .init(label: "$1.00", help: dollarsHelp),
                reason: "From $1 the chip shows two decimals."),
            Row(name: "dollars above one", reportsUSD: true, usd: 12.5, tokens: 0,
                expected: .init(label: "$12.50", help: dollarsHelp),
                reason: "Two decimals above $1."),
            Row(name: "just under one rounds up", reportsUSD: true, usd: 0.99999, tokens: 0,
                expected: .init(label: "$1.0000", help: dollarsHelp),
                reason: "Current behavior: the format is chosen before rounding, so this reads $1.0000."),
            Row(name: "dollars win over tokens", reportsUSD: true, usd: 0.5, tokens: 5000,
                expected: .init(label: "$0.5000", help: dollarsHelp),
                reason: "When dollars are reported, token counts are not shown."),
            Row(name: "no dollars, no tokens", reportsUSD: false, usd: 0, tokens: 0,
                expected: nil,
                reason: "Hidden when the harness reports nothing — never a misleading $0.00 (issue #12)."),
            Row(name: "no dollars, stray cost ignored", reportsUSD: false, usd: 3.2, tokens: 0,
                expected: nil,
                reason: "A cost value from a harness that doesn't report dollars is not trusted."),
            Row(name: "negative tokens", reportsUSD: false, usd: 0, tokens: -5,
                expected: nil,
                reason: "Only a positive token count shows the chip."),
            Row(name: "one token", reportsUSD: false, usd: 0, tokens: 1,
                expected: .init(label: "1 tok", help: tokensHelp),
                reason: "Small counts are shown exactly."),
            Row(name: "just under a thousand", reportsUSD: false, usd: 0, tokens: 999,
                expected: .init(label: "999 tok", help: tokensHelp),
                reason: "Below 1000 there is no k suffix."),
            Row(name: "exactly a thousand", reportsUSD: false, usd: 0, tokens: 1000,
                expected: .init(label: "1.0k tok", help: tokensHelp),
                reason: "From 1000 the count switches to thousands with one decimal."),
            Row(name: "thousands", reportsUSD: false, usd: 0, tokens: 15_500,
                expected: .init(label: "15.5k tok", help: tokensHelp),
                reason: "One decimal of thousands."),
            Row(name: "millions stay in k", reportsUSD: false, usd: 0, tokens: 1_234_567,
                expected: .init(label: "1234.6k tok", help: tokensHelp),
                reason: "Current behavior: there is no M unit, large counts stay in thousands."),
        ]
        for row in rows {
            XCTAssertEqual(ViewLogic.costChip(reportsCostUSD: row.reportsUSD,
                                              totalCostUSD: row.usd,
                                              totalTokens: row.tokens),
                           row.expected, "\(row.name): \(row.reason)")
        }
    }

    // MARK: - Portability

    /// Acceptance criterion of #126: the extracted rules import neither
    /// SwiftUI nor AppKit, so a non-macOS UI (and later the Rust core) can
    /// reuse them unchanged.
    func testViewLogicFileImportsNeitherSwiftUINorAppKit() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PowerUpTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
            .appendingPathComponent("Sources/PowerUp/ViewLogic.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // An import declaration: optional attributes (`@testable`,
        // `@_exported`), then `import`, an optional kind (`struct`, …) and
        // the module path (`SwiftUI` or `SwiftUI.Color`).
        let imports: [[Substring]] = text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ").drop { $0.hasPrefix("@") } }
            .filter { $0.first == "import" }
            .map { Array($0) }
        XCTAssertTrue(imports.contains { $0.contains("Foundation") },
                      "Expected ViewLogic.swift to import Foundation only; found \(imports)")
        for forbidden in ["SwiftUI", "AppKit", "Cocoa", "UIKit"] {
            let found = imports.contains { tokens in
                tokens.contains { $0 == forbidden || $0.hasPrefix(forbidden + ".") }
            }
            XCTAssertFalse(found, "ViewLogic.swift must not import \(forbidden); found imports: \(imports)")
        }
    }
}
