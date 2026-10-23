import Foundation

/// One choice in the Settings → Devices Controller picker.
struct ControllerPickerRow: Identifiable, Equatable {
    /// What choosing this row stores in `AppConfig.controllerDeviceID`;
    /// `nil` is Automatic.
    let pin: String?
    /// The menu text, including the "in use" / "not connected" marks.
    let title: String
    /// False only for a pinned controller that is away.
    let isConnected: Bool
    /// True for the one controller filling the Controller slot right now.
    let isInSlot: Bool

    var id: String { pin.map { "controller:\($0)" } ?? "automatic" }
}

/// What the Controller picker shows (DESIGN.md v2.7 addendum §B, ADR 0013):
/// Automatic, then every connected controller most recently connected first,
/// the one in the slot marked, and a pinned controller that is away kept as
/// a "not connected" row so the picker never snaps back to Automatic on its
/// own. Pure: the view only renders these rows and binds the selection to
/// `controllerDeviceID`.
enum ControllerPicker {

    static func rows(connected: [ConnectedController],
                     active: ConnectedController?,
                     pinnedID: String?) -> [ControllerPickerRow] {
        var rows = [ControllerPickerRow(pin: nil, title: "Automatic",
                                        isConnected: true, isInSlot: false)]
        for controller in connected {
            let inSlot = controller.id == active?.id
            rows.append(ControllerPickerRow(
                pin: controller.id,
                title: inSlot ? "\(controller.displayName) — in use" : controller.displayName,
                isConnected: true,
                isInSlot: inSlot))
        }
        if let pinnedID, !connected.contains(where: { $0.id == pinnedID }) {
            rows.append(ControllerPickerRow(
                pin: pinnedID,
                title: "\(ControllerService.displayName(forID: pinnedID)) — not connected",
                isConnected: false,
                isInSlot: false))
        }
        return rows
    }

    /// The line under the picker: which controller responds, and why none
    /// does when the slot is empty.
    static func note(connected: [ConnectedController],
                     active: ConnectedController?,
                     pinnedID: String?) -> String {
        let keyboard = "The keyboard and the mic button still work."
        if let pinnedID {
            if let pinned = connected.first(where: { $0.id == pinnedID }) {
                return "Only \(pinned.displayName) responds. Other controllers are ignored."
            }
            let name = ControllerService.displayName(forID: pinnedID)
            return "\(name) is not connected, so no controller responds until it returns. Choose Automatic to use another controller. \(keyboard)"
        }
        guard let active else {
            return "No controller is connected. \(keyboard)"
        }
        return "Automatic uses the most recently connected controller: \(active.displayName). Other controllers are ignored."
    }
}
