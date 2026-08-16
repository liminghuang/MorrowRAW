import AppKit
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum StudioUI {
    static let background = Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 1))
    static let panel = Color(nsColor: NSColor(calibratedWhite: 0.105, alpha: 1))
    static let raised = Color(nsColor: NSColor(calibratedWhite: 0.145, alpha: 1))
    static let divider = Color(nsColor: NSColor(calibratedWhite: 0.24, alpha: 1))
    static let primary = Color(nsColor: NSColor(calibratedWhite: 0.92, alpha: 1))
    static let secondary = Color(nsColor: NSColor(calibratedWhite: 0.62, alpha: 1))
    static let accent = Color(red: 0.25, green: 0.57, blue: 0.95)
}

enum StudioText {
    private static var english: Bool {
        UserDefaults.standard.string(forKey: "MorrowRAW.language") == AppLanguage.english.rawValue
    }
    private static func t(_ zh: String, _ en: String) -> String { english ? en : zh }
    static func localized(_ zh: String, _ en: String) -> String { t(zh, en) }
    static var library: String { t("資料庫", "Library") }
    static var adjustments: String { t("調整", "Adjustments") }
    static var presets: String { t("預設", "Presets") }
    static var export: String { t("匯出", "Export") }
    static var info: String { t("資訊", "Info") }
    static var basic: String { t("基本調整", "Basic") }
    static var color: String { t("色彩", "Color") }
    static var detail: String { t("細節", "Detail") }
    static var geometry: String { t("幾何", "Geometry") }
    static var local: String { t("局部工具", "Local Tools") }
    static var versions: String { t("版本", "Versions") }
    static var original: String { t("原圖", "Original") }
    static var edited: String { t("已編輯", "Edited") }
    static var fit: String { t("適合", "Fit") }
    static var openFolder: String { t("開啟資料夾…", "Open Folder…") }
    static var openPhoto: String { t("開啟照片…", "Open Photo…") }
    static var recentFolders: String { t("最近開啟的資料夾", "Recent Folders") }
    static var noHistory: String { t("尚無開啟紀錄", "No History") }
    static var reset: String { t("重設全部", "Reset All") }
    static var undo: String { t("復原", "Undo") }
    static var redo: String { t("重做", "Redo") }
    static var copy: String { t("複製調整", "Copy Adjustments") }
    static var paste: String { t("貼上調整", "Paste Adjustments") }
    static var beforeAfter: String { t("前後對照", "Before/After") }
    static var closeBeforeAfter: String { t("關閉前後對照", "Close Before/After") }
    static var before: String { t("修圖前 · 原圖", "BEFORE · Original") }
    static var after: String { t("修圖後 · 已編輯", "AFTER · Edited") }
    static var jpegQuality: String { t("JPEG 品質", "JPEG Quality") }
    static var language: String { t("語言", "Language") }
    static var ok: String { t("好", "OK") }
    static var cancel: String { t("取消", "Cancel") }
    static var save: String { t("儲存", "Save") }
    static var photoOpenError: String { t("無法開啟照片", "Unable to open photo") }
    static var unknownError: String { t("未知錯誤", "Unknown error") }
    static var addCustomPreset: String { t("新增自訂預設", "Add Custom Preset") }
    static var presetName: String { t("預設名稱", "Preset Name") }
    static var exporting: String { t("正在匯出", "Exporting") }
    static var readingPhotos: String { t("正在讀取照片", "Loading photos") }
    static var foundPhotos: String { t("已找到", "Found") }
    static var decodingRAW: String { t("正在解碼 RAW", "Decoding RAW") }
    static var openPhotoToEdit: String { t("開啟照片開始編輯", "Open a photo to start editing") }
    static var photoInfo: String { t("照片資訊", "Photo Info") }
    static var filmstrip: String { t("膠卷", "Filmstrip") }
    static var zoomIn: String { t("放大", "Zoom In") }
    static var zoomOut: String { t("縮小", "Zoom Out") }
    static var selected: String { t("選取", "Select") }
    static var batch: String { t("批次", "Batch") }
    static var allPhotos: String { t("全部照片…", "All Photos…") }
    static var folder: String { t("資料夾", "Folder") }
    static var singlePhoto: String { t("單張照片", "Single Photo") }

    static func exporting(_ completed: Int, _ total: Int) -> String {
        "\(exporting) \(completed)/\(total)"
    }

    static func loadingPhotos(_ loaded: Int, _ total: Int) -> String {
        total > 0 ? "\(readingPhotos)… \(loaded)/\(total)" : "\(readingPhotos)… \(foundPhotos) \(loaded)"
    }

    static func decoding(_ name: String) -> String { "\(decodingRAW)：\(name)" }
    static func photoCount(_ count: Int) -> String { english ? "\(count) photos" : "\(count) 張" }
}

struct StudioSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: systemImage).frame(width: 17)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudioUI.secondary)
                }
                .foregroundStyle(StudioUI.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 12, content: content)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(StudioUI.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioUI.divider).frame(height: 1) }
    }
}

struct StudioAdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioUI.secondary)
            }
            Slider(value: $value, in: range) { _ in onChange() }
                .tint(StudioUI.accent)
        }
    }
}

struct StudioThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .font(.title2)
                    .foregroundStyle(failed ? .orange : StudioUI.secondary)
            }
            if isLoading {
                ProgressView().controlSize(.small).padding(6)
                    .background(.black.opacity(0.72), in: Circle())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .background(StudioUI.raised)
        .task(id: url) {
            isLoading = true
            failed = false
            let cgImage: CGImage? = await withTaskCancellationHandler(operation: {
                await ThumbnailDecodeGate.shared.acquire()
                guard !Task.isCancelled else {
                    await ThumbnailDecodeGate.shared.release()
                    return nil
                }
                let decodeTask = Task.detached(priority: .utility) {
                    PhotoThumbnailLoader.shared.loadCGImage(url: url)
                }
                let result = await decodeTask.value
                await ThumbnailDecodeGate.shared.release()
                return result
            }, onCancel: {
                Task { @MainActor in isLoading = false }
            })
            guard !Task.isCancelled else { return }
            image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            failed = cgImage == nil
            isLoading = false
        }
    }
}
