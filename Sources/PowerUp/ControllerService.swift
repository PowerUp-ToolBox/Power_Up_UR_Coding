import Foundation
import GameController
import CoreHaptics

/// Manages a connected DualSense (or other extended gamepad) controller:
/// button → `ControllerButton` event dispatch, light bar color, haptics, and
/// battery polling.
@MainActor
final class ControllerService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var controllerName: String?
    @Published private(set) var isDualSense: Bool = false
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var isCharging: Bool = false

    var onButtonDown: ((ControllerButton) -> Void)?
    var onButtonUp: ((ControllerButton) -> Void)?
    /// Fired when the current controller disconnects (after any fallback and
    /// after stuck-hold releases). Lets AppState force-release a stranded hold.
    var onDisconnect: (() -> Void)?
    /// Fired at most once per connection when the polled battery first drops
    /// below the warning threshold while discharging. Carries the 0...1 level.
    var onLowBattery: ((Float) -> Void)?

    private var currentController: GCController?
    private var hapticEngine: CHHapticEngine?
    private var batteryTimer: Timer?
    private var batteryWarningLatch = BatteryWarningLatch()

    /// Buttons currently held down. Used to de-dup analog-trigger threshold
    /// jitter / duplicate events, and to release stuck holds on disconnect.
    private var pressedButtons: Set<ControllerButton> = []

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    private var didStart = false

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

        // Seed from already-paired controllers — they fire no synthetic connect.
        for controller in GCController.controllers() {
            handleConnect(controller)
        }

        startBatteryTimer()
    }

    // MARK: - Connect / disconnect

    private func handleConnect(_ controller: GCController) {
        // Track the most recent controller as "the" controller.
        currentController = controller
        // Deliver input handlers on the main queue so `MainActor.assumeIsolated`
        // in `wire(...)` is valid and events are processed in exact delivery
        // order (an unstructured Task hop has no ordering guarantee).
        controller.handlerQueue = .main
        isConnected = true
        controllerName = controller.vendorName ?? "Controller"
        isDualSense = controller.productCategory == GCProductCategoryDualSense

        hapticEngine = nil // recreate lazily for the new connection
        batteryWarningLatch.reset() // one warning per connection, even a swap
        wireButtons(on: controller)
        pollBattery()

        // GameController often reports a nil/unpopulated `battery` in the same
        // run-loop turn as the connect notification, and the poll timer only
        // ticks every 60s — re-poll shortly after connecting so the gauge isn't
        // stuck on "--%" for a minute.
        Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let controller, self.currentController === controller else { return }
            self.pollBattery()
        }
    }

    private func handleDisconnect(_ controller: GCController) {
        guard controller === currentController else { return }

        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil

        // Snapshot any holds still down at drop time. `handleConnect(next)`
        // below rewires and clears `pressedButtons`, so capture first.
        let stuckButtons = pressedButtons

        // Fall back to another connected controller, if any.
        let remaining = GCController.controllers().filter { $0 !== controller }
        if let next = remaining.last {
            handleConnect(next)
        } else {
            currentController = nil
            isConnected = false
            controllerName = nil
            isDualSense = false
            batteryLevel = nil
            isCharging = false
            batteryWarningLatch.reset()
        }

        // Release any buttons still pressed when the pad dropped BEFORE clearing
        // the set, so AppState can release a stranded hold (e.g. mid-PTT drop).
        for button in stuckButtons {
            onButtonUp?(button)
        }
        pressedButtons.removeAll()

        onDisconnect?()
    }

    // MARK: - Button wiring

    private func wireButtons(on controller: GCController) {
        // Fresh press-tracking for the newly-wired controller.
        pressedButtons.removeAll()
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
                    guard let self, let controller, self.currentController === controller else { return }
                    if pressed {
                        // De-dup: ignore a repeat press for an already-held button
                        // (analog-trigger threshold jitter, duplicate events).
                        guard self.pressedButtons.insert(button).inserted else { return }
                        self.onButtonDown?(button)
                    } else {
                        // Ignore an up for a button we don't consider held.
                        guard self.pressedButtons.remove(button) != nil else { return }
                        self.onButtonUp?(button)
                    }
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

    // MARK: - Light bar

    func setLight(r: Float, g: Float, b: Float) {
        guard let light = currentController?.light else { return }
        light.color = GCColor(red: r, green: g, blue: b)
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

    func rumble(intensity: Float, duration: TimeInterval) {
        guard let controller = currentController, controller.haptics != nil else { return }
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

    private func pollBattery() {
        guard let battery = currentController?.battery else {
            batteryLevel = nil
            isCharging = false
            return
        }
        batteryLevel = battery.batteryLevel
        isCharging = battery.batteryState == .charging || battery.batteryState == .full

        if batteryWarningLatch.shouldWarn(level: battery.batteryLevel,
                                          state: battery.batteryState) {
            onLowBattery?(battery.batteryLevel)
        }
    }
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
