import Foundation
import GameController
import CoreHaptics

/// Manages the connected controllers (DualSense or other extended gamepads)
/// and the one in the Controller slot (DESIGN.md v2.7 addendum §B): button →
/// `ControllerButton` event dispatch, light bar color, haptics, and battery
/// polling — all for the active controller only. Every other connected pad
/// is listed in `connected` for the Settings picker and is otherwise inert:
/// no events, no light (it is darkened), no haptics, no battery warning.
@MainActor
final class ControllerService: ObservableObject {
    // These five describe the controller in the slot; with the slot empty
    // (nothing connected, or a pinned pad that is away) they read as
    // "no controller", so nothing downstream responds.
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var controllerName: String?
    @Published private(set) var isDualSense: Bool = false
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var isCharging: Bool = false

    /// Every connected controller, most recently connected first.
    @Published private(set) var connected: [ConnectedController] = []
    /// The controller filling the Controller slot, chosen by
    /// `ControllerSlotSelector` from `connected` and `pinnedControllerID`;
    /// nil when the slot is empty.
    @Published private(set) var active: ConnectedController?

    /// The Controller slot pin (`AppConfig.controllerDeviceID`, which AppState
    /// keeps in sync); nil is Automatic. Changing it re-selects the slot.
    var pinnedControllerID: String? {
        didSet {
            guard pinnedControllerID != oldValue else { return }
            selectActive()
        }
    }

    var onButtonDown: ((ControllerButton) -> Void)?
    var onButtonUp: ((ControllerButton) -> Void)?
    /// Fired when the controller in the slot leaves it — it disconnected, or
    /// another controller took the slot (a newer pad in Automatic, or a pin
    /// change) — after the new slot state is in place and after its
    /// stuck-hold releases. Lets AppState force-release a stranded hold
    /// (v2.7 §C).
    var onDisconnect: (() -> Void)?
    /// Fired at most once per slot tenure when the active controller's polled
    /// battery first drops below the warning threshold while discharging.
    /// Carries the 0...1 level. Never fired for a pad outside the slot.
    var onLowBattery: ((Float) -> Void)?

    /// One connected controller. `device` is nil for a simulated pad (test
    /// hooks), which then reports `simulatedBattery` instead.
    private struct Pad {
        let info: ConnectedController
        let isDualSense: Bool
        let device: GCController?
        var simulatedBattery: (level: Float, state: GCDeviceBattery.State)?
    }

    /// Connected controllers, most recently connected first.
    private var pads: [Pad] = []
    private var hapticEngine: CHHapticEngine?
    private var batteryTimer: Timer?
    private var batteryWarningLatch = BatteryWarningLatch()

    /// Buttons of the active controller currently held down. Used to de-dup
    /// analog-trigger threshold jitter / duplicate events, and to release
    /// stuck holds when that controller leaves the slot.
    private var pressedButtons: Set<ControllerButton> = []

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// True once `start()` has run (readable so tests can prove it never did).
    private(set) var didStart = false

