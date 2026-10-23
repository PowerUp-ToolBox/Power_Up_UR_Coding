// S1 spike (#136): does the current macOS still let a process write the
// DualSense light bar, drive the adaptive triggers and play a haptic?
//
// THROWAWAY CODE. Not part of the app, not built by `swift build`.
// Build with ./build.sh in this directory; see s1-macos-light-bar.md.
//
// Every step prints an observation line prefixed with a step id (L1, T1, H1, ...)
// so the output can be pasted into the record verbatim. Lines starting with
// "LOOK:" / "FEEL:" / "PRESS:" ask the human to observe the pad; the API
// readback alone does not prove the hardware changed (GCDeviceLight.color may
// simply echo the cached value), so the human's observation is the verdict.
//
// Usage: s1-light-bar [--log <file>] [--no-appkit] [--wait <seconds>]

import AppKit
import CoreHaptics
import Foundation
import GameController

// MARK: - Output

var logHandle: FileHandle?
let started = Date()

func log(_ line: String) {
    let stamp = String(format: "%7.2f", Date().timeIntervalSince(started))
    let text = "[\(stamp)s] \(line)\n"
    FileHandle.standardOutput.write(Data(text.utf8))
    logHandle?.write(Data(text.utf8))
}

// MARK: - Arguments

var useAppKit = true
var waitSeconds: TimeInterval = 60
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--no-appkit":
        useAppKit = false
    case "--log":
        guard let path = arguments.first else { break }
        arguments.removeFirst()
        FileManager.default.createFile(atPath: path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: path)
    case "--wait":
        guard let value = arguments.first, let seconds = TimeInterval(value) else { break }
        arguments.removeFirst()
        waitSeconds = seconds
    default:
        log("ignoring unknown argument \(argument)")
    }
}

// MARK: - Step runner

/// Steps run one after another on the main queue, each after its own delay.
var steps: [(delay: TimeInterval, run: () -> Void)] = []

func step(after delay: TimeInterval, _ run: @escaping () -> Void) {
    steps.append((delay, run))
}

func runNextStep() {
    guard !steps.isEmpty else {
        finish(code: 0)
        return
    }
    let next = steps.removeFirst()
    DispatchQueue.main.asyncAfter(deadline: .now() + next.delay) {
        next.run()
        runNextStep()
    }
}

func finish(code: Int32) {
    log("DONE exit=\(code)")
    try? logHandle?.synchronize()
    exit(code)
}

// MARK: - Environment

func describeEnvironment() {
    let info = ProcessInfo.processInfo
    log("ENV os=\(info.operatingSystemVersionString)")
    log("ENV bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "(none: raw binary)")")
    log("ENV bundlePath=\(Bundle.main.bundlePath)")
    log("ENV executable=\(CommandLine.arguments.first ?? "?")")
    log("ENV runLoop=\(useAppKit ? "NSApplication (.accessory)" : "dispatchMain")")
    log("ENV shouldMonitorBackgroundEvents=\(GCController.shouldMonitorBackgroundEvents)")
}

// MARK: - Controller

var controller: GCController?
var hapticEngine: CHHapticEngine?
var pressed: [String: Bool] = [:]

func describe(_ pad: GCController) {
    log("C1 vendorName=\(pad.vendorName ?? "nil") productCategory=\(pad.productCategory)")
    log("C2 isDualSense=\(pad.extendedGamepad is GCDualSenseGamepad) attached=\(pad.isAttachedToDevice)")
    log("C3 light=\(pad.light == nil ? "nil" : "present") haptics=\(pad.haptics == nil ? "nil" : "present")")
    if let haptics = pad.haptics {
        log("C4 haptics.supportedLocalities=\(haptics.supportedLocalities.map(\.rawValue).sorted())")
    }
    if let battery = pad.battery {
        log("C5 battery.level=\(battery.batteryLevel) battery.state=\(battery.batteryState.rawValue) (0 unknown, 1 discharging, 2 charging, 3 full)")
    } else {
        log("C5 battery=nil")
    }
}

