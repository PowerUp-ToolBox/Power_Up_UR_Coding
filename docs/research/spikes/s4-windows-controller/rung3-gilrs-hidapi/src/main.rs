//! S4 rung 3 (#134): gilrs for input plus hidapi raw DualSense reports for the
//! light bar, rumble and battery (and a raw-report input check as a fallback).
//! THROWAWAY spike code. The report layout below was written from the publicly
//! documented DualSense HID format (offsets only); no GPL driver code is copied.
//!
//!   cargo run --release -p rung3-gilrs-hidapi -- [--input-seconds 120] [--skip-gilrs]

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use gilrs::{Axis, Button, EventType, Gilrs};
use hidapi::{BusType, HidApi, HidDevice};

const SONY: u16 = 0x054C;
const DUALSENSE: [u16; 2] = [0x0CE6, 0x0DF2]; // DualSense, DualSense Edge

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

fn has_flag(name: &str) -> bool {
    std::env::args().any(|a| a == name)
}

// ---------------------------------------------------------------- gilrs input

fn gilrs_phase(start: Instant, input_seconds: u64) {
    let mut gilrs = match Gilrs::new() {
        Ok(g) => g,
        Err(e) => {
            log(start, format!("G0 Gilrs::new failed: {e}"));
            return;
        }
    };
    for (id, pad) in gilrs.gamepads() {
        log(start, format!("G1 gamepad {id}: name={:?} os_name={:?} map={:?} vendor={:04x?} product={:04x?} power={:?} ff={}",
            pad.name(), pad.os_name(), pad.map_name(), pad.vendor_id(), pad.product_id(), pad.power_info(), pad.is_ff_supported()));
    }
    let buttons = [
        Button::South, Button::East, Button::West, Button::North,
        Button::Select, Button::Start, Button::Mode,
        Button::LeftThumb, Button::RightThumb, Button::LeftTrigger, Button::RightTrigger,
        Button::LeftTrigger2, Button::RightTrigger2,
        Button::DPadUp, Button::DPadDown, Button::DPadLeft, Button::DPadRight,
    ];
    let axes = [Axis::LeftStickX, Axis::LeftStickY, Axis::RightStickX, Axis::RightStickY];
    let mut missing: BTreeSet<String> = buttons.iter().map(|b| format!("{b:?}")).collect();
    missing.extend(axes.iter().map(|a| format!("{a:?}")));
    let total = missing.len();
    let mut unknown: BTreeSet<String> = BTreeSet::new();
    log(start, format!("PRESS (gilrs): every button once (incl. PS, Create, Options, touchpad click, mic mute, L3, R3), \
        both triggers fully, both sticks; {input_seconds} s. Touchpad and mic mute have no gilrs name; they show up as Unknown codes"));
    let deadline = Instant::now() + Duration::from_secs(input_seconds);
    let mut last_report = Instant::now();
    while Instant::now() < deadline && !missing.is_empty() {
        while let Some(ev) = gilrs.next_event_blocking(Some(Duration::from_millis(100))) {
            match ev.event {
                EventType::ButtonPressed(Button::Unknown, code) => {
                    if unknown.insert(format!("{code}")) {
                        log(start, format!("G2 unknown button code {code}"));
                    }
                }
                EventType::ButtonPressed(button, _) => {
                    if missing.remove(&format!("{button:?}")) {
                        log(start, format!("G2 button {button:?} ok ({}/{total})", total - missing.len()));
                    }
                }
                EventType::ButtonChanged(button, value, _) if value > 0.9 => {
                    if missing.remove(&format!("{button:?}")) {
                        log(start, format!("G2 analog {button:?} ok value={value:.2} ({}/{total})", total - missing.len()));
                    }
                }
                EventType::AxisChanged(axis, value, _) if value.abs() > 0.75 => {
                    if missing.remove(&format!("{axis:?}")) {
                        log(start, format!("G2 axis {axis:?} ok value={value:.2} ({}/{total})", total - missing.len()));
                    }
                }
                EventType::Connected => log(start, format!("G9 connected {}", ev.id)),
                EventType::Disconnected => log(start, format!("G9 disconnected {}", ev.id)),
                _ => {}
            }
            if missing.is_empty() {
                break;
            }
        }
        if last_report.elapsed() > Duration::from_secs(10) {
            last_report = Instant::now();
            log(start, format!("G3 still missing: {missing:?}"));
        }
    }
    log(start, format!("G4 gilrs checklist: {} of {total} seen; missing {missing:?}; unknown codes {unknown:?}", total - missing.len()));

    log(start, "BACKGROUND (gilrs): within 5 s click into ANOTHER app so this console loses focus, then press Cross 3 times; 20 s");
    let bg_deadline = Instant::now() + Duration::from_secs(20);
    let mut presses = 0;
    while Instant::now() < bg_deadline {
        if let Some(ev) = gilrs.next_event_blocking(Some(Duration::from_millis(100))) {
            if let EventType::ButtonPressed(Button::South, _) = ev.event {
                presses += 1;
                log(start, format!("B1 South press #{presses} received"));
            }
        }
    }
    log(start, format!("B2 background window (gilrs): {presses} South presses received"));
}