    /// The pad in the slot.
    private var activePad: Pad? {
        guard let id = active?.id else { return nil }
        return pads.first { $0.info.id == id }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        GCController.shouldMonitorBackgroundEvents = true

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor [weak self] in
                self?.handleConnect(controller)
            }
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor [weak self] in
                self?.handleDisconnect(controller)
            }
        }

        GCController.startWirelessControllerDiscovery(completionHandler: {})

        // Seed from already-paired controllers — they fire no synthetic
        // connect. In list order, so the last one is the most recent.
        for controller in GCController.controllers() {
            handleConnect(controller)
        }

        startBatteryTimer()
    }

    // MARK: - Connect / disconnect

    private func handleConnect(_ controller: GCController) {
        // The seed and a connect notification can both report the same pad.
        guard !pads.contains(where: { $0.device === controller }) else { return }
        // Deliver input handlers on the main queue so `MainActor.assumeIsolated`
        // in `wire(...)` is valid and events are processed in exact delivery
        // order (an unstructured Task hop has no ordering guarantee).
        controller.handlerQueue = .main
        let pad = makePad(name: controller.vendorName ?? "Controller",
                          kind: controller.productCategory,
                          isDualSense: controller.productCategory == GCProductCategoryDualSense,
                          device: controller)
        wireButtons(on: controller)
        addPad(pad)

        // GameController often reports a nil/unpopulated `battery` in the same
        // run-loop turn as the connect notification, and the poll timer only
        // ticks every 60s — re-poll shortly after connecting so the gauge isn't
        // stuck on "--%" for a minute.
        Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let controller, self.activePad?.device === controller else { return }
            self.pollBattery()
        }
    }

    private func handleDisconnect(_ controller: GCController) {
        guard let pad = pads.first(where: { $0.device === controller }) else { return }
        removePad(id: pad.info.id)
    }

    /// The record of a new connection, with its id and picker name.
    private func makePad(name: String, kind: String, isDualSense: Bool,
                         device: GCController?) -> Pad {
        let identity = Self.connectionIdentity(kind: kind, name: name,
                                               taken: Set(pads.map(\.info.id)))
        return Pad(info: ConnectedController(id: identity.id,
                                             profileID: DeviceProfile.dualSenseID,
                                             displayName: identity.displayName),
                   isDualSense: isDualSense,
                   device: device,
                   simulatedBattery: nil)
    }

    /// A new connection, shared by a real connect and `simulateConnect`: it
    /// becomes the most recent, the slot is re-selected, and a pad that does
    /// not get the slot is darkened so only the active one is lit.
    private func addPad(_ pad: Pad) {
        pads.insert(pad, at: 0)
        selectActive()
        if active?.id != pad.info.id {
            darken(pad)
        }
    }

    /// A dropped connection, shared by a real disconnect and
    /// `simulateDisconnect`. If it was in the slot, the selector hands the
    /// slot on (Automatic: the next most recent; pinned: nobody).
    private func removePad(id: String) {
        pads.removeAll { $0.info.id == id }
        selectActive()
    }

    /// Re-runs the Controller slot rule. When the slot's controller changes:
    /// the new one becomes what every published field, write and poll refers
    /// to; the old one, if still connected, is darkened; every button still
    /// held on the old one is released (so AppState can end a hold it
    /// owned); then the change is reported through `onDisconnect`.
    private func selectActive() {
        let list = pads.map(\.info)
        if list != connected { connected = list }
        let next = ControllerSlotSelector(mostRecentlyConnectedFirst: list,
                                          pinnedID: pinnedControllerID).active
        guard next?.id != active?.id else { return }

        let previous = active
        let leavingPad = activePad // still connected only on a slot change

        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil // recreate lazily for the new controller
        // Snapshot any holds still down on the controller leaving the slot.
        let stuckButtons = pressedButtons
        pressedButtons.removeAll()
        batteryWarningLatch.reset() // one warning per controller in the slot

        active = next
        isConnected = next != nil
        controllerName = next?.displayName
        isDualSense = activePad?.isDualSense ?? false
        if let leavingPad {
            darken(leavingPad)
        }
        pollBattery()

        // Release any buttons still pressed on the controller that left the
        // slot, so AppState can release a stranded hold (e.g. mid-PTT drop).
        for button in stuckButtons {
            onButtonUp?(button)
        }
        if previous != nil {
            onDisconnect?()
        }
    }

    /// The id of a new connection and its picker name: the device kind and
    /// vendor name, which a reconnect of the same pad reproduces (so a pin
    /// finds it again), plus an ordinal when an identical pad is already
    /// connected. Stable for the life of the connection: assigned once, never
    /// renumbered. GameController exposes no serial number, so two identical
    /// pads are told apart only by connection order.
    nonisolated static func connectionIdentity(kind: String, name: String,
                                               taken: Set<String>) -> (id: String, displayName: String) {
        let base = "\(kind)/\(name)"
        guard taken.contains(base) else { return (base, name) }
        var ordinal = 2
        while taken.contains("\(base)#\(ordinal)") { ordinal += 1 }
        return ("\(base)#\(ordinal)", "\(name) \(ordinal)")
    }

    // MARK: - Button wiring

    private func wireButtons(on controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        func wire(_ input: GCControllerButtonInput?, _ button: ControllerButton) {
            // `controller` must be captured weakly: the handler is stored on the
            // controller's own inputs, so a strong capture is a retain cycle
            // that would leak every disconnected pad.
            input?.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
                // handlerQueue is `.main` (set on connect), so this handler runs
                // on the main queue and is therefore already main-actor isolated.
                // Assume that isolation synchronously — no Task hop — so events
                // are processed in exact delivery order (an unstructured Task has
                // no ordering guarantee, which let a button's `up` overtake its
                // `down` and wedge PTT). No data race: all state touched here is
                // only ever accessed on the main actor.
                MainActor.assumeIsolated {
                    guard let self, let controller,
                          let pad = self.pads.first(where: { $0.device === controller }) else { return }
                    self.receive(button, pressed: pressed, from: pad.info.id)
                }
            }
        }

        wire(gamepad.buttonA, .cross)
        wire(gamepad.buttonB, .circle)
        wire(gamepad.buttonX, .square)
        wire(gamepad.buttonY, .triangle)

        wire(gamepad.dpad.up, .dpadUp)
        wire(gamepad.dpad.down, .dpadDown)
        wire(gamepad.dpad.left, .dpadLeft)
        wire(gamepad.dpad.right, .dpadRight)

        wire(gamepad.leftShoulder, .l1)
        wire(gamepad.rightShoulder, .r1)
        wire(gamepad.leftTrigger, .l2)
        wire(gamepad.rightTrigger, .r2)
        wire(gamepad.leftThumbstickButton, .l3)
        wire(gamepad.rightThumbstickButton, .r3)

        wire(gamepad.buttonOptions, .create)
        wire(gamepad.buttonMenu, .options)
        wire(gamepad.buttonHome, .ps)

        if let dualSense = gamepad as? GCDualSenseGamepad {
            wire(dualSense.touchpadButton, .touchpad)
        }
    }

    /// Input from one connected pad, shared by the pads' input handlers and
    /// `simulateButton`: only the controller in the slot delivers presses;
    /// every other pad is inert.
    private func receive(_ button: ControllerButton, pressed: Bool, from padID: String) {
        guard padID == active?.id else { return }
        deliver(button, pressed: pressed)
    }

    /// Press/release dispatch for the active controller.
    private func deliver(_ button: ControllerButton, pressed: Bool) {
        if pressed {
            // De-dup: ignore a repeat press for an already-held button
            // (analog-trigger threshold jitter, duplicate events).
            guard pressedButtons.insert(button).inserted else { return }
            onButtonDown?(button)
        } else {
            // Ignore an up for a button we don't consider held.
            guard pressedButtons.remove(button) != nil else { return }
            onButtonUp?(button)
        }
    }

    // MARK: - Light bar

    /// Colors the active controller's light bar; no-op with the slot empty.
    func setLight(r: Float, g: Float, b: Float) {
        record(.light(r: r, g: g, b: b), to: active?.id)
        guard let light = activePad?.device?.light else { return }
        light.color = GCColor(red: r, green: g, blue: b)
    }

    /// Turns off the light of a connected pad that is not in the slot, so a
    /// second pad on the desk is dark rather than showing a misleading color.
    private func darken(_ pad: Pad) {
        record(.light(r: 0, g: 0, b: 0), to: pad.info.id)
        guard let light = pad.device?.light else { return }
        light.color = GCColor(red: 0, green: 0, blue: 0)
    }

    // MARK: - Haptics

    private func engine(for controller: GCController) -> CHHapticEngine? {
        if let hapticEngine {
            return hapticEngine
        }
        guard let engine = controller.haptics?.createEngine(withLocality: .default) else {
            return nil
        }
        engine.stoppedHandler = { _ in
            Task { @MainActor [weak self] in
                self?.hapticEngine = nil
            }
        }
        engine.resetHandler = {
            Task { @MainActor [weak self] in
                self?.hapticEngine = nil
            }
        }
        do {
            try engine.start()
        } catch {
            return nil
        }
        hapticEngine = engine
        return engine
    }

    /// Rumbles the active controller; no-op with the slot empty.
    func rumble(intensity: Float, duration: TimeInterval) {
        record(.rumble(intensity: intensity, duration: duration), to: active?.id)
        guard let controller = activePad?.device, controller.haptics != nil else { return }
        guard let engine = engine(for: controller) else { return }

        let intensityParam = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
        let sharpnessParam = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)

        let eventType: CHHapticEvent.EventType = duration > 0.1 ? .hapticContinuous : .hapticTransient
        let event = CHHapticEvent(
            eventType: eventType,
            parameters: [intensityParam, sharpnessParam],
            relativeTime: 0,
            duration: max(duration, 0.01)
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Swallow — haptics are best-effort.
        }
    }

    // MARK: - Battery

    private func startBatteryTimer() {
        batteryTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.pollBattery()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer

        // A repeating Timer's first fire is a full interval out — poll once now
        // so the gauge starts from a real reading instead of a 60s-stale blank.
        pollBattery()
    }

    /// Reads the active controller's battery only: a pad outside the slot
    /// never moves the gauge or warns.
    private func pollBattery() {
        guard let reading = activePad.flatMap(batteryReading) else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = reading.level
        isCharging = reading.state == .charging || reading.state == .full

        if batteryWarningLatch.shouldWarn(level: reading.level, state: reading.state) {
            onLowBattery?(reading.level)
        }
    }

    private func batteryReading(of pad: Pad) -> (level: Float, state: GCDeviceBattery.State)? {
        guard let device = pad.device else { return pad.simulatedBattery }
        guard let battery = device.battery else { return nil }
        return (battery.batteryLevel, battery.batteryState)
    }

    // MARK: - Test hooks (internal; production never calls these)

    /// When true, every light and haptic write is appended to
    /// `recordedWrites` — with or without a pad — and still goes on to the
    /// pad exactly as it would otherwise. Off in production, so nothing
    /// accumulates there.
    var recordsOutput = false

    /// The light and haptic writes made while `recordsOutput` was on, oldest
    /// first, each with the controller it went to (nil: the slot was empty).
    private(set) var recordedWrites: [ControllerOutputRecord] = []

    /// `recordedWrites` without the targets.
    var recordedOutput: [ControllerOutput] {
        recordedWrites.map(\.output)
    }

    func clearRecordedOutput() {
        recordedWrites.removeAll()
    }

    private func record(_ output: ControllerOutput, to controllerID: String?) {
        guard recordsOutput else { return }
        recordedWrites.append(ControllerOutputRecord(controllerID: controllerID, output: output))
    }

    /// Test hook: connects a pad as if GameController had reported one,
    /// without any hardware, through the same path as a real connect (it
    /// becomes the most recent; the slot is re-selected). Nothing is held on
    /// a fresh connection. Returns the pad as `connected` lists it.
    @discardableResult
    func simulateConnect(name: String = "DualSense Wireless Controller",
                         isDualSense: Bool = true) -> ConnectedController {
        let pad = makePad(name: name,
                          kind: isDualSense ? GCProductCategoryDualSense : "Gamepad",
                          isDualSense: isDualSense,
                          device: nil)
        addPad(pad)
        return pad.info
    }

    /// Test hook: a press or release from a connected pad (`id`; nil means
    /// the active one), through the same slot check and de-dup as its input
    /// handlers. Ignored unless that pad is in the slot.
    func simulateButton(_ button: ControllerButton, pressed: Bool, on id: String? = nil) {
        guard let padID = id ?? active?.id else { return }
        receive(button, pressed: pressed, from: padID)
    }

    /// Test hook: a connected pad (`id`; nil means the active one) drops,
    /// through the same path as a GameController disconnect — if it was in
    /// the slot, its held buttons are released, then `onDisconnect` fires.
    /// Ignored when there is no such pad.
    func simulateDisconnect(_ id: String? = nil) {
        guard let target = id ?? active?.id,
              pads.contains(where: { $0.info.id == target }) else { return }
        removePad(id: target)
    }

    /// Test hook: what a pad's battery reads (`id`; nil means the active
    /// one), followed by a poll as the timer would run one. Ignored when
    /// there is no such simulated pad.
    func simulateBattery(level: Float, state: GCDeviceBattery.State, on id: String? = nil) {
        guard let target = id ?? active?.id,
              let index = pads.firstIndex(where: { $0.info.id == target && $0.device == nil }) else { return }
        pads[index].simulatedBattery = (level, state)
        pollBattery()
    }
}

/// One write to a pad's outputs, as recorded by
/// `ControllerService.recordedWrites` (tests only).
enum ControllerOutput: Equatable {
    case light(r: Float, g: Float, b: Float)
    case rumble(intensity: Float, duration: TimeInterval)
}

/// A recorded write and the controller it went to (tests only).
struct ControllerOutputRecord: Equatable {
    /// The `ConnectedController.id` written to; nil when the slot was empty.
    let controllerID: String?
    let output: ControllerOutput
}

/// Once-per-connection latch behind the low-battery warning. Fires only while
/// the pack is actually discharging (never charging/full/unknown), and treats
/// a 0.0 level as "not populated yet" — GameController reports zeros briefly
/// around connect before the real reading arrives.
struct BatteryWarningLatch {
    static let threshold: Float = 0.2

    private var didWarn = false

    mutating func reset() { didWarn = false }

    mutating func shouldWarn(level: Float?, state: GCDeviceBattery.State) -> Bool {
        guard !didWarn, state == .discharging,
              let level, level > 0, level < Self.threshold else { return false }
        didWarn = true
        return true
    }
}