func colorText(_ color: GCColor?) -> String {
    guard let color else { return "nil" }
    return String(format: "(r %.3f, g %.3f, b %.3f)", color.red, color.green, color.blue)
}

func scheduleLightSteps() {
    let colors: [(name: String, r: Float, g: Float, b: Float)] = [
        ("RED", 1, 0, 0),
        ("GREEN", 0, 1, 0),
        ("BLUE", 0, 0, 1),
        ("ORANGE (PowerUp thinking)", 1, 0.45, 0),
    ]
    for (index, color) in colors.enumerated() {
        let id = "L\(index + 1)"
        step(after: index == 0 ? 0.5 : 1.5) {
            guard let light = controller?.light else {
                log("\(id) light=nil, cannot set \(color.name)")
                return
            }
            log("\(id) before=\(colorText(light.color))")
            light.color = GCColor(red: color.r, green: color.g, blue: color.b)
            log("\(id) set \(color.name) readback+0.0s=\(colorText(controller?.light?.color))")
            log("LOOK: the light bar should now be \(color.name)")
        }
        step(after: 0.5) {
            log("\(id) readback+0.5s=\(colorText(controller?.light?.color))")
        }
        step(after: 1.5) {
            log("\(id) readback+2.0s=\(colorText(controller?.light?.color))")
        }
    }
}

func triggerText(_ trigger: GCDualSenseAdaptiveTrigger) -> String {
    // Raw values: mode 0 off, 1 feedback, 2 weapon, 3 vibration, 4 slopeFeedback.
    // status: -1 unknown, 0 feedbackNoLoad, 1 feedbackLoadApplied, 2 weaponReady,
    // 3 weaponFiring, 4 weaponFired, 5 vibrationNotVibrating, 6 vibrationIsVibrating, ...
    "mode=\(trigger.mode.rawValue) status=\(trigger.status.rawValue) arm=\(String(format: "%.3f", trigger.armPosition)) value=\(String(format: "%.3f", trigger.value))"
}

func scheduleTriggerSteps() {
    step(after: 1.0) {
        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else {
            log("T1 not a GCDualSenseGamepad, adaptive triggers unavailable")
            return
        }
        log("T1 R2 before \(triggerText(dualSense.rightTrigger))")
        dualSense.rightTrigger.setModeFeedbackWithStartPosition(0.2, resistiveStrength: 0.9)
        log("T1 R2 setModeFeedback(start 0.2, strength 0.9) readback+0.0s \(triggerText(dualSense.rightTrigger))")
        log("T2 L2 before \(triggerText(dualSense.leftTrigger))")
        dualSense.leftTrigger.setModeWeaponWithStartPosition(0.3, endPosition: 0.6, resistiveStrength: 0.9)
        log("T2 L2 setModeWeapon(start 0.3, end 0.6, strength 0.9) readback+0.0s \(triggerText(dualSense.leftTrigger))")
        log("PRESS: squeeze R2 slowly (resistance from about 20%) and L2 (a click between 30% and 60%) during the next 8 seconds")
    }
    step(after: 0.5) {
        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        log("T1 R2 readback+0.5s \(triggerText(dualSense.rightTrigger))")
        log("T2 L2 readback+0.5s \(triggerText(dualSense.leftTrigger))")
    }
    for second in [2.0, 4.0, 6.0, 8.0] {
        step(after: 2.0) {
            guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
            log("T3 +\(Int(second))s R2 \(triggerText(dualSense.rightTrigger)) | L2 \(triggerText(dualSense.leftTrigger))")
        }
    }
    step(after: 0.5) {
        guard let dualSense = controller?.extendedGamepad as? GCDualSenseGamepad else { return }
        dualSense.rightTrigger.setModeOff()
        dualSense.leftTrigger.setModeOff()
        log("T4 both triggers setModeOff readback R2 \(triggerText(dualSense.rightTrigger)) | L2 \(triggerText(dualSense.leftTrigger))")
    }
}

