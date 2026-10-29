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

    /// The config the file holds, or the defaults. The reading is the
    /// core's (DESIGN v2.14); the file decisions are made here: a file that
    /// cannot be read or is corrupt is moved aside to config.json.bak
    /// (HK-160), and one the next save would rewrite lossily is copied once
    /// to config.pre-profiles.json first (HK-014). A core failure is never
    /// taken for corruption: the file stays, copied once, and the app runs on
    /// the defaults.
    private static func loadOrDefault(from url: URL) -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig.defaultConfig()
        }
        guard let data = try? Data(contentsOf: url) else {
            backupCorruptFile(at: url)
            return AppConfig.defaultConfig()
        }
        switch CoreBridge.loadConfig(data) {
        case .loaded(let config, let backupBeforeSave)?:
            if backupBeforeSave { copyOnceToPreProfiles(url) }
            return config
        case .corrupt?:
            backupCorruptFile(at: url)
            return AppConfig.defaultConfig()
        case nil:
            copyOnceToPreProfiles(url)
            return AppConfig.defaultConfig()
        }
    }

    /// A config the next save would rewrite lossily gets copied once first,
    /// so the user's bindings always stay recoverable on disk. Two triggers:
    /// (1) a pre-ADR-0006 file whose button-keyed `mapping` is about to be
    /// migrated into `deviceMappings`; (2) a `deviceMappings` containing
    /// entries this build cannot represent (a newer build's action, a
    /// hand-edit) that the tolerant decoder will drop. The decision is the
    /// Rust core's (`config::load_config`, from the mapping layer since
    /// slice 2.2); the copy, its `config.pre-profiles.json` name and its
    /// once-only rule stay here. A core that fails counts as lossy too: the
    /// app then runs on the defaults, and the save would bury the file.
    /// Internal, URL-injected, so tests can exercise it against a temp
    /// directory.
    nonisolated static func backupConfigBeforeLossyLoadIfNeeded(at url: URL, data: Data) {
        switch CoreBridge.loadConfig(data) {
        case .loaded(_, true)?, nil: copyOnceToPreProfiles(url)
        case .loaded(_, false)?, .corrupt?: break
        }
    }

    /// Copies config.json to config.pre-profiles.json unless a copy is
    /// already there: the first copy is the one worth keeping.
    nonisolated private static func copyOnceToPreProfiles(_ url: URL) {
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
    /// slashes and all, JSONEncoder's bytes as the core writes them
    /// (`config::encode_config`). Kept in one place so the byte-identity
    /// fixture test pins the real on-disk writer.
    nonisolated static func encode(_ config: AppConfig) throws -> Data {
        guard let data = CoreBridge.encodeConfig(config) else { throw ConfigFileError.coreUnavailable }
        return data
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
