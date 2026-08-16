import Foundation

/// Export controls persisted independently from per-photo RAW_TEMP adjustments.
struct ExportPreferences: Codable, Equatable {
    var quality = 0.92
    var maxLongEdge = 0
    var dpi = 300.0
    var preserveMetadata = true
    var naming: BatchExportNaming = .original
    var conflict: BatchConflictMode = .appendNumber
    var watermark = WatermarkSettings()
}

enum ExportPreferencesStore {
    private static let key = "MorrowRAW.exportPreferences"

    static func load(defaults: UserDefaults = .standard) -> ExportPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(ExportPreferences.self, from: data) else {
            return ExportPreferences()
        }
        return preferences
    }

    static func save(_ preferences: ExportPreferences, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