// ---------------------------------------------------------------- hidapi raw

/// CRC-32 (IEEE, reflected, poly 0xEDB88320), as used by DualSense Bluetooth reports.
fn crc32(chunks: &[&[u8]]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for chunk in chunks {
        for &byte in *chunk {
            crc ^= byte as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
            }
        }
    }
    !crc
}

struct Pad {
    dev: HidDevice,
    bluetooth: bool,
    seq: u8,
}

/// Fields of the 47-byte "common" block shared by the USB (0x02) and Bluetooth (0x31)
/// output reports. Offsets within that block:
///   0 valid_flag0 (bit0 compatible vibration, bit1 haptics select)
///   1 valid_flag1 (bit2 light bar control enable)
///   2 motor_right (high frequency)   3 motor_left (low frequency)
///   38 valid_flag2 (bit1 light bar setup control enable, bit2 compatible vibration v2)
///   41 lightbar_setup (2 = fade out the firmware's startup light)
///   44 red   45 green   46 blue
#[derive(Default, Clone, Copy)]
struct Output {
    rumble: Option<(u8, u8)>,
    vibration_v2: bool,
    light: Option<(u8, u8, u8)>,
    release_startup_light: bool,
}

impl Pad {
    fn write(&mut self, out: Output) -> Result<usize, String> {
        let mut common = [0u8; 47];
        if let Some((right, left)) = out.rumble {
            if out.vibration_v2 {
                common[38] |= 0x04;
            } else {
                common[0] |= 0x01;
            }
            common[0] |= 0x02;
            common[2] = right;
            common[3] = left;
        }
        if let Some((r, g, b)) = out.light {
            common[1] |= 0x04;
            common[44] = r;
            common[45] = g;
            common[46] = b;
        }
        if out.release_startup_light {
            common[38] |= 0x02;
            common[41] = 0x02;
        }
        if self.bluetooth {
            let mut report = [0u8; 78];
            report[0] = 0x31;
            report[1] = (self.seq & 0x0F) << 4;
            self.seq = self.seq.wrapping_add(1);
            report[2] = 0x10;
            report[3..50].copy_from_slice(&common);
            let crc = crc32(&[&[0xA2], &report[..74]]);
            report[74..78].copy_from_slice(&crc.to_le_bytes());
            self.dev.write(&report).map_err(|e| e.to_string())
        } else {
            let mut report = [0u8; 48];
            report[0] = 0x02;
            report[1..48].copy_from_slice(&common);
            self.dev.write(&report).map_err(|e| e.to_string())
        }
    }

