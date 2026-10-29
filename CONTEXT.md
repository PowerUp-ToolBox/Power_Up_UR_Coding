# PowerUp

PowerUp turns physical input devices and a voice into a remote for AI coding
harnesses. This glossary is the one vocabulary shared by every implementation
(the Swift macOS app, the Rust daemon and device plugins, the wire protocol,
the docs). Implementation detail belongs in DESIGN.md and the ADRs, not here.

## Language

### Input

**Device**:
Any physical or virtual input source a person uses to drive PowerUp: a gamepad,
a foot pedal, a macropad, a headset, a phone, a protocol client. The host
computer's own keyboard and mouse are not a device: they always work and are
never selected or ignored.
_Avoid_: controller (as the umbrella), input, peripheral

**Controller**:
A device that provides controls a person presses: a gamepad, a foot pedal, a
macropad, a phone registered as a device. Also the name of the slot that
holds the one controller in use.
_Avoid_: gamepad (as the general term), pad, control device, input device

**Slot**:
One of the three roles a device can fill, each holding at most one device:
Controller (where presses come from), Input (the microphone), Output (the
speaker). A device in no slot is ignored.
_Avoid_: active device, selection, channel

**Input**:
The slot holding the microphone PowerUp listens to.
_Avoid_: mic device (when meaning the slot), voice source, recorder

**Output**:
The slot holding the speaker PowerUp speaks through.
_Avoid_: speaker device (when meaning the slot), playback, sink

**Audio device**:
A microphone or speaker. Always qualified with "audio" so it is never confused
with an input device.
_Avoid_: device (bare) when meaning a mic or speaker

**Profile**:
The description of a kind of controller as data: a stable id and the list of
controls it has. One profile covers every connected controller of that kind.
Only controllers have profiles.
_Avoid_: device definition, layout, schema, setup

**Plugin**:
A unit that adds a profile or an adapter to PowerUp. Official plugins ship
with the app; community plugins are designed to be installable later.
_Avoid_: extension, module, driver

**Control**:
One thing on a device a person can press, hold, move, or hit: a button, a
trigger, a stick axis, a key, a pedal. Identified by a stable string id within
its profile.
_Avoid_: button (as the general term), input, key (as the general term)

**Phase**:
Whether a control just began (pressed) or ended (released).
_Avoid_: state, event type, down/up

### Meaning

**Intent**:
A device-agnostic user request, such as begin voice capture, approve, cycle
model. The only vocabulary the app's dispatcher understands; every input
source ends up producing intents.
_Avoid_: command, event, action (when meaning an intent)

**Action**:
What a person assigns to a control in a mapping: push to talk, approve, cycle
model. An action becomes an intent when its control fires.
_Avoid_: controller action, command, binding

**Hold**:
An action that runs for as long as its control stays pressed and finishes on
release, such as push to talk. Whether an action is a hold is a property of
the action, not of the control.
_Avoid_: long press, press-and-hold, hold control

**Mapping**:
The per-profile table from control id to the action a person assigned it.
_Avoid_: binding, config (when meaning the table), keymap

**Built-in mode**:
The control mode in which PowerUp runs the harness itself. The same name on
every operating system.
_Avoid_: builtin, embedded, owned session

**Remote mode**:
The control mode in which PowerUp drives a harness session that already
exists elsewhere, by way of an injector. The same name on every operating
system.
_Avoid_: injection mode, external mode, attach mode

**Injector**:
The per-operating-system mechanism remote mode uses to deliver text to an
existing session: cmux, Accessibility typing, SendInput, X11 typing.
_Avoid_: target (when meaning the mechanism), backend, driver

**Core**:
The logic of PowerUp written once, as a library every OS app compiles in:
intents, mappings, slots, harness adapters, sessions, configuration, the
protocol server.
_Avoid_: backend, daemon, engine

**Platform adapter**:
The per-operating-system code the core cannot contain: device input, speech
recognition, text to speech, audio devices, the injector.
_Avoid_: driver, provider, native layer

**Effect**:
What the core asks a platform adapter to do: start the harness, append a
transcript entry, inject text. The core decides; the platform only carries
it out, in order.
_Avoid_: command, callback, side effect (when meaning one of these)

**Harness**:
The AI coding agent PowerUp drives: Claude Code built in, or any agent
reached over the Agent Client Protocol.
_Avoid_: backend, agent (bare, when meaning the harness), model
