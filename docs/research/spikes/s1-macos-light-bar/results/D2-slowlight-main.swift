import AppKit
import GameController

let colors: [(String, Float, Float, Float)] = [
    ("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1),
    ("white", 1, 1, 1), ("off", 0, 0, 0), ("green", 0, 1, 0.2)]
var started = false
func say(_ text: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = [text]; try? p.run()
}
func run(_ pad: GCController) {
    guard !started else { return }; started = true
    print("connected: \(pad.vendorName ?? "?") light=\(pad.light == nil ? "nil" : "present") before=\(String(describing: pad.light?.color.red)),\(String(describing: pad.light?.color.green)),\(String(describing: pad.light?.color.blue))")
    say("starting")
    for (i, c) in colors.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 6) {
            pad.light?.color = GCColor(red: c.1, green: c.2, blue: c.3)
            print("set \(c.0)"); say(c.0)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(colors.count) * 6) { say("done"); print("done"); exit(0) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
GCController.shouldMonitorBackgroundEvents = true
NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
    if let pad = n.object as? GCController { run(pad) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let pad = GCController.controllers().first { run(pad) } }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if !started { print("no controller"); exit(1) } }
app.run()
