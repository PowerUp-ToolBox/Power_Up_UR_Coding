import XCTest
@testable import PowerUp

/// The injector's own rules, which stay in Swift (DESIGN v2.14 C): which
/// route a configured target kind takes and which cmux workspace "auto"
/// types into. Pure functions only: nothing here runs cmux or posts a key.
final class RemoteRoutingTests: XCTestCase {

    func testAnUnrecognisedTargetKindFallsBackToCmux() {
        // A hand-edited config must never switch on keystroke injection,
        // which needs Accessibility trust; cmux needs no permission (HK-208).
        for kind in ["cmux", "", "Frontmost", "APP", "keystrokes", " frontmost"] {
            var config = AppConfig.defaultConfig()
            config.remoteTargetKind = kind
            config.remoteAppBundleID = "com.example.terminal"
            XCTAssertEqual(RemoteControlService.route(for: config), .cmux, "kind \(kind.debugDescription)")
        }
    }

    func testFrontmostHasNoBundleIDAndTheAppRouteTrimsItsOwn() {
        // HK-209: frontmost never activates anything; the app route trims the
        // bundle id and reads a blank one as nil.
        var config = AppConfig.defaultConfig()
        config.remoteTargetKind = "frontmost"
        config.remoteAppBundleID = "com.example.terminal"
        XCTAssertEqual(RemoteControlService.route(for: config), .injection(bundleID: nil))

        config.remoteTargetKind = "app"
        for (bundleID, expected) in [("com.example.terminal", "com.example.terminal"),
                                     (" \tcom.example.terminal\n", "com.example.terminal"),
                                     ("  \n", nil),
                                     ("", nil)] as [(String?, String?)] {
            config.remoteAppBundleID = bundleID
            XCTAssertEqual(RemoteControlService.route(for: config), .injection(bundleID: expected),
                           "bundle id \(String(describing: bundleID))")
        }
        config.remoteAppBundleID = nil
        XCTAssertEqual(RemoteControlService.route(for: config), .injection(bundleID: nil))
    }

    func testConfiguredValuesAreTrimmedAndBlankMeansUnset() {
        // A blank configured workspace means "auto", not a --workspace "" (HK-209).
        XCTAssertNil(RemoteControlService.trimmedOrNil(nil))
        XCTAssertNil(RemoteControlService.trimmedOrNil(""))
        XCTAssertNil(RemoteControlService.trimmedOrNil(" \t\r\n\u{2028}\u{200B}"))
        XCTAssertEqual(RemoteControlService.trimmedOrNil("  workspace:7\n"), "workspace:7")
    }

    func testAutoTargetIsTheSelectedWorkspaceElseTheFirst() {
        // HK-204: with no workspace configured, the one cmux has selected,
        // else the first listed, else none (the person is told to open one).
        let first = CmuxWorkspace(ref: "workspace:3", title: "Notes", selected: false)
        let selected = CmuxWorkspace(ref: "workspace:11", title: "Build", selected: true)
        let later = CmuxWorkspace(ref: "workspace:12", title: "Review", selected: true)

        XCTAssertEqual(RemoteControlService.autoTargetWorkspace(in: [first, selected, later]), selected)
        XCTAssertEqual(RemoteControlService.autoTargetWorkspace(in: [first]), first)
        XCTAssertNil(RemoteControlService.autoTargetWorkspace(in: []))
    }

    func testTargetArgumentsPutTheWorkspaceFirstAndSkipEmptyValues() {
        XCTAssertEqual(RemoteControlService.targetArguments(workspace: "workspace:11", surface: "surface:2"),
                       ["--workspace", "workspace:11", "--surface", "surface:2"])
        XCTAssertEqual(RemoteControlService.targetArguments(workspace: "workspace:11", surface: nil),
                       ["--workspace", "workspace:11"])
        XCTAssertEqual(RemoteControlService.targetArguments(workspace: nil, surface: "surface:2"),
                       ["--surface", "surface:2"])
        XCTAssertEqual(RemoteControlService.targetArguments(workspace: "", surface: ""), [])
        XCTAssertEqual(RemoteControlService.targetArguments(workspace: nil, surface: nil), [])
    }
}
