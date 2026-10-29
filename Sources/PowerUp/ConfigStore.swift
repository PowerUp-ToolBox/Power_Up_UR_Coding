import Foundation

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: AppConfig {
        didSet { scheduleSave() }
    }

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("PowerUp", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    /// The file this store loads from and saves to.
    let fileURL: URL

    private var saveWorkItem: DispatchWorkItem?

    /// The app's store, on the real `configURL`.
    convenience init() {
        self.init(fileURL: ConfigStore.configURL)
    }

    /// Test seam — mirrors `HookInstaller`'s injected `settingsURL`: a store
    /// pointed at a temp file never reads or writes the real configuration.
    init(fileURL: URL) {
        self.fileURL = fileURL
        config = ConfigStore.loadOrDefault(from: fileURL)

        // The remote read-back listener authenticates hook posts with this token,
        // so one must exist before anything can start. Minting it here (and
        // writing it straight away) means the hook script installed from Settings
        // and the running listener always agree on the same secret.
        if config.listenerToken.isEmpty {
            config.listenerToken = UUID().uuidString
            save()
        }
    }

    private static func loadOrDefault(from url: URL) -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig.defaultConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            backupConfigBeforeLossyLoadIfNeeded(at: url, data: data)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(AppConfig.self, from: data)
            return decoded
        } catch {
            // Corrupt config: back it up and start fresh rather than crashing.
            backupCorruptFile(at: url)
            return AppConfig.defaultConfig()
        }
    }

    /// A config the next save would rewrite lossily gets copied once first,
    /// so the user's bindings always stay recoverable on disk. Two triggers:
    /// (1) a pre-ADR-0006 file whose button-keyed `mapping` is about to be
    /// migrated into `deviceMappings`; (2) a `deviceMappings` containing
    /// entries this build cannot represent (a newer build's action, a
    /// hand-edit) that the tolerant decoder will drop. The decision is the
    /// Rust core's (`mapping::load_device_mappings`, slice 2.2); the copy, its
    /// `config.pre-profiles.json` name and its once-only rule stay here.
    /// Internal, URL-injected, so tests can exercise it against a temp
    /// directory.
    nonisolated static func backupConfigBeforeLossyLoadIfNeeded(at url: URL, data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value,
              let text = value.jsonText,
              CoreBridge.loadDeviceMappings(configJSON: text)?.backupBeforeSave == true else { return }
        let backupURL = url.deletingPathExtension().appendingPathExtension("pre-profiles.json")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }

    private static func backupCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension().appendingPathExtension("json.bak")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.moveItem(at: url, to: backupURL)
        } catch {
            // Best effort only; nothing else we can do here.
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// The exact bytes `save()` writes — pretty-printed, key-sorted, escaped
    /// slashes and all. Kept in one place so the byte-identity fixture test
    /// pins the real on-disk writer rather than a copy of its settings.
    nonisolated static func encode(_ config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    func save() {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try ConfigStore.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persisting is best-effort; never crash the app over a save failure.
        }
    }

    func resetMappingToDefault() {
        config.mapping = AppConfig.defaultMapping()
    }
}
