import Foundation
import PowerUpCore

/// The configuration schema (slice 2.5, DESIGN v2.14): the core owns the
/// defaults, how config.json's bytes read and the bytes it is saved as;
/// ConfigStore keeps the file, its path, the atomic write and the backups.
/// The app's `AppConfig` stays a plain struct with its own names, converted
/// field for field to and from the generated `CoreAppConfig`.
extension CoreBridge {
    /// What reading config.json's bytes decided.
    enum ConfigLoad: Equatable {
        /// The config to run with; `backupBeforeSave` asks for the one-time
        /// copy to config.pre-profiles.json before the next save.
        case loaded(AppConfig, backupBeforeSave: Bool)
        /// Not a config the app can read: move it aside, run on defaults.
        case corrupt
    }

    /// The values each fixed-vocabulary setting may take, in the order
    /// Settings offers them.
    struct ConfigVocabulary: Equatable {
        let harnessKinds: [String]
        let acpAgents: [String]
        let controlModes: [String]
        let remoteTargetKinds: [String]
    }

    /// Every setting at its default; nil when the core fails.
    static func defaultConfig() -> AppConfig? {
        call("defaultConfig", fallback: nil) {
            AppConfig(try PowerUpCore.defaultConfig())
        }
    }

    /// Reads config.json's bytes; nil when the core fails, which the caller
    /// must never mistake for a corrupt file.
    static func loadConfig(_ data: Data) -> ConfigLoad? {
        call("loadConfig", fallback: nil) {
            switch try PowerUpCore.loadConfig(bytes: data) {
            case .loaded(let config, let backupBeforeSave):
                return .loaded(AppConfig(config), backupBeforeSave: backupBeforeSave)
            case .corrupt:
                return .corrupt
            }
        }
    }

    /// The bytes config.json is saved as; nil when the core fails.
    static func encodeConfig(_ config: AppConfig) -> Data? {
        call("encodeConfig", fallback: nil) {
            try PowerUpCore.encodeConfig(config: config.core)
        }
    }

    /// The pre-multi-project migration; nil when the core fails.
    static func seedProjectBookkeeping(_ config: AppConfig) -> AppConfig? {
        call("seedProjectBookkeeping", fallback: nil) {
            AppConfig(try PowerUpCore.seedProjectBookkeeping(config: config.core))
        }
    }

    /// The fixed vocabularies; nil when the core fails.
    static func configVocabulary() -> ConfigVocabulary? {
        call("configVocabulary", fallback: nil) {
            let vocabulary = try PowerUpCore.configVocabulary()
            return ConfigVocabulary(harnessKinds: vocabulary.harnessKinds,
                                    acpAgents: vocabulary.acpAgents,
                                    controlModes: vocabulary.controlModes,
                                    remoteTargetKinds: vocabulary.remoteTargetKinds)
        }
    }
}

// MARK: - Conversions
//
// Every field by name, both ways, so a field added on one side and not the
// other is a compile error in the memberwise initializer.

fileprivate extension AppConfig {
    init(_ core: CoreAppConfig) {
        self.init(
            projectDir: core.projectDir,
            model: core.model,
            permissionMode: core.permissionMode,
            claudePath: core.claudePath,
            lastSessionID: core.lastSessionId,
            ttsEnabled: core.ttsEnabled,
            ttsRate: core.ttsRate,
            ttsVoiceID: core.ttsVoiceId,
            maxSpokenChars: Int(clamping: core.maxSpokenChars),
            speakSummaries: core.speakSummaries,
            summaryModel: core.summaryModel,
            localeID: core.localeId,
            onDeviceRecognition: core.onDeviceRecognition,
            audioInputUID: core.audioInputUid,
            audioOutputUID: core.audioOutputUid,
            controllerDeviceID: core.controllerDeviceId,
            hapticsEnabled: core.hapticsEnabled,
            lightEnabled: core.lightEnabled,
            effort: core.effort,
            modelCycle: core.modelCycle,
            harnessKind: core.harnessKind,
            acpAgent: core.acpAgent,
            acpCustomCommand: core.acpCustomCommand,
            controlMode: core.controlMode,
            remoteTargetKind: core.remoteTargetKind,
            remoteCmuxWorkspace: core.remoteCmuxWorkspace,
            remoteCmuxSurface: core.remoteCmuxSurface,
            remoteAppBundleID: core.remoteAppBundleId,
            remoteCmuxPassword: core.remoteCmuxPassword,
            remoteAutoSubmit: core.remoteAutoSubmit,
            listenerPort: Int(clamping: core.listenerPort),
            listenerToken: core.listenerToken,
            recentProjectDirs: core.recentProjectDirs,
            sessionIDsByProject: core.sessionIdsByProject,
            deviceMappings: [String: DeviceMapping](core: core.deviceMappings)
        )
    }

    var core: CoreAppConfig {
        CoreAppConfig(
            projectDir: projectDir,
            model: model,
            permissionMode: permissionMode,
            claudePath: claudePath,
            lastSessionId: lastSessionID,
            ttsEnabled: ttsEnabled,
            ttsRate: ttsRate,
            ttsVoiceId: ttsVoiceID,
            maxSpokenChars: Int64(maxSpokenChars),
            speakSummaries: speakSummaries,
            summaryModel: summaryModel,
            localeId: localeID,
            onDeviceRecognition: onDeviceRecognition,
            audioInputUid: audioInputUID,
            audioOutputUid: audioOutputUID,
            controllerDeviceId: controllerDeviceID,
            hapticsEnabled: hapticsEnabled,
            lightEnabled: lightEnabled,
            effort: effort,
            modelCycle: modelCycle,
            harnessKind: harnessKind,
            acpAgent: acpAgent,
            acpCustomCommand: acpCustomCommand,
            controlMode: controlMode,
            remoteTargetKind: remoteTargetKind,
            remoteCmuxWorkspace: remoteCmuxWorkspace,
            remoteCmuxSurface: remoteCmuxSurface,
            remoteAppBundleId: remoteAppBundleID,
            remoteCmuxPassword: remoteCmuxPassword,
            remoteAutoSubmit: remoteAutoSubmit,
            listenerPort: Int64(listenerPort),
            listenerToken: listenerToken,
            recentProjectDirs: recentProjectDirs,
            sessionIdsByProject: sessionIDsByProject,
            deviceMappings: deviceMappings.core
        )
    }
}
