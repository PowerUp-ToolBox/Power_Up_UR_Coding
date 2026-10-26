//! S4 rung 2 (#134): raw `sdl3-sys` bindings (the C API), for when the safe
//! `sdl3` crate is the problem rather than SDL itself.
//! THROWAWAY spike code. Same script as rung 1.
//!
//!   cargo run --release -p rung2-sdl3-sys -- [--input-seconds 120]

use std::collections::BTreeSet;
use std::ffi::{c_int, CStr};
use std::time::{Duration, Instant};

use sdl3_sys::error::SDL_GetError;
use sdl3_sys::events::{
    SDL_Event, SDL_WaitEventTimeout, SDL_EVENT_GAMEPAD_AXIS_MOTION, SDL_EVENT_GAMEPAD_BUTTON_DOWN,
    SDL_EVENT_GAMEPAD_REMOVED,
};
use sdl3_sys::gamepad::*;
use sdl3_sys::hints::SDL_SetHint;
use sdl3_sys::init::{SDL_Init, SDL_Quit, SDL_INIT_GAMEPAD};
use sdl3_sys::joystick::SDL_JoystickConnectionState;
use sdl3_sys::stdinc::SDL_free;

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

fn cstr(ptr: *const std::ffi::c_char) -> String {
    if ptr.is_null() {
        return "(null)".into();
    }
    // SAFETY: SDL returns NUL-terminated strings that stay valid until the next call.
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

fn sdl_error() -> String {
    // SDL_GetError is declared safe in sdl3-sys; it returns a valid (possibly empty) string.
    cstr(SDL_GetError())
}

fn button_name(button: u8) -> String {
    // SAFETY: SDL_GetGamepadStringForButton returns a static string or NULL.
    cstr(unsafe { SDL_GetGamepadStringForButton(SDL_GamepadButton(button as c_int)) })
}

fn axis_name(axis: u8) -> String {
    // SAFETY: as above.
    cstr(unsafe { SDL_GetGamepadStringForAxis(SDL_GamepadAxis(axis as c_int)) })
}

fn wait(timeout_ms: i32) -> Option<SDL_Event> {
    let mut event = SDL_Event::default();
    // SAFETY: `event` is a valid, writable SDL_Event.
    if unsafe { SDL_WaitEventTimeout(&mut event, timeout_ms) } { Some(event) } else { None }
}

fn pump_for(duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        let _ = wait(50);
    }
}