    /// Reads one input report and returns the payload aligned to the USB layout
    /// (index 0 = report id 0x01, 1..=6 sticks/triggers, 8..=10 buttons, 53 status).
    fn read_input(&self, timeout_ms: i32) -> Option<Vec<u8>> {
        let mut buf = [0u8; 128];
        let n = self.dev.read_timeout(&mut buf, timeout_ms).ok()?;
        if n == 0 {
            return None;
        }
        match buf[0] {
            0x01 if n >= 64 => Some(buf[..n].to_vec()),
            // Bluetooth full report: one extra byte after the id.
            0x31 if n >= 55 => {
                let mut v = vec![0x01];
                v.extend_from_slice(&buf[2..n]);
                Some(v)
            }
            _ => Some(vec![buf[0]]), // simple Bluetooth report or other: id only
        }
    }
}

fn pressed_buttons(r: &[u8]) -> Vec<&'static str> {
    if r.len() < 11 {
        return vec![];
    }
    let mut out = vec![];
    let hat = r[8] & 0x0F;
    let dpad = ["DPadUp", "DPadUp+Right", "DPadRight", "DPadDown+Right", "DPadDown", "DPadDown+Left", "DPadLeft", "DPadUp+Left"];
    if (hat as usize) < dpad.len() {
        out.push(dpad[hat as usize]);
    }
    let bits: [(usize, u8, &str); 15] = [
        (8, 0x10, "Square"), (8, 0x20, "Cross"), (8, 0x40, "Circle"), (8, 0x80, "Triangle"),
        (9, 0x01, "L1"), (9, 0x02, "R1"), (9, 0x04, "L2"), (9, 0x08, "R2"),
        (9, 0x10, "Create"), (9, 0x20, "Options"), (9, 0x40, "L3"), (9, 0x80, "R3"),
        (10, 0x01, "PS"), (10, 0x02, "TouchpadClick"), (10, 0x04, "MicMute"),
    ];
    for (byte, mask, name) in bits {
        if r[byte] & mask != 0 {
            out.push(name);
        }
    }
    out
}

fn sleep_reading(pad: &Pad, duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        let _ = pad.read_input(20);
    }
}

