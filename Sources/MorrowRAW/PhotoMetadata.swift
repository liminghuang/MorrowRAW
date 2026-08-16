import Foundation
import ImageIO

enum PhotoMetadataReader {
    static func displayDate(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        for inputFormat in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = inputFormat
            if let date = parser.date(from: raw) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "en_US_POSIX")
                output.dateFormat = inputFormat.contains("HH") ? "yyyy/MM/dd HH:mm:ss" : "yyyy/MM/dd"
                return output.string(from: date)
            }
        }
        return raw
    }

    static func read(url: URL) -> ExifData? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var result = ExifData()
        result.filePath = url.path
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            result.fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        result.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        result.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
            result.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            result.iso = string(exif[kCGImagePropertyExifISOSpeedRatings])
            result.aperture = number(exif[kCGImagePropertyExifFNumber], prefix: "f/")
            if let seconds = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                result.shutter = seconds.doubleValue >= 1
                    ? String(format: "%.1f s", seconds.doubleValue)
                    : String(format: "1/%.0f s", 1 / max(0.0001, seconds.doubleValue))
            }
            result.focalLength = number(exif[kCGImagePropertyExifFocalLength], suffix: " mm")
            result.exposureBias = number(exif[kCGImagePropertyExifExposureBiasValue], suffix: " EV")
            result.whiteBalance = mode(exif[kCGImagePropertyExifWhiteBalance], values: [0: "自動", 1: "手動"])
            result.meteringMode = mode(exif[kCGImagePropertyExifMeteringMode], values: [1: "平均", 2: "中央重點", 3: "點測光", 4: "多點測光", 5: "矩陣／多區", 6: "局部", 255: "其他"])
            result.dateTaken = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
        }
        if let ciff = properties[kCGImagePropertyCIFFDictionary] as? [CFString: Any] {
            if result.focusMode.isEmpty {
                result.focusMode = string(ciff[kCGImagePropertyCIFFFocusMode])
            }
            if result.meteringMode.isEmpty {
                result.meteringMode = string(ciff[kCGImagePropertyCIFFMeteringMode])
            }
        }
        return result
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? [NSNumber] { return value.map(\.stringValue).joined(separator: ",") }
        if let value = value as? NSNumber { return value.stringValue }
        return value as? String ?? ""
    }

    private static func number(_ value: Any?, prefix: String = "", suffix: String = "") -> String {
        guard let value = value as? NSNumber else { return "" }
        return prefix + String(format: "%.1f", value.doubleValue) + suffix
    }

    private static func mode(_ value: Any?, values: [Int: String]) -> String {
        guard let number = value as? NSNumber else { return "" }
        return values[number.intValue] ?? number.stringValue
    }
}
