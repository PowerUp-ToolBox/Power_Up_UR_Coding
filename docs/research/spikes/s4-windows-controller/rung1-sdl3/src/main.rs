//! S4 rung 1 (#134): the `sdl3` crate's safe API.
//! THROWAWAY spike code. Reads every DualSense button and trigger, then sets the
//! light bar, rumbles and reads the battery. Prints one observation per line.
//!
//!   cargo run --release -p rung1-sdl3 -- [--input-seconds 120]

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use sdl3::event::Event;
use sdl3::gamepad::{Axis, Button, Gamepad};
use sdl3::joystick::ConnectionState;

const BUTTONS: [Button; 17] = [
    Button::South, Button::East, Button::West, Button::North,
    Button::Back, Button::Guide, Button::Start,
    Button::LeftStick, Button::RightStick, Button::LeftShoulder, Button::RightShoulder,
    Button::DPadUp, Button::DPadDown, Button::DPadLeft, Button::DPadRight,
    Button::Misc1, Button::Touchpad,
];
const AXES: [Axis; 6] = [
    Axis::LeftX, Axis::LeftY, Axis::RightX, Axis::RightY, Axis::TriggerLeft, Axis::TriggerRight,
];

fn log(start: Instant, line: impl AsRef<str>) {
    println!("[{:7.2}s] {}", start.elapsed().as_secs_f64(), line.as_ref());
}

fn arg_u64(name: &str, default: u64) -> u64 {
    let args: Vec<String> = std::env::args().collect();
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn connection(state: Result<ConnectionState, sdl3::Error>) -> String {
    match state {
        Ok(ConnectionState::Wired) => "wired".into(),
        Ok(ConnectionState::Wireless) => "wireless".into(),
        Ok(ConnectionState::Unknown) => "unknown".into(),
        Ok(ConnectionState::Invalid) => "invalid".into(),
        Err(e) => format!("error: {e}"),
    }
}

fn main() -> Result<(), String> {
    let start = Instant::now();
    let input_seconds = arg_u64("--input-seconds", 120);

    // Must be set BEFORE SDL initializes the joystick subsystem.
    let accepted = sdl3::hint::set("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
    log(start, format!("ENV rung=1 crate=sdl3 0.20.0 hint SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1 accepted={accepted}"));

    let sdl = sdl3::init().map_err(|e| e.to_string())?;
    let gamepads = sdl.gamepad().map_err(|e| e.to_string())?;
    let mut pump = sdl.event_pump().map_err(|e| e.to_string())?;

    log(start, "WAIT: connect the DualSense (USB first, then Bluetooth on a second run) within 60 s");
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut pad: Option<Gamepad> = None;
    while pad.is_none() && Instant::now() < deadline {
        for id in gamepads.gamepads().map_err(|e| e.to_string())? {
            if let Ok(opened) = gamepads.open(id) {
                pad = Some(opened);
                break;
            }
        }
        if pad.is_none() {
            let _ = pump.wait_event_timeout(Duration::from_millis(500));
        }
    }
    let Some(mut pad) = pad else {
        log(start, "C0 no gamepad within 60 s");
        std::process::exit(2);
    };

    log(start, format!("C1 name={:?} vendor={:04x?} product={:04x?} firmware={:?}",
        pad.name(), pad.vendor_id(), pad.product_id(), pad.firmware_version()));
    log(start, format!("C2 connection={} path={:?} serial={:?}",
        connection(pad.connection_state()), pad.path(), pad.serial_number()));
    // SAFETY: plain property reads on a gamepad we hold open.
    let (has_led, has_rumble) = unsafe { (pad.has_led(), pad.has_rumble()) };
    log(start, format!("C3 has_led={has_led} has_rumble={has_rumble} touchpads={}", pad.touchpads_count()));

    // Input checklist.
    let mut missing: BTreeSet<String> = BUTTONS.iter().map(|b| format!("{b:?}")).collect();
    missing.extend(AXES.iter().map(|a| format!("{a:?}")));
    let total = missing.len();
    log(start, format!("PRESS: every button once (incl. PS, Create, Options, touchpad click, mic mute, L3, R3), \
        both triggers fully, both sticks in all directions; {input_seconds} s"));
    let input_deadline = Instant::now() + Duration::from_secs(input_seconds);
    let mut last_report = Instant::now();
    while !missing.is_empty() && Instant::now() < input_deadline {
        if let Some(event) = pump.wait_event_timeout(Duration::from_millis(100)) {
            match event {
                Event::GamepadButtonDown { button, .. } => {
                    let name = format!("{button:?}");
                    if missing.remove(&name) {
                        log(start, format!("I1 button {name} ok ({}/{total})", total - missing.len()));
                    }
                }
                Event::GamepadAxisMotion { axis, value, .. } => {
                    let name = format!("{axis:?}");
                    if (value as i32).abs() > 24000 && missing.remove(&name) {
                        log(start, format!("I1 axis {name} ok value={value} ({}/{total})", total - missing.len()));
                    }
                }
                Event::GamepadRemoved { .. } => log(start, "I9 gamepad removed"),
                _ => {}
            }
        }
        if last_report.elapsed() > Duration::from_secs(10) {
            last_report = Instant::now();
            log(start, format!("I2 still missing: {missing:?}"));
        }
    }
    log(start, format!("I3 input checklist: {} of {total} seen; missing {missing:?}", total - missing.len()));

    // Background events.
    log(start, "BACKGROUND: within 5 s click into ANOTHER app (e.g. Notepad) so this console loses focus, \
        then press Cross (South) 3 times; 20 s window");
    let bg_deadline = Instant::now() + Duration::from_secs(20);
    let mut presses = 0;
    while Instant::now() < bg_deadline {
        if let Some(Event::GamepadButtonDown { button: Button::South, .. }) =
            pump.wait_event_timeout(Duration::from_millis(100))
        {
            presses += 1;
            log(start, format!("B1 South press #{presses} received"));
        }
    }
    log(start, format!("B2 background window: {presses} South presses received"));

    // Light bar.
    for (name, r, g, b) in [("RED", 255u8, 0u8, 0u8), ("GREEN", 0, 255, 0), ("BLUE", 0, 0, 255), ("ORANGE", 255, 115, 0)] {
        let result = pad.set_led(r, g, b).map_err(|e| e.to_string());
        log(start, format!("L1 set_led {name} -> {result:?}"));
        log(start, format!("LOOK: the light bar should be {name}"));
        pump_for(&mut pump, Duration::from_secs(2));
    }

    // Rumble.
    let low = pad.set_rumble(0xFFFF, 0, 800).map_err(|e| e.to_string());
    log(start, format!("R1 set_rumble low-frequency 800 ms -> {low:?}  FEEL: left grip"));
    pump_for(&mut pump, Duration::from_millis(1500));
    let high = pad.set_rumble(0, 0xFFFF, 800).map_err(|e| e.to_string());
    log(start, format!("R2 set_rumble high-frequency 800 ms -> {high:?}  FEEL: right grip"));
    pump_for(&mut pump, Duration::from_millis(1500));

    // Battery.
    log(start, format!("P1 power_info={:?}", pad.power_info()));
    let _ = pad.set_led(0, 64, 255);
    log(start, "DONE");
    Ok(())
}

fn pump_for(pump: &mut sdl3::EventPump, duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        let _ = pump.wait_event_timeout(Duration::from_millis(50));
    }
}