fn hid_phase(start: Instant, input_seconds: u64) {
    let api = match HidApi::new() {
        Ok(api) => api,
        Err(e) => {
            log(start, format!("H0 HidApi::new failed: {e}"));
            return;
        }
    };
    let mut chosen = None;
    for info in api.device_list() {
        if info.vendor_id() == SONY && DUALSENSE.contains(&info.product_id()) {
            log(start, format!("H1 found pid={:04x} bus={:?} interface={} usage_page={:04x} product={:?} path={:?}",
                info.product_id(), info.bus_type(), info.interface_number(), info.usage_page(), info.product_string(), info.path()));
            if chosen.is_none() {
                chosen = Some((info.path().to_owned(), info.bus_type()));
            }
        }
    }
    let Some((path, bus)) = chosen else {
        log(start, "H1 no DualSense HID interface found (VID 054C, PID 0CE6/0DF2)");
        return;
    };
    let dev = match api.open_path(&path) {
        Ok(d) => d,
        Err(e) => {
            log(start, format!("H2 open failed: {e}"));
            return;
        }
    };
    let bluetooth = matches!(bus, BusType::Bluetooth);
    let mut pad = Pad { dev, bluetooth, seq: 0 };
    log(start, format!("H2 opened, transport={}", if bluetooth { "bluetooth" } else { "usb" }));

    if bluetooth {
        // Reading feature report 0x05 (calibration) switches the pad to full 0x31 reports.
        let mut feature = [0u8; 41];
        feature[0] = 0x05;
        log(start, format!("H3 get_feature_report(0x05) -> {:?}", pad.dev.get_feature_report(&mut feature).map_err(|e| e.to_string())));
    }

    let mut first = None;
    let until = Instant::now() + Duration::from_secs(2);
    while first.is_none() && Instant::now() < until {
        first = pad.read_input(100).filter(|r| r.len() > 53);
    }
    match &first {
        Some(r) => {
            let level = (r[53] & 0x0F).min(10) as u32 * 10;
            let status = match r[53] >> 4 { 0 => "discharging", 1 => "charging", 2 => "full", _ => "other" };
            log(start, format!("P1 battery ~{level}% status={status} (raw 0x{:02x})", r[53]));
        }
        None => log(start, "P1 no full input report within 2 s (battery unknown)"),
    }

    let release = Output { release_startup_light: true, ..Default::default() };
    log(start, format!("L0 release startup light -> {:?}", pad.write(release)));
    sleep_reading(&pad, Duration::from_millis(300));
    for (name, r, g, b) in [("RED", 255u8, 0u8, 0u8), ("GREEN", 0, 255, 0), ("BLUE", 0, 0, 255), ("ORANGE", 255, 115, 0)] {
        let result = pad.write(Output { light: Some((r, g, b)), ..Default::default() });
        log(start, format!("L1 raw light {name} -> {result:?}"));
        log(start, format!("LOOK: the light bar should be {name}"));
        sleep_reading(&pad, Duration::from_secs(2));
    }

    for (label, v2) in [("v1 (valid_flag0)", false), ("v2 (valid_flag2)", true)] {
        let on = pad.write(Output { rumble: Some((0, 255)), vibration_v2: v2, light: Some((255, 115, 0)), ..Default::default() });
        log(start, format!("R1 raw rumble left motor, {label} -> {on:?}  FEEL: left grip (note which variant works)"));
        sleep_reading(&pad, Duration::from_millis(700));
        let on = pad.write(Output { rumble: Some((255, 0)), vibration_v2: v2, light: Some((255, 115, 0)), ..Default::default() });
        log(start, format!("R2 raw rumble right motor, {label} -> {on:?}  FEEL: right grip"));
        sleep_reading(&pad, Duration::from_millis(700));
        let off = pad.write(Output { rumble: Some((0, 0)), vibration_v2: v2, light: Some((255, 115, 0)), ..Default::default() });
        log(start, format!("R3 rumble off -> {off:?}"));
        sleep_reading(&pad, Duration::from_millis(800));
    }

    // Raw input check: decodes buttons straight from the reports (fallback if gilrs misses some).
    let wanted = [
        "Square", "Cross", "Circle", "Triangle", "L1", "R1", "L2", "R2", "Create", "Options",
        "L3", "R3", "PS", "TouchpadClick", "MicMute", "DPadUp", "DPadDown", "DPadLeft", "DPadRight",
    ];
    let mut missing: BTreeSet<&str> = wanted.into_iter().collect();
    let total = missing.len();
    let mut triggers_full = (false, false);
    log(start, format!("PRESS (raw HID): every button again, and both triggers fully; {input_seconds} s"));
    let deadline = Instant::now() + Duration::from_secs(input_seconds);
    let mut last_report = Instant::now();
    while Instant::now() < deadline && !(missing.is_empty() && triggers_full.0 && triggers_full.1) {
        if let Some(r) = pad.read_input(100) {
            for name in pressed_buttons(&r) {
                if missing.remove(name) {
                    log(start, format!("H5 raw button {name} ok ({}/{total})", total - missing.len()));
                }
            }
            if r.len() > 6 {
                if r[5] > 240 && !triggers_full.0 {
                    triggers_full.0 = true;
                    log(start, format!("H5 raw L2 analog full ({})", r[5]));
                }
                if r[6] > 240 && !triggers_full.1 {
                    triggers_full.1 = true;
                    log(start, format!("H5 raw R2 analog full ({})", r[6]));
                }
            }
        }
        if last_report.elapsed() > Duration::from_secs(10) {
            last_report = Instant::now();
            log(start, format!("H6 still missing: {missing:?} triggers_full={triggers_full:?}"));
        }
    }
    log(start, format!("H7 raw checklist: {} of {total} buttons; missing {missing:?}; triggers_full={triggers_full:?}", total - missing.len()));
    let _ = pad.write(Output { light: Some((0, 64, 255)), ..Default::default() });
}

fn main() {
    let start = Instant::now();
    let input_seconds = arg_u64("--input-seconds", 120);
    log(start, "ENV rung=3 crates=gilrs 0.11.2 (default wgi backend) + hidapi 2.6.7");
    if !has_flag("--skip-gilrs") {
        gilrs_phase(start, input_seconds);
    }
    hid_phase(start, input_seconds);
    log(start, "DONE");
}