func playHaptic(id: String, duration: TimeInterval) {
    guard let pad = controller else { return }
    guard let haptics = pad.haptics else {
        log("\(id) controller.haptics=nil")
        return
    }
    if hapticEngine == nil {
        guard let engine = haptics.createEngine(withLocality: .default) else {
            log("\(id) createEngine(.default) returned nil")
            return
        }
        engine.stoppedHandler = { reason in
            DispatchQueue.main.async { log("H* engine stopped reason=\(reason.rawValue)") }
        }
        engine.resetHandler = {
            DispatchQueue.main.async { log("H* engine reset") }
        }
        do {
            try engine.start()
            log("\(id) engine started")
        } catch {
            log("\(id) engine.start failed: \(error)")
            return
        }
        hapticEngine = engine
    }
    guard let engine = hapticEngine else { return }
    let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
    let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
    let type: CHHapticEvent.EventType = duration > 0.1 ? .hapticContinuous : .hapticTransient
    let event = CHHapticEvent(eventType: type, parameters: [intensity, sharpness],
                              relativeTime: 0, duration: duration)
    do {
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: CHHapticTimeImmediate)
        log("\(id) played \(type == .hapticTransient ? "transient" : "continuous \(duration)s") without error")
        log("FEEL: the pad should have \(type == .hapticTransient ? "tapped once" : "buzzed briefly")")
    } catch {
        log("\(id) play failed: \(error)")
    }
}

func scheduleHapticSteps() {
    step(after: 1.0) { playHaptic(id: "H1", duration: 0) }
    step(after: 2.0) { playHaptic(id: "H2", duration: 0.4) }
    step(after: 2.0) {
        hapticEngine?.stop(completionHandler: nil)
        hapticEngine = nil
        log("H3 engine stopped by the spike")
    }
}

func scheduleInputWindow() {
    step(after: 0.5) {
        log("PRESS: press a few face buttons, the touchpad and the PS button during the next 10 seconds")
        controller?.extendedGamepad?.valueChangedHandler = { _, element in
            guard let button = element as? GCControllerButtonInput else { return }
            let name = button.localizedName ?? button.sfSymbolsName ?? "?"
            let isPressed = button.isPressed
            if pressed[name] != isPressed {
                pressed[name] = isPressed
                log("I1 \(name) \(isPressed ? "down" : "up")")
            }
        }
    }
    step(after: 10.0) {
        controller?.extendedGamepad?.valueChangedHandler = nil
        log("I2 input window closed; distinct elements seen=\(pressed.count)")
    }
}

func scheduleReset() {
    step(after: 0.5) {
        controller?.light?.color = GCColor(red: 0, green: 0, blue: 1)
        log("R1 light reset to blue")
    }
}

// MARK: - Startup

func begin(with pad: GCController) {
    guard controller == nil else { return }
    controller = pad
    GCController.stopWirelessControllerDiscovery()
    log("C0 connected after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    describe(pad)
    scheduleLightSteps()
    scheduleTriggerSteps()
    scheduleHapticSteps()
    scheduleInputWindow()
    scheduleReset()
    runNextStep()
}

func start() {
    describeEnvironment()
    GCController.shouldMonitorBackgroundEvents = true
    log("ENV shouldMonitorBackgroundEvents(after set)=\(GCController.shouldMonitorBackgroundEvents)")

    NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
        guard let pad = note.object as? GCController else { return }
        log("N1 GCControllerDidConnect \(pad.vendorName ?? "nil")")
        begin(with: pad)
    }
    NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
        let pad = note.object as? GCController
        log("N2 GCControllerDidDisconnect \(pad?.vendorName ?? "nil")")
    }

    if let pad = GCController.controllers().first {
        log("N0 already connected: \(pad.vendorName ?? "nil")")
        begin(with: pad)
    } else {
        log("WAIT: connect the DualSense (USB or Bluetooth) within \(Int(waitSeconds)) seconds")
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + waitSeconds) {
            if controller == nil {
                log("C0 no controller connected after \(Int(waitSeconds))s")
                finish(code: 2)
            }
        }
    }
}

if useAppKit {
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) { start() }
    }
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    DispatchQueue.main.async { start() }
    dispatchMain()
}
