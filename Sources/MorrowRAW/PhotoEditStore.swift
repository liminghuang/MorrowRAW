import CryptoKit
import Foundation

/// Durable per-photo edit records. The legacy XML sidecar remains synchronized
/// so existing folders and older versions can continue to read the edits.
final class PhotoEditStore {
    static let shared = PhotoEditStore()

    private struct Record: Codable {
        let schemaVersion: Int
        let sourcePath: String
        let sourceFingerprint: String
        let copyIndex: Int
        let updatedAt: Date
        let adjustmentXML: Data
    }

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let schemaVersion = 1

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = (rootURL ?? base.appendingPathComponent("MorrowRAW/Edits", isDirectory: true))
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadOrMigrate(for sourceURL: URL, copyIndex: Int, legacyURL: URL) -> ImageAdjustments? {
        lock.lock()
        defer { lock.unlock() }
        if let record = readRecord(for: sourceURL, copyIndex: copyIndex) {
            guard record.schemaVersion <= schemaVersion,
                  record.sourceFingerprint == PhotoFileFingerprint.key(for: sourceURL) else {
                return nil
            }
            var adjustments = ImageAdjustments()
            return (try? adjustments.load(data: record.adjustmentXML)) == nil ? nil : adjustments
        }

        guard fileManager.fileExists(atPath: legacyURL.path) else { return nil }
        var migrated = ImageAdjustments()
        guard (try? migrated.load(from: legacyURL)) != nil else { return nil }
        try? saveUnlocked(migrated, for: sourceURL, copyIndex: copyIndex, legacyURL: legacyURL)
        return migrated
    }

    func save(_ adjustments: ImageAdjustments, for sourceURL: URL,
              copyIndex: Int, legacyURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(adjustments, for: sourceURL, copyIndex: copyIndex, legacyURL: legacyURL)
    }

    private func saveUnlocked(_ adjustments: ImageAdjustments, for sourceURL: URL,
                              copyIndex: Int, legacyURL: URL) throws {
        let xml = adjustments.xmlData()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the old sidecar available for older app versions and external tools.
        try adjustments.save(to: legacyURL)
        let record = Record(schemaVersion: schemaVersion,
                            sourcePath: sourceURL.standardizedFileURL.path,
                            sourceFingerprint: PhotoFileFingerprint.key(for: sourceURL),
                            copyIndex: copyIndex,
                            updatedAt: Date(), adjustmentXML: xml)
        let data = try JSONEncoder().encode(record)
        try data.write(to: recordURL(for: sourceURL, copyIndex: copyIndex), options: .atomic)
    }

    private func readRecord(for sourceURL: URL, copyIndex: Int) -> Record? {
        let url = recordURL(for: sourceURL, copyIndex: copyIndex)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func recordURL(for sourceURL: URL, copyIndex: Int) -> URL {
        let identity = "\(sourceURL.standardizedFileURL.path)|\(copyIndex)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}