fn main() {
    let start = Instant::now();
    let input_seconds = arg_u64("--input-seconds", 120);

    // SAFETY: plain C calls with NUL-terminated literals; all made from this thread.
    unsafe {
        let accepted = SDL_SetHint(c"SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS".as_ptr(), c"1".as_ptr());
        log(start, format!("ENV rung=2 crate=sdl3-sys 0.7.2 hint SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1 accepted={accepted}"));
        if !SDL_Init(SDL_INIT_GAMEPAD) {
            log(start, format!("C0 SDL_Init failed: {}", sdl_error()));
            std::process::exit(1);
        }
    }

    log(start, "WAIT: connect the DualSense (USB first, then Bluetooth on a second run) within 60 s");
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut pad: *mut SDL_Gamepad = std::ptr::null_mut();
    while pad.is_null() && Instant::now() < deadline {
        let mut count: c_int = 0;
        // SAFETY: SDL allocates the array; we free it with SDL_free.
        unsafe {
            let ids = SDL_GetGamepads(&mut count);
            if !ids.is_null() {
                if count > 0 {
                    pad = SDL_OpenGamepad(*ids);
                }
                SDL_free(ids.cast());
            }
        }
        if pad.is_null() {
            let _ = wait(500);
        }
    }
    if pad.is_null() {
        log(start, format!("C0 no gamepad within 60 s ({})", sdl_error()));
        std::process::exit(2);
    }

    // SAFETY: `pad` is a valid open gamepad for the rest of main.
    unsafe {
        let conn = match SDL_GetGamepadConnectionState(pad) {
            SDL_JoystickConnectionState::WIRED => "wired",
            SDL_JoystickConnectionState::WIRELESS => "wireless",
            _ => "unknown/invalid",
        };
        log(start, format!("C1 name={} vendor={:04x} product={:04x} connection={conn}",
            cstr(SDL_GetGamepadName(pad)), SDL_GetGamepadVendor(pad), SDL_GetGamepadProduct(pad)));
    }

    // Input checklist (DualSense: 17 buttons incl. Misc1 = mic mute and touchpad; 6 axes).
    let wanted_buttons: [SDL_GamepadButton; 17] = [
        SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
        SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_GUIDE, SDL_GAMEPAD_BUTTON_START,
        SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK,
        SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
        SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN, SDL_GAMEPAD_BUTTON_DPAD_LEFT,
        SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_MISC1, SDL_GAMEPAD_BUTTON_TOUCHPAD,
    ];
    let wanted_axes: [SDL_GamepadAxis; 6] = [
        SDL_GAMEPAD_AXIS_LEFTX, SDL_GAMEPAD_AXIS_LEFTY, SDL_GAMEPAD_AXIS_RIGHTX, SDL_GAMEPAD_AXIS_RIGHTY,
        SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
    ];
    let mut missing: BTreeSet<String> = wanted_buttons.iter().map(|b| button_name(b.0 as u8)).collect();
    missing.extend(wanted_axes.iter().map(|a| axis_name(a.0 as u8)));
    let total = missing.len();
    log(start, format!("PRESS: every button once (incl. PS, Create, Options, touchpad click, mic mute, L3, R3), \
        both triggers fully, both sticks in all directions; {input_seconds} s"));
    let input_deadline = Instant::now() + Duration::from_secs(input_seconds);
    let mut last_report = Instant::now();
    while !missing.is_empty() && Instant::now() < input_deadline {
        if let Some(event) = wait(100) {
            // SAFETY: the `type` field is valid for every event; the variant read matches it.
            unsafe {
                if event.r#type == SDL_EVENT_GAMEPAD_BUTTON_DOWN.0 {
                    let name = button_name(event.gbutton.button);
                    if missing.remove(&name) {
                        log(start, format!("I1 button {name} ok ({}/{total})", total - missing.len()));
                    }
                } else if event.r#type == SDL_EVENT_GAMEPAD_AXIS_MOTION.0 {
                    let name = axis_name(event.gaxis.axis);
                    if (event.gaxis.value as i32).abs() > 24000 && missing.remove(&name) {
                        log(start, format!("I1 axis {name} ok value={} ({}/{total})", event.gaxis.value, total - missing.len()));
                    }
                } else if event.r#type == SDL_EVENT_GAMEPAD_REMOVED.0 {
                    log(start, "I9 gamepad removed");
                }
            }
        }
        if last_report.elapsed() > Duration::from_secs(10) {
            last_report = Instant::now();
            log(start, format!("I2 still missing: {missing:?}"));
        }
    }
    log(start, format!("I3 input checklist: {} of {total} seen; missing {missing:?}", total - missing.len()));

    log(start, "BACKGROUND: within 5 s click into ANOTHER app (e.g. Notepad) so this console loses focus, \
        then press Cross (South) 3 times; 20 s window");
    let bg_deadline = Instant::now() + Duration::from_secs(20);
    let mut presses = 0;
    while Instant::now() < bg_deadline {
        if let Some(event) = wait(100) {
            // SAFETY: as above.
            unsafe {
                if event.r#type == SDL_EVENT_GAMEPAD_BUTTON_DOWN.0
                    && event.gbutton.button as c_int == SDL_GAMEPAD_BUTTON_SOUTH.0
                {
                    presses += 1;
                    log(start, format!("B1 South press #{presses} received"));
                }
            }
        }
    }
    log(start, format!("B2 background window: {presses} South presses received"));

    // SAFETY: `pad` is still open.
    unsafe {
        for (name, r, g, b) in [("RED", 255u8, 0u8, 0u8), ("GREEN", 0, 255, 0), ("BLUE", 0, 0, 255), ("ORANGE", 255, 115, 0)] {
            let ok = SDL_SetGamepadLED(pad, r, g, b);
            log(start, format!("L1 SDL_SetGamepadLED {name} -> {ok} {}", if ok { String::new() } else { sdl_error() }));
            log(start, format!("LOOK: the light bar should be {name}"));
            pump_for(Duration::from_secs(2));
        }
        let ok = SDL_RumbleGamepad(pad, 0xFFFF, 0, 800);
        log(start, format!("R1 SDL_RumbleGamepad low 800 ms -> {ok}  FEEL: left grip"));
        pump_for(Duration::from_millis(1500));
        let ok = SDL_RumbleGamepad(pad, 0, 0xFFFF, 800);
        log(start, format!("R2 SDL_RumbleGamepad high 800 ms -> {ok}  FEEL: right grip"));
        pump_for(Duration::from_millis(1500));
        let mut percent: c_int = -1;
        let state = SDL_GetGamepadPowerInfo(pad, &mut percent);
        log(start, format!("P1 power state={} percent={percent} (state: -1 error, 0 unknown, 1 on battery, 2 no battery, 3 charging, 4 charged)", state.0));
        let _ = SDL_SetGamepadLED(pad, 0, 64, 255);
        SDL_CloseGamepad(pad);
        SDL_Quit();
    }
    log(start, "DONE");
}
