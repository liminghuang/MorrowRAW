import Foundation

private struct TonalPreset: Codable {
    var exposure: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double
    var whites: Double
    var blacks: Double
    var temperature: Double
    var tint: Double
    var vibrance: Double
    var saturation: Double
    var sharpening: Double
    var noiseReduction: Double
    var vignette: Double
    var distortion: Double

    init(_ a: ImageAdjustments) {
        exposure = a.exposure; contrast = a.contrast; highlights = a.highlights
        shadows = a.shadows; whites = a.whites; blacks = a.blacks
        temperature = a.temperature; tint = a.tint; vibrance = a.vibrance
        saturation = a.saturation; sharpening = a.sharpening
        noiseReduction = a.noiseReduction; vignette = a.vignette; distortion = a.distortion
    }

    func apply(to a: inout ImageAdjustments) {
        a.resetTonal()
        a.exposure = exposure; a.contrast = contrast; a.highlights = highlights
        a.shadows = shadows; a.whites = whites; a.blacks = blacks
        a.temperature = temperature; a.tint = tint; a.vibrance = vibrance
        a.saturation = saturation; a.sharpening = sharpening
        a.noiseReduction = noiseReduction; a.vignette = vignette; a.distortion = distortion
    }
}

enum CustomPresetStore {
    private static let reservedNames = ["自訂1", "自訂2", "自訂3"]
    private static let key = "MorrowRAW.customPresets"

    private static func load() -> [String: TonalPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([String: TonalPreset].self, from: data)
        else { return [:] }
        return presets
    }

    private static func save(_ presets: [String: TonalPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Includes the original three slots plus any user-named presets.
    static var names: [String] {
        let all = Set(reservedNames).union(load().keys)
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func exists(_ name: String) -> Bool { load()[name] != nil }

    static func save(_ name: String, adjustments: ImageAdjustments) {
        var presets = load()
        presets[name] = TonalPreset(adjustments)
        save(presets)
    }

    static func apply(_ name: String, to adjustments: inout ImageAdjustments) -> Bool {
        guard let preset = load()[name] else { return false }
        preset.apply(to: &adjustments)
        return true
    }

    static func export(to url: URL) throws {
        let data = try JSONEncoder().encode(load())
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func `import`(from url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let presets = try JSONDecoder().decode([String: TonalPreset].self, from: data)
        save(presets)
        return Set(presets.keys)
    }
}
