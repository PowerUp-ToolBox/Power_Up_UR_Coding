import Foundation
import CoreAudio

/// One audio device as the pickers and the routing code see it. `id` is the
/// transient CoreAudio object id (valid until unplug); `uid` is the stable
/// identity that gets persisted in config and survives reconnects.
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }
}

/// Enumerates the Mac's audio devices and tracks hot-plug changes, so STT can
/// record from a chosen microphone and TTS can speak through a chosen output.
/// Devices are remembered by UID; resolution back to a live `AudioDeviceID`
/// happens at use time, which is what makes unplug-fallback and auto-restore
/// automatic — a missing UID simply resolves to nil and callers use the
/// system default.
@MainActor
final class AudioDeviceStore: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []

    /// Fired after the device lists change (hot-plug), lists already updated.
    var onDevicesChanged: (() -> Void)?

    private var didStart = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()

        // The hardware property listener fires on its dispatch queue; hop to
        // the main actor before touching published state.
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.onDevicesChanged?()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    /// Live id for a remembered input UID; nil when unset or not connected.
    func inputDeviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid else { return nil }
        return inputDevices.first { $0.uid == uid }?.id
    }

    /// Live id for a remembered output UID; nil when unset or not connected.
    func outputDeviceID(forUID uid: String?) -> AudioDeviceID? {
        guard let uid else { return nil }
        return outputDevices.first { $0.uid == uid }?.id
    }

    func inputDevice(forUID uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return inputDevices.first { $0.uid == uid }
    }

    func outputDevice(forUID uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return outputDevices.first { $0.uid == uid }
    }

    // MARK: - Enumeration

    private func refresh() {
        let devices = Self.allDevices()
        inputDevices = devices.filter(\.hasInput)
        outputDevices = devices.filter(\.hasOutput)
    }

    /// The system's current default input device id (what the engine uses
    /// when no override is set). Used to restore the default after a routed
    /// session, so an override never sticks past its welcome.
    nonisolated static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private nonisolated static func allDevices() -> [AudioDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard let uid = stringProperty(of: id, kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty else { return nil }
            let name = stringProperty(of: id, kAudioObjectPropertyName) ?? uid
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                inputChannels: channelCount(of: id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(of: id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    private nonisolated static func stringProperty(
        of deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private nonisolated static func channelCount(
        of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, listPointer) == noErr
        else { return 0 }

        let list = listPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}

/// Pure availability tracker behind the "your chosen device came / went"
/// transcript announcements. Kept free of CoreAudio so it's testable: feed it
/// the configured UID and whether that UID is currently present, get back the
/// transition to announce (if any). Changing the configured UID rebaselines
/// silently — picking a device is not an event worth announcing.
struct AudioAvailabilityTracker {
    enum Transition: Equatable {
        case becameUnavailable
        case becameAvailable
    }

    private var lastUID: String?
    private var lastAvailable = true

    mutating func check(configuredUID: String?, isAvailable: Bool) -> Transition? {
        defer {
            lastUID = configuredUID
            lastAvailable = isAvailable
        }
        // Nothing configured → system default is always "available"; a change
        // of selection rebaselines without announcing.
        guard let configuredUID, configuredUID == lastUID else { return nil }
        if lastAvailable && !isAvailable { return .becameUnavailable }
        if !lastAvailable && isAvailable { return .becameAvailable }
        return nil
    }
}
