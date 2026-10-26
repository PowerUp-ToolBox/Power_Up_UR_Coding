import XCTest
@testable import PowerUp

/// Pins the Settings → Devices Controller picker (#132, DESIGN.md v2.7
/// addendum §B): Automatic first, then every connected controller most
/// recently connected first, the one in the slot marked, and a pinned
/// controller that is away kept as a "not connected" row. Pure data in,
/// rows out — no SwiftUI, no hardware.
final class ControllerPickerTests: XCTestCase {

    private let desk = ConnectedController(id: "DualSense/DualSense Wireless Controller",
                                           profileID: "dualsense",
                                           displayName: "DualSense Wireless Controller")
    private let couch = ConnectedController(id: "DualSense/DualSense Wireless Controller#2",
                                            profileID: "dualsense",
                                            displayName: "DualSense Wireless Controller 2")

    // MARK: - Rows

    /// With nothing connected the picker still offers Automatic, and only it.
    func testNoControllersListsOnlyAutomatic() {
        let rows = ControllerPicker.rows(connected: [], active: nil, pinnedID: nil)

        XCTAssertEqual(rows, [
            ControllerPickerRow(pin: nil, title: "Automatic", isConnected: true, isInSlot: false),
        ])
    }

    /// Automatic first, then every connected controller in the service's
    /// order (most recent first), with the one in the slot marked "in use".
    func testAutomaticListsEveryConnectedControllerAndMarksTheOneInTheSlot() {
        let rows = ControllerPicker.rows(connected: [couch, desk], active: couch, pinnedID: nil)

        XCTAssertEqual(rows, [
            ControllerPickerRow(pin: nil, title: "Automatic", isConnected: true, isInSlot: false),
            ControllerPickerRow(pin: couch.id, title: "DualSense Wireless Controller 2 — in use",
                                isConnected: true, isInSlot: true),
            ControllerPickerRow(pin: desk.id, title: "DualSense Wireless Controller",
                                isConnected: true, isInSlot: false),
        ])
    }

    /// A pinned controller that is connected is the marked row, even when it
    /// is not the most recent connection.
    func testPinnedConnectedControllerIsTheMarkedRow() {
        let rows = ControllerPicker.rows(connected: [couch, desk], active: desk, pinnedID: desk.id)

        XCTAssertEqual(rows.map(\.isInSlot), [false, false, true])
        XCTAssertEqual(rows.last?.title, "DualSense Wireless Controller — in use")
        XCTAssertEqual(rows.count, 3, "a connected pin needs no extra row")
    }

    /// A pinned controller that is switched off stays selectable as a
    /// "not connected" row, so the picker never snaps back to Automatic and
    /// the person can see why nothing responds.
    func testPinnedControllerThatIsAwayIsListedAsNotConnected() {
        let rows = ControllerPicker.rows(connected: [couch], active: nil, pinnedID: desk.id)

        XCTAssertEqual(rows, [
            ControllerPickerRow(pin: nil, title: "Automatic", isConnected: true, isInSlot: false),
            ControllerPickerRow(pin: couch.id, title: "DualSense Wireless Controller 2",
                                isConnected: true, isInSlot: false),
            ControllerPickerRow(pin: desk.id, title: "DualSense Wireless Controller — not connected",
                                isConnected: false, isInSlot: false),
        ])
    }

    /// No row is marked in use when the slot is empty, even though a pad is
    /// connected (the pin points elsewhere).
    func testEmptySlotMarksNoRow() {
        let rows = ControllerPicker.rows(connected: [couch, desk], active: nil, pinnedID: "elsewhere")

        XCTAssertFalse(rows.contains(where: \.isInSlot))
    }

    /// Every row's selection value is distinct, so the menu has one tag per
    /// choice, and Automatic's is the nil the config stores for it.
    func testRowIDsAreUniqueAndAutomaticPinsNil() {
        let rows = ControllerPicker.rows(connected: [couch, desk], active: couch, pinnedID: "gone/Pad")

        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertNil(rows.first?.pin)
        XCTAssertEqual(rows.map(\.pin), [nil, couch.id, desk.id, "gone/Pad"])
    }

    // MARK: - Note under the picker

    func testNoteWithNoControllerSaysTheKeyboardStillWorks() {
        XCTAssertEqual(
            ControllerPicker.note(connected: [], active: nil, pinnedID: nil),
            "No controller is connected. The keyboard and the mic button still work."
        )
    }

    func testNoteInAutomaticNamesTheControllerInUse() {
        XCTAssertEqual(
            ControllerPicker.note(connected: [couch, desk], active: couch, pinnedID: nil),
            "Automatic uses the most recently connected controller: DualSense Wireless Controller 2. Other controllers are ignored."
        )
    }

    func testNoteWhenPinnedAndConnected() {
        XCTAssertEqual(
            ControllerPicker.note(connected: [couch, desk], active: desk, pinnedID: desk.id),
            "Only DualSense Wireless Controller responds. Other controllers are ignored."
        )
    }

    func testNoteWhenPinnedControllerIsAwayExplainsWhyNothingResponds() {
        XCTAssertEqual(
            ControllerPicker.note(connected: [couch], active: nil, pinnedID: desk.id),
            "DualSense Wireless Controller is not connected, so no controller responds until it returns. Choose Automatic to use another controller. The keyboard and the mic button still work."
        )
    }

    // MARK: - Names for a pin that is away

    /// A pin stores only the connection id; its picker name is the name the
    /// controller had when it was connected.
    func testDisplayNameForIDInvertsConnectionIdentity() {
        let first = ControllerService.connectionIdentity(kind: "DualSense",
                                                         name: "DualSense Wireless Controller",
                                                         taken: [])
        let second = ControllerService.connectionIdentity(kind: "DualSense",
                                                          name: "DualSense Wireless Controller",
                                                          taken: [first.id])
        let third = ControllerService.connectionIdentity(kind: "DualSense",
                                                         name: "DualSense Wireless Controller",
                                                         taken: [first.id, second.id])

        for identity in [first, second, third] {
            XCTAssertEqual(ControllerService.displayName(forID: identity.id), identity.displayName)
        }
    }

    /// A hand-edited or foreign id is shown as written rather than mangled.
    func testDisplayNameForAnUnrecognisedIDIsTheIDItself() {
        XCTAssertEqual(ControllerService.displayName(forID: "a-pad-that-is-switched-off"),
                       "a-pad-that-is-switched-off")
        XCTAssertEqual(ControllerService.displayName(forID: "DualSense/"), "DualSense/")
        XCTAssertEqual(ControllerService.displayName(forID: "Gamepad/Pad #1"), "Pad #1",
                       "only an ordinal of 2 or more is a connection number")
    }
}
