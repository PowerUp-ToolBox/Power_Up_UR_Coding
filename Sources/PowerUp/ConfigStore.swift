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

    private var saveWorkItem: DispatchWorkItem?

    init() {
        config = ConfigStore.loadOrDefault()

        // The remote read-back listener authenticates hook posts with this token,
        // so one must exist before anything can start. Minting it here (and
        // writing it straight away) means the hook script installed from Settings
        // and the running listener always agree on the same secret.
        if config.listenerToken.isEmpty {
            config.listenerToken = UUID().uuidString
            save()
        }
    }

    private static func loadOrDefault() -> AppConfig {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig.defaultConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(AppConfig.self, from: data)
            return decoded
        } catch {
            // Corrupt config: back it up and start fresh rather than crashing.
            backupCorruptFile(at: url)
            return AppConfig.defaultConfig()
        }
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

    func save() {
        let url = ConfigStore.configURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persisting is best-effort; never crash the app over a save failure.
        }
    }

    func resetMappingToDefault() {
        config.mapping = AppConfig.defaultMapping()
    }
}
