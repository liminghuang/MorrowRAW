import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var photos: [URL] = []
    @Published var selectedIndex = 0
    @Published var selectedPhotoIndices: Set<Int> = []
    @Published private(set) var showOriginal = false
    @Published private(set) var beforeAfterEnabled = false
    @Published private(set) var beforeAfterOriginalPreview: NSImage?
    @Published var beforeAfterPosition: CGFloat = 0.5
    @Published var virtualCopyIndex = 0
    @Published var adjustments = ImageAdjustments()
    @Published var preview: NSImage?
    @Published var histogram: [CGFloat] = []
    @Published var rgbHistogram = RGBHistogram.empty
    @Published var sourceName = "尚未選擇照片"
    @Published var errorMessage: String?
    @Published var healingBrushEnabled = false
    @Published var zoomScale = 1.0
    @Published var watermark = WatermarkSettings()
    @Published var customPresetAvailability: Set<String> = []
    @Published var showingPresetNameSheet = false
    @Published var presetNameDraft = ""
    @Published private(set) var canPasteAdjustments = false
    @Published var exportQuality = 0.92
    @Published var exportMaxLongEdge = 0
    @Published var exportDPI: CGFloat = 300
    @Published var preserveMetadata = true
    @Published var whiteBalancePickerEnabled = false
    @Published var customCropRatio = "3:2"
    @Published var batchExportNaming: BatchExportNaming = .original
    @Published var batchConflictMode: BatchConflictMode = .appendNumber
    @Published var showHiddenPhotos = false
    @Published private(set) var isLoadingFolder = false
    @Published private(set) var folderLoadCount = 0
    @Published private(set) var isLoadingPhoto = false
    @Published private(set) var recentFolders: [String] = []
    @Published var appearance: AppAppearance = AppAppearance(rawValue:
        UserDefaults.standard.string(forKey: "MorrowRAW.appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "MorrowRAW.appearance") }
    }
    @Published var language: AppLanguage = AppLanguage(rawValue:
        UserDefaults.standard.string(forKey: "MorrowRAW.language") ?? "") ?? .traditionalChinese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "MorrowRAW.language") }
    }

    private let renderer = ImageRenderer()
    private let exporter = ImageExporter()
    private var source: CIImage?
    private var currentPhotoURL: URL?
    var currentFolderURL: URL?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var adjustmentURL: URL?
    private var undoStack: [ImageAdjustments] = []
    private var redoStack: [ImageAdjustments] = []
    private var copiedAdjustments: ImageAdjustments?
    private var lastHistoryState = ImageAdjustments()
    private var openURLObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var folderScanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var folderScanID = UUID()
    private var activeLoadID = UUID()

    init() {
        customPresetAvailability = Set(CustomPresetStore.names.filter { CustomPresetStore.exists($0) })
        let exportPreferences = ExportPreferencesStore.load()
        exportQuality = (exportPreferences.quality * 100).rounded() / 100
        exportMaxLongEdge = exportPreferences.maxLongEdge
        exportDPI = CGFloat(exportPreferences.dpi)
        preserveMetadata = exportPreferences.preserveMetadata
        batchExportNaming = exportPreferences.naming
        batchConflictMode = exportPreferences.conflict
        watermark = exportPreferences.watermark
        recentFolders = RecentFoldersStore.load()
        openURLObserver = NotificationCenter.default.addObserver(
            forName: .awayPhotoOpenURL, object: nil, queue: .main
        ) { [weak self] notification in
            guard let urls = notification.object as? [URL] else { return }
            Task { @MainActor [weak self] in
                self?.open(urls: urls)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: .awayPhotoWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingSave()
            }
        }
    }

    deinit {
        folderScanTask?.cancel()
        loadTask?.cancel()
        if let openURLObserver { NotificationCenter.default.removeObserver(openURLObserver) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func openPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = PhotoLibrary.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        photos = []
        selectedIndex = 0
        open(url: url)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        prepareForFolderChange(to: folder)
        recentFolders = RecentFoldersStore.remember(folder)
        startFolderScan(folder)
    }

    func openRecentFolder(_ path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            recentFolders = RecentFoldersStore.load().filter { FileManager.default.fileExists(atPath: $0) }
            return
        }
        prepareForFolderChange(to: folder)
        recentFolders = RecentFoldersStore.remember(folder)
        startFolderScan(folder)
    }

    func open(url: URL) {
        open(urls: [url])
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            openDropped(url: urls[0])
            return
        }
        let supported = urls.filter {
            PhotoLibrary.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else {
            errorMessage = "沒有支援的照片格式"
            return
        }
        photos = supported
        currentFolderURL = nil
        selectedIndex = 0
        selectedPhotoIndices = [0]
        load(url: supported[0], copyIndex: 0)
    }

    func openDropped(url: URL) {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            prepareForFolderChange(to: url)
            recentFolders = RecentFoldersStore.remember(url)
            startFolderScan(url)
        } else {
            currentFolderURL = nil
            photos = []
            selectedIndex = 0
            selectedPhotoIndices = []
            load(url: url, copyIndex: 0)
        }
    }

    func selectPhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        selectedIndex = index
        selectedPhotoIndices = [index]
        load(url: photos[index], copyIndex: 0)
    }

    func setPhotoSelection(at index: Int, selected: Bool) {
        guard photos.indices.contains(index) else { return }
        if selected {
            selectedPhotoIndices.insert(index)
        } else {
            selectedPhotoIndices.remove(index)
        }
    }

    func toggleCurrentPhotoVisibility() {
        guard let photo = currentPhotoURL, let folder = currentFolderURL else { return }
        saveCurrentAdjustments()
        var state = PhotoLibraryState.load(folder: folder)
        if showHiddenPhotos {
            state.show(photo)
        } else {
            state.hide(photo)
        }
        do {
            try state.save(folder: folder)
            photos = PhotoLibrary.scan(folder: folder, includeHidden: showHiddenPhotos, rawOnly: true)
            if let next = photos.first {
                selectedIndex = 0
                load(url: next, copyIndex: 0)
            } else {
                selectedIndex = 0
                source = nil
                preview = nil
                histogram = []
                rgbHistogram = .empty
                currentPhotoURL = nil
                sourceName = "沒有可顯示的照片"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadFolderVisibility() {
        guard let folder = currentFolderURL else { return }
        let scanned = PhotoLibrary.scan(folder: folder, includeHidden: showHiddenPhotos, rawOnly: true)
        photos = scanned
        guard !scanned.isEmpty else {
            selectedIndex = 0
            source = nil
            preview = nil
            histogram = []
            rgbHistogram = .empty
            currentPhotoURL = nil
            sourceName = "沒有可顯示的照片"
            return
        }
        selectedIndex = min(selectedIndex, scanned.count - 1)
        load(url: scanned[selectedIndex], copyIndex: 0)
    }

    private func load(url: URL, copyIndex: Int = 0) {
        activeLoadID = UUID()
        saveCurrentAdjustments()
        saveTask?.cancel()
        loadTask?.cancel()
        preview = nil
        beforeAfterOriginalPreview = nil
        beforeAfterEnabled = false
        histogram = []
        rgbHistogram = .empty
        isLoadingPhoto = false
        do {
            let image = try ApplePhotoDecoder().decode(url: url)
            applyLoadedPhoto(url: url, copyIndex: copyIndex, image: image,
                             exif: PhotoMetadataReader.read(url: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadInBackground(url: URL, copyIndex: Int = 0) {
        saveCurrentAdjustments()
        saveTask?.cancel()
        loadTask?.cancel()
        preview = nil
        beforeAfterOriginalPreview = nil
        beforeAfterEnabled = false
        histogram = []
        rgbHistogram = .empty
        sourceName = url.lastPathComponent
        isLoadingPhoto = true
        let loadID = UUID()
        activeLoadID = loadID
        loadTask = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoDecoder().decode(url: url)
                }.value
                let exif = await Task.detached(priority: .utility) {
                    PhotoMetadataReader.read(url: url)
                }.value
                guard !Task.isCancelled else { return }
                guard let self, self.activeLoadID == loadID else { return }
                self.applyLoadedPhoto(url: url, copyIndex: copyIndex, image: image, exif: exif)
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoadingPhoto = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func applyLoadedPhoto(url: URL, copyIndex: Int, image: CIImage, exif: ExifData?) {
        isLoadingPhoto = false
        source = image
        currentPhotoURL = url
        virtualCopyIndex = copyIndex
        sourceName = url.lastPathComponent
        showOriginal = false
        adjustments = ImageAdjustments()
        let xmlURL = adjustmentURL(for: url, copyIndex: copyIndex)
        adjustmentURL = xmlURL
        do {
            if FileManager.default.fileExists(atPath: xmlURL.path) {
                try adjustments.load(from: xmlURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if adjustments.cachedExif == nil {
            adjustments.cachedExif = exif
        }
        if !["Original", "3:2", "4:3", "16:9", "1:1"].contains(adjustments.cropAspectRatio) {
            customCropRatio = adjustments.cropAspectRatio
        }
        undoStack.removeAll()
        redoStack.removeAll()
        lastHistoryState = adjustments
        scheduleRender()
    }

    private func startFolderScan(_ folder: URL) {
        folderScanTask?.cancel()
        let scanID = UUID()
        folderScanID = scanID
        isLoadingFolder = true
        folderLoadCount = 0
        photos = []
        selectedIndex = 0
        selectedPhotoIndices = []
        let includeHidden = showHiddenPhotos
        let model = self
        folderScanTask = Task.detached(priority: .userInitiated) {
            let scanned = PhotoLibrary.scanIncrementally(folder: folder, includeHidden: includeHidden, rawOnly: true) { url in
                Task { @MainActor in
                    guard model.folderScanID == scanID else { return }
                    model.photos.append(url)
                    model.folderLoadCount = model.photos.count
                    if model.photos.count == 1 {
                        model.selectedIndex = 0
                        model.selectedPhotoIndices = [0]
                        model.loadInBackground(url: url, copyIndex: 0)
                    }
                }
            }
            await MainActor.run {
                guard model.folderScanID == scanID else { return }
                model.folderScanTask = nil
                model.isLoadingFolder = false
                model.photos = scanned
                if let first = scanned.first {
                    model.selectedIndex = 0
                    model.selectedPhotoIndices = [0]
                    if model.currentPhotoURL != first {
                        model.loadInBackground(url: first, copyIndex: 0)
                    }
                }
                if scanned.isEmpty {
                    model.errorMessage = "資料夾中沒有支援的照片格式"
                }
            }
        }
    }

    func cancelFolderLoading() {
        folderScanID = UUID()
        folderScanTask?.cancel()
        folderScanTask = nil
        isLoadingFolder = false
        photos = []
        selectedPhotoIndices = []
        isLoadingPhoto = false
    }

    private func prepareForFolderChange(to folder: URL) {
        saveCurrentAdjustments()
        currentFolderURL = folder
        photos = []
        selectedIndex = 0
        selectedPhotoIndices = []
        virtualCopyIndex = 0
        adjustments = ImageAdjustments()
        preview = nil
        histogram = []
        rgbHistogram = .empty
        source = nil
        currentPhotoURL = nil
        adjustmentURL = nil
        sourceName = "尚未選擇照片"
        showOriginal = false
        undoStack.removeAll()
        redoStack.removeAll()
        lastHistoryState = adjustments
    }

    func scheduleRender() {
        renderTask?.cancel()
        guard let source else { return }
        recordHistoryIfNeeded()
        let current = showOriginal ? originalPreviewAdjustments() : adjustments
        let editedAdjustments = adjustments
        let compare = beforeAfterEnabled && !showOriginal
        let originalAdjustments = originalPreviewAdjustments()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let interactivePair = await Task.detached(priority: .userInitiated) {
                let renderer = ImageRenderer()
                let edited = await renderer.makePreviewAsync(
                    source, adjustments: compare ? editedAdjustments : current, quality: .interactive
                )
                let original = compare
                    ? await renderer.makePreviewAsync(source, adjustments: originalAdjustments,
                                                      quality: .interactive)
                    : nil
                return (edited, original)
            }.value
            guard !Task.isCancelled, let interactivePreview = interactivePair.0 else { return }
            self.preview = NSImage(cgImage: interactivePreview, size: .zero)
            self.beforeAfterOriginalPreview = interactivePair.1.map { NSImage(cgImage: $0, size: .zero) }
            self.histogram = HistogramCalculator.bins(for: interactivePreview)
            self.rgbHistogram = HistogramCalculator.rgbBins(for: interactivePreview)

            // Let the user see the responsive low-quality result first, then
            // refine only if no newer adjustment cancelled this render task.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let finalPair = await Task.detached(priority: .userInitiated) {
                let renderer = ImageRenderer()
                let edited = await renderer.makePreviewAsync(
                    source, adjustments: compare ? editedAdjustments : current, quality: .finalPreview
                )
                let original = compare
                    ? await renderer.makePreviewAsync(source, adjustments: originalAdjustments,
                                                      quality: .finalPreview)
                    : nil
                return (edited, original)
            }.value
            guard !Task.isCancelled, let finalPreview = finalPair.0 else { return }
            self.preview = NSImage(cgImage: finalPreview, size: .zero)
            self.beforeAfterOriginalPreview = finalPair.1.map { NSImage(cgImage: $0, size: .zero) }
            self.histogram = HistogramCalculator.bins(for: finalPreview)
            self.rgbHistogram = HistogramCalculator.rgbBins(for: finalPreview)
        }

        saveTask?.cancel()
        let savedAdjustments = adjustments
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? savedAdjustments.save(to: self?.adjustmentURL ?? URL(fileURLWithPath: "/dev/null"))
        }
    }

    func toggleShowOriginal() {
        beforeAfterEnabled = false
        beforeAfterOriginalPreview = nil
        showOriginal.toggle()
        scheduleRender()
    }

    func toggleBeforeAfter() {
        showOriginal = false
        beforeAfterEnabled.toggle()
        if beforeAfterEnabled {
            scheduleRender()
        } else {
            beforeAfterOriginalPreview = nil
        }
    }

    func setBeforeAfterPosition(_ position: CGFloat) {
        beforeAfterPosition = min(1, max(0, position))
    }

    /// Returns a preview-only neutral state while preserving the user's geometry.
    func originalPreviewAdjustments() -> ImageAdjustments {
        var neutral = adjustments
        neutral.resetTonal()
        neutral.gradients.removeAll()
        neutral.healSpots.removeAll()
        return neutral
    }

    func export(format: ImageExportFormat) {
        guard let source else { return }
        saveCurrentAdjustments()
        saveExportPreferences()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = URL(fileURLWithPath: sourceName)
            .deletingPathExtension().lastPathComponent + "_edited." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try exporter.export(source: source, adjustments: adjustments, to: url, format: format,
                                quality: exportQuality, maxLongEdge: exportMaxLongEdge > 0 ? exportMaxLongEdge : nil,
                                sourceURL: currentPhotoURL,
                                dpi: exportDPI, preserveMetadata: preserveMetadata,
                                watermark: watermark)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportAll(format: ImageExportFormat) {
        let exportURLs = PhotoLibrary.exportable(photos, from: currentFolderURL)
        guard !exportURLs.isEmpty else {
            errorMessage = "沒有可匯出的照片"
            return
        }
        saveCurrentAdjustments()
        saveExportPreferences()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇匯出資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let result = try? ImageBatchExporter().export(urls: exportURLs, to: folder, format: format,
                                                       quality: exportQuality,
                                                       maxLongEdge: exportMaxLongEdge > 0 ? exportMaxLongEdge : nil,
                                                       dpi: exportDPI, preserveMetadata: preserveMetadata,
                                                       naming: batchExportNaming,
                                                       conflict: batchConflictMode,
                                                       watermark: watermark)
        guard let result else {
            errorMessage = "批次匯出失敗"
            return
        }
        if !result.failures.isEmpty {
            errorMessage = "已匯出 \(result.writtenURLs.count) 張，\(result.failures.count) 張失敗"
        }
    }

    func rotateLeft() {
        adjustments.rotation = (adjustments.rotation + 270) % 360
        scheduleRender()
    }

    func rotateRight() {
        adjustments.rotation = (adjustments.rotation + 90) % 360
        scheduleRender()
    }

    func resetCrop() {
        adjustments.cropX = 0
        adjustments.cropY = 0
        adjustments.cropWidth = 1
        adjustments.cropHeight = 1
        adjustments.cropAngle = 0
        scheduleRender()
    }

    func applyCustomCropRatio() {
        let components = customCropRatio.split(separator: ":", maxSplits: 1).compactMap { Double($0) }
        guard components.count == 2, components.allSatisfy({ $0 > 0 }) else {
            errorMessage = "裁切比例格式應為寬:高，例如 5:4"
            return
        }
        adjustments.cropAspectRatio = "\(components[0]):\(components[1])"
        scheduleRender()
    }

    func resetAllAdjustments() {
        adjustments = ImageAdjustments()
        scheduleRender()
    }

    func toggleWhiteBalancePicker() {
        whiteBalancePickerEnabled.toggle()
    }

    func pickWhiteBalance(at normalizedPoint: CGPoint) {
        guard whiteBalancePickerEnabled, let source,
              let result = WhiteBalanceSampler.sample(source: source, normalizedPoint: normalizedPoint) else { return }
        adjustments.temperature = result.temperature
        adjustments.tint = result.tint
        whiteBalancePickerEnabled = false
        scheduleRender()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(adjustments)
        adjustments = previous
        lastHistoryState = adjustments
        scheduleRender()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(adjustments)
        adjustments = next
        lastHistoryState = adjustments
        scheduleRender()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var virtualCopyCount: Int {
        guard let currentPhotoURL else { return 0 }
        var count = 1
        while FileManager.default.fileExists(atPath: adjustmentURL(for: currentPhotoURL,
                                                                    copyIndex: count).path) {
            count += 1
        }
        return count
    }

    func createVirtualCopy() {
        guard let currentPhotoURL else { return }
        saveCurrentAdjustments()
        let next = virtualCopyCount
        let baseURL = adjustmentURL(for: currentPhotoURL, copyIndex: 0)
        let copyURL = adjustmentURL(for: currentPhotoURL, copyIndex: next)
        do {
            if FileManager.default.fileExists(atPath: baseURL.path) {
                try FileManager.default.copyItem(at: baseURL, to: copyURL)
            } else {
                try adjustments.save(to: copyURL)
            }
            load(url: currentPhotoURL, copyIndex: next)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchVirtualCopy(by offset: Int) {
        guard let currentPhotoURL else { return }
        let next = virtualCopyIndex + offset
        guard next >= 0, next < virtualCopyCount else { return }
        load(url: currentPhotoURL, copyIndex: next)
    }

    func zoomIn() { zoomScale = min(4, zoomScale * 1.25) }
    func zoomOut() { zoomScale = max(0.25, zoomScale / 1.25) }
    func resetZoom() { zoomScale = 1 }

    func applyPreset(_ preset: BuiltInPreset) {
        preset.apply(to: &adjustments)
        scheduleRender()
    }

    func applyPresetToAll(_ preset: BuiltInPreset) {
        guard photos.count > 1 else { return }
        saveCurrentAdjustments()
        let result = BatchAdjustmentService.applyPreset(preset, to: photos)
        load(url: photos[selectedIndex], copyIndex: virtualCopyIndex)
        if result.failureCount > 0 {
            errorMessage = "已更新 \(result.updatedCount) 張，\(result.failureCount) 張失敗"
        }
    }

    func applyPresetToSelected(_ preset: BuiltInPreset) {
        let targets = selectedPhotoIndices
            .sorted()
            .compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        let exportableTargets = PhotoLibrary.exportable(targets, from: currentFolderURL)
        guard !exportableTargets.isEmpty else { return }
        saveCurrentAdjustments()
        let result = BatchAdjustmentService.applyPreset(preset, to: exportableTargets)
        if photos.indices.contains(selectedIndex) {
            load(url: photos[selectedIndex], copyIndex: virtualCopyIndex)
        }
        if result.failureCount > 0 {
            errorMessage = "已更新 \(result.updatedCount) 張，\(result.failureCount) 張失敗"
        }
    }

    func copyCurrentAdjustmentsToAll() {
        guard photos.count > 1 else { return }
        saveCurrentAdjustments()
        let result = BatchAdjustmentService.copy(adjustments, to: photos)
        load(url: photos[selectedIndex], copyIndex: virtualCopyIndex)
        if result.failureCount > 0 {
            errorMessage = "已更新 \(result.updatedCount) 張，\(result.failureCount) 張失敗"
        }
    }

    func copyCurrentAdjustmentsToSelected() {
        let targets = selectedPhotoIndices
            .sorted()
            .compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        let exportableTargets = PhotoLibrary.exportable(targets, from: currentFolderURL)
        guard !exportableTargets.isEmpty else { return }
        saveCurrentAdjustments()
        let result = BatchAdjustmentService.copy(adjustments, to: exportableTargets)
        if photos.indices.contains(selectedIndex) {
            load(url: photos[selectedIndex], copyIndex: virtualCopyIndex)
        }
        if result.failureCount > 0 {
            errorMessage = "已更新 \(result.updatedCount) 張，\(result.failureCount) 張失敗"
        }
    }

    /// Copies only editable values. The destination keeps its own EXIF metadata.
    func copyPhotoAdjustments() {
        saveCurrentAdjustments()
        copiedAdjustments = adjustments
        canPasteAdjustments = true
    }

    func pastePhotoAdjustments() {
        guard var copiedAdjustments else { return }
        copiedAdjustments.cachedExif = adjustments.cachedExif
        adjustments = copiedAdjustments
        scheduleRender()
    }

    func applyCustomPreset(_ name: String) {
        guard CustomPresetStore.apply(name, to: &adjustments) else { return }
        scheduleRender()
    }

    func saveCustomPreset(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        CustomPresetStore.save(name, adjustments: adjustments)
        customPresetAvailability.insert(name)
    }

    func beginNewCustomPreset() {
        presetNameDraft = ""
        showingPresetNameSheet = true
    }

    func saveNewCustomPreset() {
        saveCustomPreset(presetNameDraft)
        showingPresetNameSheet = false
    }

    func exportCustomPresets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MorrowRAW-Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CustomPresetStore.export(to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importCustomPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            customPresetAvailability = try CustomPresetStore.import(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addGradient() {
        adjustments.gradients.append(LinearGradient())
        scheduleRender()
    }

    func removeLastGradient() {
        guard !adjustments.gradients.isEmpty else { return }
        adjustments.gradients.removeLast()
        scheduleRender()
    }

    func gradientIndexNearCenter(_ point: CGPoint, tolerance: CGFloat = 0.06) -> Int? {
        adjustments.gradients.enumerated().min {
            hypot($0.element.centerX - point.x, $0.element.centerY - point.y) <
                hypot($1.element.centerX - point.x, $1.element.centerY - point.y)
        }.flatMap { index, gradient in
            hypot(gradient.centerX - point.x, gradient.centerY - point.y) <= tolerance ? index : nil
        }
    }

    func moveGradientCenter(at index: Int, to point: CGPoint) {
        guard adjustments.gradients.indices.contains(index) else { return }
        adjustments.gradients[index].centerX = min(1, max(0, point.x))
        adjustments.gradients[index].centerY = min(1, max(0, point.y))
        scheduleRender()
    }

    func addHealSpot(inpaint: Bool) {
        adjustments.healSpots.append(HealSpot(targetX: 0.5, targetY: 0.5,
                                              sourceX: 0.25, sourceY: 0.25,
                                              radiusNorm: 0.03, useInpaint: inpaint))
        scheduleRender()
    }

    func addHealSpot(target: CGPoint, source: CGPoint) {
        adjustments.healSpots.append(HealSpot(targetX: min(1, max(0, target.x)),
                                              targetY: min(1, max(0, target.y)),
                                              sourceX: min(1, max(0, source.x)),
                                              sourceY: min(1, max(0, source.y)),
                                              radiusNorm: max(0.005, adjustments.healSize / 1000),
                                              useInpaint: false))
        scheduleRender()
    }

    func healSpotIndexNearSource(_ point: CGPoint, tolerance: CGFloat = 0.045) -> Int? {
        adjustments.healSpots.enumerated().min {
            hypot($0.element.sourceX - point.x, $0.element.sourceY - point.y) <
                hypot($1.element.sourceX - point.x, $1.element.sourceY - point.y)
        }.flatMap { index, spot in
            hypot(spot.sourceX - point.x, spot.sourceY - point.y) <= tolerance ? index : nil
        }
    }

    func moveHealSource(at index: Int, to point: CGPoint) {
        guard adjustments.healSpots.indices.contains(index) else { return }
        adjustments.healSpots[index].sourceX = min(1, max(0, point.x))
        adjustments.healSpots[index].sourceY = min(1, max(0, point.y))
        scheduleRender()
    }

    func removeLastHealSpot() {
        guard !adjustments.healSpots.isEmpty else { return }
        adjustments.healSpots.removeLast()
        scheduleRender()
    }

    func clearHealSpots() {
        guard !adjustments.healSpots.isEmpty else { return }
        adjustments.healSpots.removeAll()
        scheduleRender()
    }

    func toggleHealingBrush() {
        healingBrushEnabled.toggle()
    }

    func paintHeal(at normalizedPoint: CGPoint) {
        guard healingBrushEnabled else { return }
        let x = min(1, max(0, normalizedPoint.x))
        let y = min(1, max(0, normalizedPoint.y))
        adjustments.healSpots.append(HealSpot(targetX: x, targetY: y,
                                              sourceX: x, sourceY: y,
                                              radiusNorm: max(0.005, adjustments.healSize / 1000),
                                              useInpaint: true))
        scheduleRender()
    }

    private func adjustmentURL(for photoURL: URL, copyIndex: Int = 0) -> URL {
        let filename = copyIndex == 0
            ? photoURL.lastPathComponent + ".rawpipe.xml"
            : photoURL.lastPathComponent + ".copy\(copyIndex).rawpipe.xml"
        return photoURL.deletingLastPathComponent()
            .appendingPathComponent("RAW_TEMP")
            .appendingPathComponent(filename)
    }

    private func saveCurrentAdjustments() {
        guard let adjustmentURL else { return }
        try? adjustments.save(to: adjustmentURL)
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveCurrentAdjustments()
        saveExportPreferences()
    }

    private func saveExportPreferences() {
        ExportPreferencesStore.save(ExportPreferences(
            quality: exportQuality,
            maxLongEdge: exportMaxLongEdge,
            dpi: Double(exportDPI),
            preserveMetadata: preserveMetadata,
            naming: batchExportNaming,
            conflict: batchConflictMode,
            watermark: watermark
        ))
    }

    private func recordHistoryIfNeeded() {
        guard adjustments != lastHistoryState else { return }
        undoStack.append(lastHistoryState)
        redoStack.removeAll()
        lastHistoryState = adjustments
        if undoStack.count > 50 {
            undoStack.removeFirst(undoStack.count - 50)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = EditorViewModel()

    var body: some View {
        StudioWorkspace(model: model)
            .preferredColorScheme(model.appearance.colorScheme)
            .onDisappear { model.flushPendingSave() }
            .onAppear {
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    let urls = delegate.consumePendingURLs()
                    if !urls.isEmpty { model.open(urls: urls) }
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let path = (object as? NSURL)?.path else { return }
                    Task { @MainActor in model.openDropped(url: URL(fileURLWithPath: path)) }
                }
                return true
            }
    }

    private var legacyBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let preview = model.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(model.zoomScale)
                            .padding(24)
                    } else {
                        Text("開啟照片開始編輯")
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button("−") { model.zoomOut() }
                            Button("Fit") { model.resetZoom() }
                            Text("\(Int(model.zoomScale * 100))%")
                                .monospacedDigit()
                                .frame(width: 48)
                            Button("+") { model.zoomIn() }
                            Button(model.showOriginal ? "Edited" : "Original") {
                                model.toggleShowOriginal()
                            }
                        }
                        .buttonStyle(.bordered)
                        .padding(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let point = CGPoint(
                                        x: value.location.x / geometry.size.width,
                                        y: value.location.y / geometry.size.height)
                                    if model.whiteBalancePickerEnabled {
                                        model.pickWhiteBalance(at: point)
                                    } else {
                                        model.paintHeal(at: point)
                                    }
                                })
                            .simultaneousGesture(MagnificationGesture()
                                .onChanged { value in
                                    guard !model.healingBrushEnabled else { return }
                                    model.zoomScale = min(4, max(0.25, value))
                                })
                    }
                }

                Divider()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                    Text(model.sourceName)
                        .font(.headline)
                        .lineLimit(1)

                    if let exif = model.adjustments.cachedExif {
                        VStack(alignment: .leading, spacing: 3) {
                            if !exif.cameraMake.isEmpty || !exif.cameraModel.isEmpty {
                                Text([exif.cameraMake, exif.cameraModel]
                                    .filter { !$0.isEmpty }.joined(separator: " "))
                            }
                            if !exif.lens.isEmpty { Text(exif.lens) }
                            let capture = [exif.iso.isEmpty ? nil : "ISO \(exif.iso)",
                                           exif.aperture.isEmpty ? nil : exif.aperture,
                                           exif.shutter.isEmpty ? nil : exif.shutter,
                                           exif.focalLength.isEmpty ? nil : exif.focalLength]
                                .compactMap { $0 }.joined(separator: " · ")
                            if !capture.isEmpty { Text(capture) }
                            if exif.width > 0 && exif.height > 0 {
                                Text("\(exif.width) × \(exif.height)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !model.histogram.isEmpty {
                        Text("Histogram")
                            .font(.headline)
                        HistogramView(bins: model.histogram)
                            .frame(height: 90)
                    }

                    AdjustmentSlider(title: "Exposure", value: $model.adjustments.exposure,
                                     range: -5...5, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Contrast", value: $model.adjustments.contrast,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Highlights", value: $model.adjustments.highlights,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Shadows", value: $model.adjustments.shadows,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Whites", value: $model.adjustments.whites,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Blacks", value: $model.adjustments.blacks,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Temperature", value: $model.adjustments.temperature,
                                     range: 2000...12000, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Tint", value: $model.adjustments.tint,
                                     range: -100...100, onChange: model.scheduleRender)
                    Button(model.whiteBalancePickerEnabled ? "Click image to sample…" : "White Balance Picker") {
                        model.toggleWhiteBalancePicker()
                    }
                    AdjustmentSlider(title: "Saturation", value: $model.adjustments.saturation,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Vibrance", value: $model.adjustments.vibrance,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Sharpening", value: $model.adjustments.sharpening,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Noise Reduction", value: $model.adjustments.noiseReduction,
                                     range: 0...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Vignette", value: $model.adjustments.vignette,
                                     range: -100...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Distortion", value: $model.adjustments.distortion,
                                     range: -100...100, onChange: model.scheduleRender)

                    Text("Crop")
                        .font(.headline)
                    Picker("Aspect", selection: $model.adjustments.cropAspectRatio) {
                        Text("Original").tag("Original")
                        Text("3:2").tag("3:2")
                        Text("4:3").tag("4:3")
                        Text("16:9").tag("16:9")
                        Text("1:1").tag("1:1")
                    }
                    .onChange(of: model.adjustments.cropAspectRatio) { _ in
                        model.scheduleRender()
                    }
                    HStack {
                        TextField("Custom ratio", text: $model.customCropRatio)
                            .textFieldStyle(.roundedBorder)
                        Button("Apply") { model.applyCustomCropRatio() }
                    }
                    AdjustmentSlider(title: "X", value: $model.adjustments.cropX,
                                     range: 0...0.9, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Y", value: $model.adjustments.cropY,
                                     range: 0...0.9, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Width", value: $model.adjustments.cropWidth,
                                     range: 0.1...1, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Height", value: $model.adjustments.cropHeight,
                                     range: 0.1...1, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Angle", value: $model.adjustments.cropAngle,
                                     range: -45...45, onChange: model.scheduleRender)
                    HStack {
                        Button("↺") { model.rotateLeft() }
                        Button("↻") { model.rotateRight() }
                        Button("Reset Crop") { model.resetCrop() }
                    }

                    HStack {
                        Text("Gradients")
                            .font(.headline)
                        Spacer()
                        Button("+") { model.addGradient() }
                        Button("−") { model.removeLastGradient() }
                            .disabled(model.adjustments.gradients.isEmpty)
                    }
                    if !model.adjustments.gradients.isEmpty {
                        let index = model.adjustments.gradients.count - 1
                        Text("Editing gradient \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AdjustmentSlider(title: "Gradient Exposure",
                                         value: $model.adjustments.gradients[index].exposure,
                                         range: -2...2, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Contrast",
                                         value: $model.adjustments.gradients[index].contrast,
                                         range: -100...100, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Highlights",
                                         value: $model.adjustments.gradients[index].highlights,
                                         range: -100...100, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Shadows",
                                         value: $model.adjustments.gradients[index].shadows,
                                         range: -100...100, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Saturation",
                                         value: $model.adjustments.gradients[index].saturation,
                                         range: -100...100, onChange: model.scheduleRender)
                    }

                    HStack {
                        Text("Heal")
                            .font(.headline)
                        Spacer()
                        Button(model.healingBrushEnabled ? "Brush On" : "Brush") {
                            model.toggleHealingBrush()
                        }
                        Button("Clone") { model.addHealSpot(inpaint: false) }
                        Button("Inpaint") { model.addHealSpot(inpaint: true) }
                        Button("−") { model.removeLastHealSpot() }
                            .disabled(model.adjustments.healSpots.isEmpty)
                    }
                    if !model.adjustments.healSpots.isEmpty {
                        let index = model.adjustments.healSpots.count - 1
                        Text("Editing heal spot \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AdjustmentSlider(title: "Target X",
                                         value: $model.adjustments.healSpots[index].targetX,
                                         range: 0...1, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Target Y",
                                         value: $model.adjustments.healSpots[index].targetY,
                                         range: 0...1, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Source X",
                                         value: $model.adjustments.healSpots[index].sourceX,
                                         range: 0...1, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Source Y",
                                         value: $model.adjustments.healSpots[index].sourceY,
                                         range: 0...1, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Radius",
                                         value: $model.adjustments.healSpots[index].radiusNorm,
                                         range: 0.005...0.2, onChange: model.scheduleRender)
                    }

                    HStack {
                        Text("Virtual Copy \(model.virtualCopyIndex + 1)/\(max(1, model.virtualCopyCount))")
                            .font(.headline)
                        Spacer()
                        Button("←") { model.switchVirtualCopy(by: -1) }
                            .disabled(model.virtualCopyIndex == 0)
                        Button("New") { model.createVirtualCopy() }
                        Button("→") { model.switchVirtualCopy(by: 1) }
                            .disabled(model.virtualCopyIndex + 1 >= model.virtualCopyCount)
                    }

                    Spacer()

                    Button("開啟資料夾…", action: model.openFolder)
                    Button("開啟照片…", action: model.openPhoto)
                        .keyboardShortcut("o", modifiers: [.command])
                    Menu("最近開啟的資料夾") {
                        if model.recentFolders.isEmpty {
                            Text("尚無開啟紀錄")
                        } else {
                            ForEach(model.recentFolders, id: \.self) { path in
                                Button(path) { model.openRecentFolder(path) }
                            }
                        }
                    }
                    HStack {
                        Button(model.showHiddenPhotos ? "恢復目前照片" : "隱藏目前照片") {
                            model.toggleCurrentPhotoVisibility()
                        }
                            .disabled(model.preview == nil || model.currentFolderURL == nil)
                        Toggle("顯示隱藏", isOn: $model.showHiddenPhotos)
                            .onChange(of: model.showHiddenPhotos) { _ in
                                model.reloadFolderVisibility()
                            }
                    }

                        Menu("匯出…") {
                            Button("JPEG…") { model.export(format: .jpeg) }
                            Button("PNG…") { model.export(format: .png) }
                            Button("TIFF…") { model.export(format: .tiff) }
                            Button("BMP…") { model.export(format: .bmp) }
                            if model.photos.count > 1 {
                                Divider()
                                Menu("全部照片…") {
                                    Button("JPEG") { model.exportAll(format: .jpeg) }
                                    Button("PNG") { model.exportAll(format: .png) }
                                    Button("TIFF") { model.exportAll(format: .tiff) }
                                    Button("BMP") { model.exportAll(format: .bmp) }
                                }
                            }
                        }
                        .disabled(model.preview == nil)
                        .keyboardShortcut("e", modifiers: [.command])
                        Button("Reset All") { model.resetAllAdjustments() }
                        Menu("Photo Settings") {
                            Button("Copy Adjustments") { model.copyPhotoAdjustments() }
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                            Button("Paste Adjustments") { model.pastePhotoAdjustments() }
                                .disabled(!model.canPasteAdjustments)
                                .keyboardShortcut("v", modifiers: [.command, .shift])
                        }
                        HStack {
                            Button("Undo") { model.undo() }
                                .disabled(!model.canUndo)
                                .keyboardShortcut("z", modifiers: [.command])
                            Button("Redo") { model.redo() }
                                .disabled(!model.canRedo)
                                .keyboardShortcut("z", modifiers: [.command, .shift])
                        }
                        Menu("Presets") {
                            ForEach(BuiltInPreset.allCases) { preset in
                                Button(preset.rawValue) { model.applyPreset(preset) }
                            }
                            Divider()
                            ForEach(CustomPresetStore.names, id: \.self) { name in
                                if model.customPresetAvailability.contains(name) {
                                    Button(name) { model.applyCustomPreset(name) }
                                } else {
                                    Button("\(name) (empty)") { model.saveCustomPreset(name) }
                                }
                            }
                            Divider()
                            Menu("Save Current As") {
                                ForEach(CustomPresetStore.names, id: \.self) { name in
                                    Button(name) { model.saveCustomPreset(name) }
                                }
                                Divider()
                                Button("New Custom Preset…") { model.beginNewCustomPreset() }
                            }
                            Divider()
                            Button("Export Presets…") { model.exportCustomPresets() }
                            Button("Import Presets…") { model.importCustomPresets() }
                        }
                        if model.photos.count > 1 {
                            Menu("Batch Edit") {
                                Button("Copy Current Adjustments to Selected (\(model.selectedPhotoIndices.count))") {
                                    model.copyCurrentAdjustmentsToSelected()
                                }
                                .disabled(model.selectedPhotoIndices.isEmpty)
                                Menu("Apply Preset to Selected (\(model.selectedPhotoIndices.count))") {
                                    ForEach(BuiltInPreset.allCases) { preset in
                                        Button(preset.rawValue) {
                                            model.applyPresetToSelected(preset)
                                        }
                                    }
                                }
                                .disabled(model.selectedPhotoIndices.isEmpty)
                                Button("Copy Current Adjustments to All") {
                                    model.copyCurrentAdjustmentsToAll()
                                }
                                Divider()
                                ForEach(BuiltInPreset.allCases) { preset in
                                    Button("Apply \(preset.rawValue) to All") {
                                        model.applyPresetToAll(preset)
                                    }
                                }
                            }
                        }

                    Toggle("Watermark", isOn: $model.watermark.enabled)
                    AdjustmentSlider(title: "JPEG Quality", value: Binding(
                        get: { model.exportQuality * 100 },
                        set: { model.exportQuality = $0 / 100 }),
                        range: 10...100, onChange: {})
                    Picker("Max Long Edge", selection: $model.exportMaxLongEdge) {
                        Text("Original").tag(0)
                        Text("1200 px").tag(1200)
                        Text("2400 px").tag(2400)
                        Text("4000 px").tag(4000)
                        Text("6000 px").tag(6000)
                    }
                    Picker("DPI", selection: $model.exportDPI) {
                        Text("72").tag(CGFloat(72))
                        Text("150").tag(CGFloat(150))
                        Text("300").tag(CGFloat(300))
                        Text("600").tag(CGFloat(600))
                    }
                    Toggle("Preserve EXIF", isOn: $model.preserveMetadata)
                    Picker("Appearance", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.rawValue).tag(appearance)
                        }
                    }
                    if model.photos.count > 1 {
                        Picker("Batch Naming", selection: $model.batchExportNaming) {
                            ForEach(BatchExportNaming.allCases) { naming in
                                Text(naming.rawValue).tag(naming)
                            }
                        }
                        Picker("File Conflicts", selection: $model.batchConflictMode) {
                            ForEach(BatchConflictMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }
                    if model.watermark.enabled {
                        TextField("Text", text: $model.watermark.text)
                        Picker("Font", selection: $model.watermark.fontName) {
                            Text("System").tag("System")
                            Text("Helvetica").tag("Helvetica")
                            Text("Arial").tag("Arial")
                            Text("Avenir").tag("Avenir")
                            Text("Georgia").tag("Georgia")
                            Text("Menlo").tag("Menlo")
                        }
                        AdjustmentSlider(title: "Watermark Size", value: Binding(
                            get: { Double(model.watermark.fontSize) },
                            set: { model.watermark.fontSize = CGFloat($0) }),
                            range: 8...160, onChange: {})
                        AdjustmentSlider(title: "Watermark Opacity", value: Binding(
                            get: { Double(model.watermark.opacity * 100) },
                            set: { model.watermark.opacity = CGFloat($0 / 100) }),
                            range: 10...100, onChange: {})
                        AdjustmentSlider(title: "Watermark Margin", value: Binding(
                            get: { Double(model.watermark.margin) },
                            set: { model.watermark.margin = CGFloat($0) }),
                            range: 0...300, onChange: {})
                        Picker("Position", selection: $model.watermark.position) {
                            ForEach(WatermarkPosition.allCases) { position in
                                Text(position.rawValue).tag(position)
                            }
                        }
                        Picker("Color", selection: $model.watermark.color) {
                            ForEach(WatermarkColor.allCases) { color in
                                Text(color.rawValue).tag(color)
                            }
                        }
                    }
                    }
                }
                .padding(20)
                .frame(width: 280)
            }

            if !model.photos.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.photos.enumerated()), id: \.offset) { index, url in
                            VStack(spacing: 2) {
                                Button {
                                    model.selectPhoto(at: index)
                                } label: {
                                    VStack(spacing: 4) {
                                        ThumbnailView(url: url)
                                        Text(url.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .frame(width: 110)
                                    }
                                }
                                .buttonStyle(.plain)
                                Toggle("", isOn: Binding(
                                    get: { model.selectedPhotoIndices.contains(index) },
                                    set: { model.setPhotoSelection(at: index, selected: $0) }
                                ))
                                .labelsHidden()
                            }
                            .padding(5)
                            .background(index == model.selectedIndex ? Color.accentColor.opacity(0.25) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(8)
                }
                .frame(height: 105)
            }
        }
        .alert("無法開啟照片", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知錯誤")
        }
        .sheet(isPresented: $model.showingPresetNameSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Custom Preset")
                    .font(.headline)
                TextField("Preset name", text: $model.presetNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.saveNewCustomPreset() }
                HStack {
                    Spacer()
                    Button("Cancel") { model.showingPresetNameSheet = false }
                    Button("Save") { model.saveNewCustomPreset() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 360)
        }
        .onDisappear {
            model.flushPendingSave()
        }
        .onAppear {
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                let urls = delegate.consumePendingURLs()
                if !urls.isEmpty {
                    model.open(urls: urls)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let path = (object as? NSURL)?.path else { return }
                let url = URL(fileURLWithPath: path)
                Task { @MainActor in
                    model.openDropped(url: url)
                }
            }
            return true
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

private struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 70)
        .clipped()
        .background(Color.secondary.opacity(0.12))
        .task(id: url) {
            image = PhotoThumbnailLoader().load(url: url)
        }
    }
}

struct PhotoThumbnailLoader {
    private let decoder: PhotoDecoder = ApplePhotoDecoder()
    private let renderer = ImageRenderer()

    func load(url: URL) -> NSImage? {
        guard let cgImage = loadCGImage(url: url) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    func loadCGImage(url: URL) -> CGImage? {
        if let cached = PhotoThumbnailCache.shared.image(for: url) {
            return cached
        }
        guard let source = try? decoder.decode(url: url) else { return nil }
        guard let image = renderer.makePreview(source, adjustments: ImageAdjustments(), maxDimension: 220) else { return nil }
        PhotoThumbnailCache.shared.store(image, for: url)
        return image
    }
}

private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) { _ in onChange() }
        }
    }
}
