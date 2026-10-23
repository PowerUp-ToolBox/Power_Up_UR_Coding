import Foundation

/// Product rules the main window shows, kept out of the SwiftUI views so they
/// can be tested and so a non-macOS UI can call the same rules (#126, the
/// same pattern DESIGN v2.6 used for `AppState.derivedStatus`).
///
/// Everything here is a pure function: input state in, text (or nil) out.
/// This file deliberately imports Foundation only — never SwiftUI or AppKit;
/// `ViewLogicTests` enforces that. Colors, symbols and layout stay in the
/// views.
enum ViewLogic {

    // MARK: - Push-to-talk hint

    /// Friendly name of whichever button is currently mapped to push-to-talk,
    /// falling back to a dictate-to-draft mapping so a person who only mapped
    /// `.pushToTalkDraft` still gets a hint instead of none at all. Ties are
    /// broken by `ControllerButton.allCases` order. Nil when neither is mapped.
    static func pushToTalkButtonName(in mapping: [ControllerButton: Action]) -> String? {
        for button in ControllerButton.allCases where mapping[button] == .pushToTalk {
            return button.displayName
        }
        for button in ControllerButton.allCases where mapping[button] == .pushToTalkDraft {
            return button.displayName
        }
        return nil
    }

    // MARK: - Empty transcript

    /// The line under "Ready when you are" on the empty-transcript card. Names
    /// the push-to-talk button when one is mapped (see `pushToTalkButtonName`);
    /// otherwise leads with the mic and ⌘D so a controller-less launch never
    /// reads as a dead end (DESIGN v2.6 C).
    static func emptyTranscriptPrompt(pushToTalkHint: String?) -> String {
        if let pushToTalkHint {
            return "Hold \(pushToTalkHint) on the controller and speak, click the mic (or press ⌘D) to dictate, or type a message below."
        }
        return "Click the mic (or press ⌘D) to dictate, or type a message below — no controller needed."
    }

    // MARK: - Controller info chip

    /// The name shown in the top bar's controller chip. A non-empty vendor
    /// name always wins; otherwise "Controller" or "No controller".
    static func controllerChipName(controllerName: String?, isConnected: Bool) -> String {
        if let controllerName, !controllerName.isEmpty { return controllerName }
        return isConnected ? "Controller" : "No controller"
    }

    /// Tooltip of the controller chip: while the slot is empty, the
    /// `pinnedAwayNote` when a pin is what empties it, else the pairing
    /// pointer; otherwise the chip name (tagged "(DualSense)" for a
    /// DualSense).
    static func controllerChipHelp(controllerName: String?, isConnected: Bool, isDualSense: Bool,
                                   pinnedAwayNote: String? = nil) -> String {
        guard isConnected else {
            return pinnedAwayNote ?? "No controller connected — see the pairing steps in the sidebar"
        }
        let name = controllerChipName(controllerName: controllerName, isConnected: isConnected)
        return isDualSense ? "\(name) (DualSense)" : name
    }

    // MARK: - Pinned controller away

    /// Why the Controller slot is empty when a controller *is* connected: the
    /// slot is pinned to a controller that is away, so every connected one is
    /// ignored (DESIGN v2.7 §B). The chip help and the sidebar show this
    /// instead of the pairing steps, which would tell a person with a working
    /// controller to pair it again. Nil whenever the pairing steps are right:
    /// the slot is filled, nothing is pinned, or nothing is connected at all.
    static func pinnedControllerAwayNote(connected: [ConnectedController],
                                         active: ConnectedController?,
                                         pinnedID: String?) -> String? {
        guard active == nil, let pinnedID, !connected.isEmpty,
              !connected.contains(where: { $0.id == pinnedID }) else { return nil }
        let name = ControllerService.displayName(forID: pinnedID)
        return "\(name) isn't connected — choose Automatic in Settings → Devices to use another controller"
    }

    // MARK: - Permission banner

    /// Title of the banner's approve button: "Allow", retitled "Confirm" once a
    /// destructive request is armed (DESIGN v2.6 C).
    static func permissionAllowButtonTitle(armed: Bool) -> String {
        armed ? "Confirm" : "Allow"
    }

    /// The ✕ / ○ controller legend next to the banner buttons.
    static func permissionLegend(armed: Bool) -> String {
        armed ? "✕ confirm  ·  ○ deny" : "✕ allow  ·  ○ deny"
    }

    /// The banner's main line: what the agent wants, flagged DESTRUCTIVE when
    /// the classifier said so, with the press-again prompt once armed.
    static func permissionBannerText(_ pending: AppState.PendingPermission) -> String {
        let what = pending.detail.isEmpty ? pending.name : "\(pending.name) — \(pending.detail)"
        if pending.isDestructive {
            return pending.armed
                ? "DESTRUCTIVE: \(what) — press ✕ again to confirm"
                : "DESTRUCTIVE: \(what)"
        }
        return "The agent wants to: \(what)"
    }

    // MARK: - Cost chip

    /// What the cost chip shows: its label and tooltip.
    struct CostChip: Equatable {
        let label: String
        let help: String
    }

    /// Dollars when the harness reports them (built-in Claude), a token count
    /// when only usage is known (the Claude ACP bridge), nil — chip hidden —
    /// when the harness reports nothing (opencode). Never a misleading $0.00
    /// (issue #12, DESIGN v2.2 D).
    static func costChip(reportsCostUSD: Bool, totalCostUSD: Double, totalTokens: Int) -> CostChip? {
        if reportsCostUSD {
            return CostChip(label: costString(totalCostUSD),
                            help: "Total cost of this session so far (CLI estimate)")
        }
        guard totalTokens > 0 else { return nil }
        return CostChip(label: tokenString(totalTokens),
                        help: "Tokens this session — this harness doesn't report dollar cost")
    }

    /// "$0.0123" below a dollar, "$1.00" from a dollar up.
    static func costString(_ usd: Double) -> String {
        String(format: usd >= 1 ? "$%.2f" : "$%.4f", usd)
    }

    /// "999 tok" below a thousand, "1.2k tok" from a thousand up.
    static func tokenString(_ tokens: Int) -> String {
        if tokens >= 1000 { return String(format: "%.1fk tok", Double(tokens) / 1000) }
        return "\(tokens) tok"
    }
}
