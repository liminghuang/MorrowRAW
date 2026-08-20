import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorViewModel: ObservableObject, @unchecked Sendable {
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
    @Published var naturalColorSuggestion: NaturalColorSuggestion?
    @Published var referencePhotoName = ""
    @Published var colorScopes = ColorScopeSnapshot.empty
    @Published var semanticRegions: [SemanticRegionSuggestion] = []
    @Published private(set) var isAnalyzingSemanticRegions = false
    @Published var colorCheckerSamples: [ColorCheckerSample] = []
    @Published var colorCheckerPatchIndex = 0
    @Published var colorCheckerProfile: ColorCheckerProfile?
    @Published var sourceName = StudioText.notSelected
    @Published private(set) var previewMaxDimension: CGFloat = 1800
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
    @Published private(set) var folderTotalCount = 0
    @Published private(set) var folderScannedCount = 0
    @Published private(set) var folderScanEntryCount = 0
    @Published private(set) var isLoadingPhoto = false
    @Published private(set) var isPhotoPreviewReady = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSingleExporting = false
    @Published private(set) var exportCompletedCount = 0
    @Published private(set) var exportTotalCount = 0
    @Published private(set) var isBatchAdjusting = false
    @Published private(set) var batchAdjustmentCompleted = 0
    @Published private(set) var batchAdjustmentTotal = 0
    @Published private(set) var recentFolders: [String] = []
    @Published var appearance: AppAppearance = AppAppearance(rawValue:
        UserDefaults.standard.string(forKey: "MorrowRAW.appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "MorrowRAW.appearance") }
    }
    @Published var language: AppLanguage = AppLanguage(rawValue:
        UserDefaults.standard.string(forKey: "MorrowRAW.language") ?? "") ?? .traditionalChinese {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "MorrowRAW.language") }
    }

    private let renderer = ImageRenderer.shared
    private var source: CIImage?
    private var currentPhotoURL: URL?
    var currentFolderURL: URL?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var adjustmentURL: URL?
    private var undoStack: [ImageAdjustments] = []
    private var redoStack: [ImageAdjustments] = []
    private var interactiveHistoryBaseline: ImageAdjustments?
    private var copiedAdjustments: ImageAdjustments?
    private var lastHistoryState = ImageAdjustments()
    private var sourceGeneration = UUID()
    private var cachedOriginalPreview: CGImage?
    private var cachedOriginalPreviewAdjustments: ImageAdjustments?
    private var cachedOriginalPreviewSourceGeneration: UUID?
    private var openURLObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var folderScanTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var thumbnailPresentationTask: Task<Void, Never>?
    private var batchExportTask: Task<Void, Never>?
    private var singleExportTask: Task<Void, Never>?
    private var batchExportCancellation: BatchExportCancellationToken?
    private var batchAdjustmentTask: Task<Void, Never>?
    private var batchAdjustmentCancellation: BatchAdjustmentCancellationToken?
    private var thumbnailPrefetchTask: Task<Void, Never>?
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
            forName: .morrowRAWOpenURL, object: nil, queue: .main
        ) { [weak self] notification in
            guard let urls = notification.object as? [URL] else { return }
            Task { @MainActor [weak self] in
                self?.open(urls: urls)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: .morrowRAWWillTerminate, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingSave()
            }
        }
    }

    deinit {
        folderScanTask?.cancel()
        loadTask?.cancel()
        thumbnailPresentationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        singleExportTask?.cancel()
        batchExportCancellation?.cancel()
        batchExportTask?.cancel()
        batchAdjustmentCancellation?.cancel()
        batchAdjustmentTask?.cancel()
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

        openDropped(url: url)
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
        // This single-URL API is also used by compatibility tests and internal
        // adjustment workflows; retain its synchronous contract. UI entry
        // points use `openDropped`/`open(urls:)`, which decode in background.
        currentFolderURL = nil
        photos = []
        selectedIndex = 0
        selectedPhotoIndices = []
        load(url: url, copyIndex: 0)
    }

    func open(urls: [URL]) {
        open(urls: urls, synchronously: false)
    }

    /// Synchronous multi-photo loading is reserved for deterministic internal
    /// workflows that immediately inspect or write the first photo's state.
    /// Finder, drag-and-drop, and application launch use the async default.
    func openSynchronously(urls: [URL]) {
        open(urls: urls, synchronously: true)
    }

    private func open(urls: [URL], synchronously: Bool) {
        guard !urls.isEmpty else { return }
        if urls.count == 1 {
            if synchronously { open(url: urls[0]) }
            else { openDropped(url: urls[0]) }
            return
        }
        let supported = urls.filter {
            PhotoLibrary.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else {
            errorMessage = StudioText.localized("沒有支援的照片格式", "No supported photo formats")
            return
        }
        photos = supported
        currentFolderURL = nil
        selectedIndex = 0
        selectedPhotoIndices = [0]
        if synchronously {
            load(url: supported[0], copyIndex: 0)
        } else {
            loadInBackground(url: supported[0], copyIndex: 0)
        }
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
            loadInBackground(url: url, copyIndex: 0)
        }
    }

    func selectPhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        selectedIndex = index
        selectedPhotoIndices = [index]
        loadInBackground(url: photos[index], copyIndex: 0)
    }

    func movePhotoSelection(_ direction: MoveCommandDirection) {
        guard !photos.isEmpty else { return }
        let offset: Int
        switch direction {
        case .left: offset = -1
        case .right: offset = 1
        default: return
        }
        let nextIndex = min(max(selectedIndex + offset, 0), photos.count - 1)
        guard nextIndex != selectedIndex else { return }
        selectPhoto(at: nextIndex)
    }

    /// Returns nearby indices in navigation order, excluding the selected
    /// photo itself. Keeping this deterministic also makes prefetch behavior
    /// easy to validate without requiring a real RAW file in tests.
    nonisolated static func nearbyThumbnailIndices(around index: Int, count: Int, radius: Int = 3) -> [Int] {
        guard count > 0, count > 1, radius > 0, index >= 0, index < count else { return [] }
        return (1...radius).flatMap { distance in
            [index + distance, index - distance]
        }.filter { $0 >= 0 && $0 < count }
    }

    nonisolated static func reconciledSelection(preferredURL: URL?, selectedURLs: Set<URL>, in photos: [URL]) -> (index: Int, selected: Set<Int>) {
        guard !photos.isEmpty else { return (0, []) }
        let index = preferredURL.flatMap { photos.firstIndex(of: $0) } ?? 0
        let remapped = Set(selectedURLs.compactMap { selectedURL in
            photos.firstIndex(of: selectedURL)
        })
        return (index, remapped.isEmpty ? [index] : remapped)
    }

    private func prefetchNearbyThumbnails(around index: Int) {
        thumbnailPrefetchTask?.cancel()
        let indices = Self.nearbyThumbnailIndices(around: index, count: photos.count)
        let urls = indices.compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        guard !urls.isEmpty else { return }

        thumbnailPrefetchTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = await PhotoThumbnailLoader.shared.loadCGImageAsync(url: url)
                    }
                }
            }
        }
    }

    func setPhotoSelection(at index: Int, selected: Bool) {
        guard photos.indices.contains(index) else { return }
        if selected {
            selectedPhotoIndices.insert(index)
        } else {
            selectedPhotoIndices.remove(index)
        }
    }

    func selectAllPhotos() {
        selectedPhotoIndices = Set(photos.indices)
    }

    func clearPhotoSelection() {
        selectedPhotoIndices.removeAll()
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
                loadInBackground(url: next, copyIndex: 0)
            } else {
                selectedIndex = 0
                source = nil
                preview = nil
                isPhotoPreviewReady = false
                histogram = []
                rgbHistogram = .empty
                currentPhotoURL = nil
                sourceName = StudioText.noDisplayablePhotos
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
            isPhotoPreviewReady = false
            histogram = []
            rgbHistogram = .empty
            currentPhotoURL = nil
            sourceName = StudioText.noDisplayablePhotos
            return
        }
        selectedIndex = min(selectedIndex, scanned.count - 1)
        loadInBackground(url: scanned[selectedIndex], copyIndex: 0)
    }

    private func load(url: URL, copyIndex: Int = 0) {
        activeLoadID = UUID()
        saveCurrentAdjustments()
        saveTask?.cancel()
        renderTask?.cancel()
        loadTask?.cancel()
        thumbnailPresentationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        preview = nil
        beforeAfterOriginalPreview = nil
        beforeAfterEnabled = false
        histogram = []
        rgbHistogram = .empty
        isLoadingPhoto = false
        isPhotoPreviewReady = false
        source = nil
        preparePhotoState(for: url, copyIndex: copyIndex)
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
        renderTask?.cancel()
        loadTask?.cancel()
        thumbnailPresentationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        preview = nil
        beforeAfterOriginalPreview = nil
        beforeAfterEnabled = false
        histogram = []
        rgbHistogram = .empty
        source = nil
        preparePhotoState(for: url, copyIndex: copyIndex)
        sourceName = url.lastPathComponent
        isLoadingPhoto = true
        isPhotoPreviewReady = false
        let loadID = UUID()
        activeLoadID = loadID
        loadTask = Task { [weak self] in
            let thumbnailTask = Task.detached(priority: .utility) {
                await PhotoThumbnailLoader.shared.loadCGImageAsync(url: url)
            }
            self?.thumbnailPresentationTask = Task { @MainActor [weak self] in
                let thumbnail = await withTaskCancellationHandler(operation: {
                    await thumbnailTask.value
                }, onCancel: {
                    thumbnailTask.cancel()
                })
                guard !Task.isCancelled,
                      let self,
                      self.activeLoadID == loadID,
                      self.isLoadingPhoto else { return }
                self.preview = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
                self.isPhotoPreviewReady = thumbnail != nil
            }
            do {
                let imageTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try ApplePhotoDecoder().decode(url: url)
                }
                let image = try await withTaskCancellationHandler(operation: {
                    try await imageTask.value
                }, onCancel: {
                    imageTask.cancel()
                })
                let exifTask = Task.detached(priority: .utility) { () -> ExifData? in
                    guard !Task.isCancelled else { return nil }
                    return PhotoMetadataReader.read(url: url)
                }
                let exif = await withTaskCancellationHandler(operation: {
                    await exifTask.value
                }, onCancel: {
                    exifTask.cancel()
                })
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
        errorMessage = nil
        naturalColorSuggestion = nil
        referencePhotoName = ""
        colorScopes = .empty
        semanticRegions = []
        colorCheckerSamples = []
        colorCheckerPatchIndex = 0
        colorCheckerProfile = nil
        source = image
        sourceGeneration = UUID()
        cachedOriginalPreview = nil
        cachedOriginalPreviewAdjustments = nil
        cachedOriginalPreviewSourceGeneration = nil
        currentPhotoURL = url
        virtualCopyIndex = copyIndex
        sourceName = url.lastPathComponent
        showOriginal = false
        let xmlURL = adjustmentURL(for: url, copyIndex: copyIndex)
        adjustmentURL = xmlURL
        if adjustments.cachedExif == nil {
            adjustments.cachedExif = exif
        }
        scheduleRender()
        prefetchNearbyThumbnails(around: selectedIndex)
    }

    /// Loads the editable sidecar state before decoding the RAW itself. This
    /// lets slider changes made while the photo is loading survive until the
    /// source image arrives and are rendered immediately afterwards.
    private func preparePhotoState(for url: URL, copyIndex: Int) {
        let xmlURL = adjustmentURL(for: url, copyIndex: copyIndex)
        var nextAdjustments = ImageAdjustments()
        do {
            if FileManager.default.fileExists(atPath: xmlURL.path) {
                try nextAdjustments.load(from: xmlURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        adjustments = nextAdjustments
        naturalColorSuggestion = nil
        referencePhotoName = ""
        colorScopes = .empty
        semanticRegions = []
        colorCheckerSamples = []
        colorCheckerPatchIndex = 0
        colorCheckerProfile = nil
        adjustmentURL = xmlURL
        currentPhotoURL = url
        virtualCopyIndex = copyIndex
        customCropRatio = ["Original", "3:2", "4:3", "16:9", "1:1"].contains(adjustments.cropAspectRatio)
            ? customCropRatio
            : adjustments.cropAspectRatio
        undoStack.removeAll()
        redoStack.removeAll()
        interactiveHistoryBaseline = nil
        lastHistoryState = adjustments
    }

    private func startFolderScan(_ folder: URL) {
        folderScanTask?.cancel()
        let scanID = UUID()
        folderScanID = scanID
        isLoadingFolder = true
        folderLoadCount = 0
        folderTotalCount = 0
        folderScannedCount = 0
        folderScanEntryCount = 0
        photos = []
        selectedIndex = 0
        selectedPhotoIndices = []
        let includeHidden = showHiddenPhotos
        let model = self
        let scanProgressGate = ProgressUpdateGate()
        folderScanTask = Task.detached(priority: .userInitiated) {
            let scanned = PhotoLibrary.scanIncrementally(folder: folder, includeHidden: includeHidden, rawOnly: true,
                                                         batchSize: 64,
                                                         onTotal: { total in
                Task { @MainActor in
                    guard model.folderScanID == scanID, model.isLoadingFolder else { return }
                    model.folderTotalCount = total
                }
            }, onScanProgress: { scanned, total in
                guard scanProgressGate.shouldPublish(completed: scanned, total: total) else { return }
                Task { @MainActor in
                    guard model.folderScanID == scanID, model.isLoadingFolder else { return }
                    model.folderScannedCount = scanned
                    model.folderScanEntryCount = total
                }
            }, shouldCancel: {
                Task.isCancelled
            }, onBatch: { batch in
                Task { @MainActor in
                    guard model.folderScanID == scanID, model.isLoadingFolder else { return }
                    model.photos.append(contentsOf: batch)
                    model.folderLoadCount = model.photos.count
                    if model.photos.count == batch.count, let first = batch.first {
                        model.selectedIndex = 0
                        model.selectedPhotoIndices = [0]
                        model.loadInBackground(url: first, copyIndex: 0)
                    }
                }
            })
            await MainActor.run {
                guard model.folderScanID == scanID else { return }
                let preferredURL = model.photos.indices.contains(model.selectedIndex)
                    ? model.photos[model.selectedIndex]
                    : model.currentPhotoURL
                let selectedURLs = Set(model.selectedPhotoIndices.compactMap { index in
                    model.photos.indices.contains(index) ? model.photos[index] : nil
                })
                model.folderScanTask = nil
                model.isLoadingFolder = false
                model.photos = scanned
                if !scanned.isEmpty {
                    let selection = Self.reconciledSelection(
                        preferredURL: preferredURL,
                        selectedURLs: selectedURLs,
                        in: scanned
                    )
                    model.selectedIndex = selection.index
                    model.selectedPhotoIndices = selection.selected
                    let selected = scanned[selection.index]
                    if model.currentPhotoURL != selected && !model.isLoadingPhoto {
                        model.loadInBackground(url: selected, copyIndex: 0)
                    }
                }
                if scanned.isEmpty {
                    model.errorMessage = StudioText.localized("資料夾中沒有支援的照片格式", "No supported photo formats in this folder")
                }
            }
        }
    }

    func cancelFolderLoading() {
        folderScanID = UUID()
        folderScanTask?.cancel()
        loadTask?.cancel()
        thumbnailPresentationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        renderTask?.cancel()
        folderScanTask = nil
        isLoadingFolder = false
        photos = []
        selectedPhotoIndices = []
        isLoadingPhoto = false
        isPhotoPreviewReady = false
        folderTotalCount = 0
        folderScannedCount = 0
        folderScanEntryCount = 0
    }

    private func prepareForFolderChange(to folder: URL) {
        saveCurrentAdjustments()
        renderTask?.cancel()
        thumbnailPresentationTask?.cancel()
        thumbnailPrefetchTask?.cancel()
        currentFolderURL = folder
        photos = []
        selectedIndex = 0
        selectedPhotoIndices = []
        virtualCopyIndex = 0
        adjustments = ImageAdjustments()
        naturalColorSuggestion = nil
        referencePhotoName = ""
        colorScopes = .empty
        semanticRegions = []
        colorCheckerSamples = []
        colorCheckerPatchIndex = 0
        colorCheckerProfile = nil
        preview = nil
        histogram = []
        rgbHistogram = .empty
        source = nil
        sourceGeneration = UUID()
        cachedOriginalPreview = nil
        cachedOriginalPreviewAdjustments = nil
        cachedOriginalPreviewSourceGeneration = nil
        currentPhotoURL = nil
        adjustmentURL = nil
        sourceName = StudioText.notSelected
        showOriginal = false
        undoStack.removeAll()
        redoStack.removeAll()
        lastHistoryState = adjustments
    }

    func scheduleRender() {
        scheduleRender(recordHistory: true)
    }

    /// Keeps preview work proportional to the visible canvas. A small window
    /// should not render a fixed 1800px image, while a large Retina canvas
    /// benefits from a little more detail. The bounds prevent resize events
    /// from creating either tiny blurry previews or excessive GPU work.
    func updatePreviewViewport(_ size: CGSize) {
        let longestEdge = max(size.width, size.height)
        guard longestEdge.isFinite, longestEdge > 0 else { return }
        let target = min(2400, max(900, (longestEdge * 2).rounded()))
        guard abs(target - previewMaxDimension) >= 128 else { return }
        previewMaxDimension = target
        if source != nil { scheduleRender(recordHistory: false) }
    }

    func scheduleRender(recordHistory: Bool) {
        // User-driven edits take priority over nearby-thumbnail prefetching.
        // The prefetch will restart when the next photo finishes loading.
        thumbnailPrefetchTask?.cancel()
        renderTask?.cancel()
        guard let source else { return }
        if recordHistory { recordHistoryIfNeeded() }
        let current = showOriginal ? originalPreviewAdjustments() : adjustments
        let editedAdjustments = adjustments
        let compare = beforeAfterEnabled && !showOriginal
        let originalAdjustments = originalPreviewAdjustments()
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            guard let interactivePair = await self.renderPreviewPair(
                source: source,
                editedAdjustments: compare ? editedAdjustments : current,
                originalAdjustments: originalAdjustments,
                compare: compare,
                quality: .interactive
            ) else { return }
            guard !Task.isCancelled, let interactivePreview = interactivePair.0 else { return }
            self.preview = NSImage(cgImage: interactivePreview, size: .zero)
            self.beforeAfterOriginalPreview = interactivePair.1.map { NSImage(cgImage: $0, size: .zero) }
            if self.interactiveHistoryBaseline == nil {
                let interactiveHistogram = await Task.detached(priority: .utility) {
                    HistogramCalculator.snapshot(for: interactivePreview)
                }.value
                guard !Task.isCancelled else { return }
                self.histogram = interactiveHistogram.luminance
                self.rgbHistogram = interactiveHistogram.rgb
            }

            // During a slider drag, keep only the responsive preview active.
            // finishInteractiveAdjustment() schedules the full refinement once
            // the drag ends, so a brief pause cannot start an expensive render
            // that competes with the next slider event.
            guard self.interactiveHistoryBaseline == nil else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let cachedOriginal = compare &&
                self.cachedOriginalPreviewSourceGeneration == self.sourceGeneration &&
                self.cachedOriginalPreviewAdjustments == originalAdjustments
                ? self.cachedOriginalPreview : nil
            guard let finalPair = await self.renderPreviewPair(
                source: source,
                editedAdjustments: compare ? editedAdjustments : current,
                originalAdjustments: originalAdjustments,
                compare: compare,
                quality: .finalPreview,
                cachedOriginal: cachedOriginal
            ) else { return }
            guard !Task.isCancelled, let finalPreview = finalPair.0 else { return }
            self.preview = NSImage(cgImage: finalPreview, size: .zero)
            self.beforeAfterOriginalPreview = finalPair.1.map { NSImage(cgImage: $0, size: .zero) }
            if compare, let original = finalPair.1 {
                self.cachedOriginalPreview = original
                self.cachedOriginalPreviewAdjustments = originalAdjustments
                self.cachedOriginalPreviewSourceGeneration = self.sourceGeneration
            }
            if self.interactiveHistoryBaseline == nil {
                let finalHistogram = await Task.detached(priority: .utility) {
                    HistogramCalculator.snapshot(for: finalPreview)
                }.value
                guard !Task.isCancelled else { return }
                self.histogram = finalHistogram.luminance
                self.rgbHistogram = finalHistogram.rgb
            }
        }

        saveTask?.cancel()
        let savedAdjustments = adjustments
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? savedAdjustments.save(to: self?.adjustmentURL ?? URL(fileURLWithPath: "/dev/null"))
        }
    }

    func beginInteractiveAdjustment() {
        if interactiveHistoryBaseline == nil {
            interactiveHistoryBaseline = adjustments
        }
    }

    private func renderPreviewPair(source: CIImage,
                                   editedAdjustments: ImageAdjustments,
                                   originalAdjustments: ImageAdjustments,
                                   compare: Bool,
                                   quality: RenderQuality,
                                   cachedOriginal: CGImage? = nil) async -> (CGImage?, CGImage?)? {
        guard await PreviewRenderGate.shared.acquire() else { return nil }
        guard !Task.isCancelled else {
            await PreviewRenderGate.shared.release()
            return nil
        }
        let maxDimension = previewMaxDimension
        let pair = await Task.detached(priority: .userInitiated) {
            let renderer = ImageRenderer.shared
            let edited = await renderer.makePreviewAsync(
                source, adjustments: editedAdjustments,
                maxDimension: maxDimension, quality: quality
            )
            let original: CGImage?
            if !compare {
                original = nil
            } else if let cachedOriginal {
                original = cachedOriginal
            } else {
                original = await renderer.makePreviewAsync(
                    source, adjustments: originalAdjustments,
                    maxDimension: maxDimension, quality: quality
                )
            }
            return (edited, original)
        }.value
        await PreviewRenderGate.shared.release()
        return pair
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
        neutral.adjustmentBrushes.removeAll()
        neutral.healSpots.removeAll()
        return neutral
    }

    func export(format: ImageExportFormat) {
        guard let source, !isExporting, !isSingleExporting, !isBatchAdjusting else { return }
        saveCurrentAdjustments()
        saveExportPreferences()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = URL(fileURLWithPath: sourceName)
            .deletingPathExtension().lastPathComponent + "_edited." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let currentAdjustments = adjustments
        let quality = exportQuality
        let maxLongEdge = exportMaxLongEdge > 0 ? exportMaxLongEdge : nil
        let sourceURL = currentPhotoURL
        let dpi = exportDPI
        let preserveMetadata = preserveMetadata
        let watermark = watermark
        isSingleExporting = true
        singleExportTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageExporter().export(source: source, adjustments: currentAdjustments,
                                                to: url, format: format, quality: quality,
                                                maxLongEdge: maxLongEdge, sourceURL: sourceURL,
                                                dpi: dpi, preserveMetadata: preserveMetadata,
                                                watermark: watermark)
                }.value
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }
            self?.isSingleExporting = false
            self?.singleExportTask = nil
        }
    }

    func exportAll(format: ImageExportFormat) {
        guard !isExporting, !isSingleExporting, !isBatchAdjusting else { return }
        let exportURLs = PhotoLibrary.exportable(photos, from: currentFolderURL)
        guard !exportURLs.isEmpty else {
            errorMessage = StudioText.localized("沒有可匯出的照片", "No photos available for export")
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

        let cancellation = BatchExportCancellationToken()
        batchExportCancellation = cancellation
        isExporting = true
        exportCompletedCount = 0
        exportTotalCount = exportURLs.count
        let quality = exportQuality
        let maxLongEdge = exportMaxLongEdge > 0 ? exportMaxLongEdge : nil
        let dpi = exportDPI
        let preserveMetadata = preserveMetadata
        let naming = batchExportNaming
        let conflict = batchConflictMode
        let watermark = watermark
        let progressGate = ProgressUpdateGate()

        batchExportTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                try? ImageBatchExporter().export(
                    urls: exportURLs, to: folder, format: format,
                    quality: quality, maxLongEdge: maxLongEdge, dpi: dpi,
                    preserveMetadata: preserveMetadata, naming: naming,
                    conflict: conflict, watermark: watermark,
                    onProgress: { completed, total in
                        guard progressGate.shouldPublish(completed: completed, total: total) else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.isExporting else { return }
                            self.exportCompletedCount = completed
                            self.exportTotalCount = total
                        }
                    },
                    shouldCancel: { cancellation.isCancelled }
                )
            }.value

            guard let self else { return }
            self.isExporting = false
            self.batchExportCancellation = nil
            self.batchExportTask = nil
            guard let result else {
                self.errorMessage = StudioText.localized("批次匯出失敗", "Batch export failed")
                return
            }
            if result.cancelled {
                self.errorMessage = StudioText.localized(
                    "已取消匯出（已完成 \(result.writtenURLs.count) 張）",
                    "Export cancelled (\(result.writtenURLs.count) completed)"
                )
            } else if !result.failures.isEmpty {
                self.errorMessage = StudioText.localized(
                    "已匯出 \(result.writtenURLs.count) 張，\(result.failures.count) 張失敗",
                    "Exported \(result.writtenURLs.count); \(result.failures.count) failed"
                )
            }
        }
    }

    func cancelBatchExport() {
        guard isExporting else { return }
        batchExportCancellation?.cancel()
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
            errorMessage = StudioText.localized("裁切比例格式應為寬:高，例如 5:4", "Crop ratio must be width:height, for example 5:4")
            return
        }
        adjustments.cropAspectRatio = "\(components[0]):\(components[1])"
        scheduleRender()
    }

    func resetAllAdjustments() {
        adjustments = ImageAdjustments()
        naturalColorSuggestion = nil
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
        startBatchAdjustment(urls: photos, operation: .preset(preset))
    }

    func applyPresetToSelected(_ preset: BuiltInPreset) {
        let targets = selectedPhotoIndices
            .sorted()
            .compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        let exportableTargets = PhotoLibrary.exportable(targets, from: currentFolderURL)
        guard !exportableTargets.isEmpty else { return }
        startBatchAdjustment(urls: exportableTargets, operation: .preset(preset))
    }

    func copyCurrentAdjustmentsToAll() {
        guard photos.count > 1 else { return }
        startBatchAdjustment(urls: photos, operation: .copy(adjustments))
    }

    func copyCurrentAdjustmentsToSelected() {
        let targets = selectedPhotoIndices
            .sorted()
            .compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        let exportableTargets = PhotoLibrary.exportable(targets, from: currentFolderURL)
        guard !exportableTargets.isEmpty else { return }
        startBatchAdjustment(urls: exportableTargets, operation: .copy(adjustments))
    }

    private enum BatchAdjustmentOperation: @unchecked Sendable {
        case preset(BuiltInPreset)
        case copy(ImageAdjustments)
    }

    private func startBatchAdjustment(urls: [URL], operation: BatchAdjustmentOperation) {
        guard !urls.isEmpty, !isBatchAdjusting else { return }
        saveCurrentAdjustments()
        batchAdjustmentCancellation?.cancel()
        let cancellation = BatchAdjustmentCancellationToken()
        batchAdjustmentCancellation = cancellation
        isBatchAdjusting = true
        batchAdjustmentCompleted = 0
        batchAdjustmentTotal = urls.count
        let progressTarget = self
        let progressGate = ProgressUpdateGate()

        batchAdjustmentTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let progress: @Sendable (Int, Int) -> Void = { completed, total in
                    guard progressGate.shouldPublish(completed: completed, total: total) else { return }
                    Task { @MainActor [weak progressTarget] in
                        guard let progressTarget, progressTarget.isBatchAdjusting else { return }
                        progressTarget.batchAdjustmentCompleted = completed
                        progressTarget.batchAdjustmentTotal = total
                    }
                }
                switch operation {
                case .preset(let preset):
                    return BatchAdjustmentService.applyPreset(
                        preset, to: urls,
                        shouldCancel: { cancellation.isCancelled },
                        onProgress: progress
                    )
                case .copy(let source):
                    return BatchAdjustmentService.copy(
                        source, to: urls,
                        shouldCancel: { cancellation.isCancelled },
                        onProgress: progress
                    )
                }
            }.value

            guard let self, self.isBatchAdjusting else { return }
            self.isBatchAdjusting = false
            self.batchAdjustmentCancellation = nil
            self.batchAdjustmentTask = nil
            if self.photos.indices.contains(self.selectedIndex) {
                self.loadInBackground(url: self.photos[self.selectedIndex], copyIndex: self.virtualCopyIndex)
            }
            if result.cancelled {
                self.errorMessage = StudioText.localized(
                    "批次調整已取消，已更新 \(result.updatedCount) 張",
                    "Batch adjustment cancelled; \(result.updatedCount) updated"
                )
            } else if result.failureCount > 0 {
                self.errorMessage = StudioText.localized(
                    "已更新 \(result.updatedCount) 張，\(result.failureCount) 張失敗",
                    "Updated \(result.updatedCount); \(result.failureCount) failed"
                )
            }
        }
    }

    func cancelBatchAdjustment() {
        guard isBatchAdjusting else { return }
        batchAdjustmentCancellation?.cancel()
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

    func suggestNaturalColor() {
        guard let preview,
              let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = StudioText.localized("請先開啟可預覽的照片", "Open a photo with a preview first")
            return
        }
        colorScopes = ColorScopeCalculator.snapshot(for: image)
        naturalColorSuggestion = NaturalColorAssistant.suggest(for: image)
    }

    func refreshColorScopes() {
        guard let preview,
              let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        colorScopes = ColorScopeCalculator.snapshot(for: image)
    }

    func analyzeSemanticRegions() {
        guard !isAnalyzingSemanticRegions,
              let preview,
              let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        isAnalyzingSemanticRegions = true
        let model = self
        let generation = sourceGeneration
        Task.detached(priority: .userInitiated) {
            let regions = SemanticMaskAnalyzer.detect(in: image)
            await MainActor.run {
                guard model.sourceGeneration == generation else {
                    model.isAnalyzingSemanticRegions = false
                    return
                }
                model.semanticRegions = regions
                model.isAnalyzingSemanticRegions = false
            }
        }
    }

    func applySemanticRegion(_ region: SemanticRegionSuggestion) {
        guard region.points.count >= 3 else { return }
        var brush = AdjustmentBrush(points: region.points)
        brush.radiusNorm = 0.045
        brush.feather = 0.8
        adjustments.adjustmentBrushes.append(brush)
        scheduleRender()
    }

    func startColorCheckerCalibration() {
        colorCheckerSamples = []
        colorCheckerPatchIndex = 0
        colorCheckerProfile = nil
    }

    func captureColorCheckerSample(at point: CGPoint) {
        guard colorCheckerPatchIndex < ColorCheckerProfile.classicReferenceRGB.count,
              let preview,
              let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let measured = ColorCheckerProfile.sampleRGB(from: image, normalizedPoint: point) else { return }
        let reference = ColorCheckerProfile.classicReferenceRGB[colorCheckerPatchIndex]
        colorCheckerSamples.append(ColorCheckerSample(measured: measured, reference: reference))
        colorCheckerPatchIndex += 1
        if colorCheckerSamples.count == ColorCheckerProfile.classicReferenceRGB.count {
            finishColorCheckerCalibration()
        }
    }

    func finishColorCheckerCalibration() {
        guard let profile = ColorCheckerProfile.calibrate(samples: colorCheckerSamples) else {
            errorMessage = StudioText.localized("至少需要 3 個有效色卡樣本", "At least 3 valid chart samples are required")
            return
        }
        beginInteractiveAdjustment()
        adjustments.colorProfileMatrix = profile.matrix
        colorCheckerProfile = profile
        finishInteractiveAdjustment()
    }

    func applyNaturalColorSuggestion() {
        guard let suggestion = naturalColorSuggestion, suggestion.hasChanges else { return }
        beginInteractiveAdjustment()
        adjustments = suggestion.applying(to: adjustments)
        finishInteractiveAdjustment()
    }

    func clearNaturalColorSuggestion() {
        naturalColorSuggestion = nil
        referencePhotoName = ""
    }

    func matchReferencePhoto() {
        guard preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
            errorMessage = StudioText.localized("請先開啟可預覽的照片", "Open a photo with a preview first")
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let currentImage = preview?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let sourceName = url.lastPathComponent
        let model = self
        let generation = sourceGeneration
        Task.detached(priority: .userInitiated) {
            guard let reference = try? ApplePhotoDecoder().decodePreview(url: url, maxDimension: 720),
                  let referenceImage = ImageRenderer.shared.makePreview(reference, adjustments: ImageAdjustments(), maxDimension: 720) else { return }
            let suggestion = ReferenceColorMatcher.suggestion(source: currentImage, reference: referenceImage)
            await MainActor.run {
                guard model.sourceGeneration == generation else { return }
                model.naturalColorSuggestion = suggestion
                model.referencePhotoName = sourceName
            }
        }
    }

    func removeLastGradient() {
        guard !adjustments.gradients.isEmpty else { return }
        adjustments.gradients.removeLast()
        scheduleRender()
    }

    func beginAdjustmentBrush(at point: CGPoint) {
        let x = min(1, max(0, point.x))
        let y = min(1, max(0, point.y))
        beginInteractiveAdjustment()
        var brush = adjustments.adjustmentBrushes.last ?? AdjustmentBrush()
        brush.points = [AdjustmentBrushPoint(x: x, y: y)]
        adjustments.adjustmentBrushes.append(brush)
        scheduleRender(recordHistory: false)
    }

    func appendAdjustmentBrushPoint(_ point: CGPoint) {
        guard !adjustments.adjustmentBrushes.isEmpty else { return }
        let x = min(1, max(0, point.x))
        let y = min(1, max(0, point.y))
        guard let last = adjustments.adjustmentBrushes.indices.last else { return }
        let previous = adjustments.adjustmentBrushes[last].points.last
        guard previous?.x != x || previous?.y != y else { return }
        adjustments.adjustmentBrushes[last].points.append(AdjustmentBrushPoint(x: x, y: y))
        scheduleRender(recordHistory: false)
    }

    func removeLastAdjustmentBrush() {
        guard !adjustments.adjustmentBrushes.isEmpty else { return }
        adjustments.adjustmentBrushes.removeLast()
        scheduleRender()
    }

    func clearAdjustmentBrushes() {
        guard !adjustments.adjustmentBrushes.isEmpty else { return }
        adjustments.adjustmentBrushes.removeAll()
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
        scheduleRender(recordHistory: false)
    }

    func finishInteractiveAdjustment() {
        let wasInteractive = interactiveHistoryBaseline != nil
        if let baseline = interactiveHistoryBaseline {
            if baseline != adjustments {
                undoStack.append(baseline)
                redoStack.removeAll()
                lastHistoryState = adjustments
                trimUndoHistory()
            }
            interactiveHistoryBaseline = nil
        } else {
            recordHistoryIfNeeded()
        }
        if wasInteractive {
            scheduleRender(recordHistory: false)
        }
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
        scheduleRender(recordHistory: false)
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
        trimUndoHistory()
    }

    private func trimUndoHistory() {
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
            .onMoveCommand { direction in
                model.movePhotoSelection(direction)
            }
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
                                     range: StudioAdjustmentRange.contrast, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Highlights", value: $model.adjustments.highlights,
                                     range: StudioAdjustmentRange.highlights, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Shadows", value: $model.adjustments.shadows,
                                     range: StudioAdjustmentRange.shadows, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Whites", value: $model.adjustments.whites,
                                     range: StudioAdjustmentRange.whites, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Blacks", value: $model.adjustments.blacks,
                                     range: StudioAdjustmentRange.blacks, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Temperature", value: $model.adjustments.temperature,
                                     range: 2000...12000, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Tint", value: $model.adjustments.tint,
                                     range: StudioAdjustmentRange.tint, onChange: model.scheduleRender)
                    Button(model.whiteBalancePickerEnabled ? "Click image to sample…" : "White Balance Picker") {
                        model.toggleWhiteBalancePicker()
                    }
                    AdjustmentSlider(title: "Saturation", value: $model.adjustments.saturation,
                                     range: StudioAdjustmentRange.saturation, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Vibrance", value: $model.adjustments.vibrance,
                                     range: StudioAdjustmentRange.vibrance, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Sharpening", value: $model.adjustments.sharpening,
                                     range: StudioAdjustmentRange.sharpening, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Noise Reduction", value: $model.adjustments.noiseReduction,
                                     range: 0...100, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Vignette", value: $model.adjustments.vignette,
                                     range: StudioAdjustmentRange.vignette, onChange: model.scheduleRender)
                    AdjustmentSlider(title: "Distortion", value: $model.adjustments.distortion,
                                     range: StudioAdjustmentRange.distortion, onChange: model.scheduleRender)

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
                                         range: StudioAdjustmentRange.contrast, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Highlights",
                                         value: $model.adjustments.gradients[index].highlights,
                                         range: StudioAdjustmentRange.highlights, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Shadows",
                                         value: $model.adjustments.gradients[index].shadows,
                                         range: StudioAdjustmentRange.shadows, onChange: model.scheduleRender)
                        AdjustmentSlider(title: "Gradient Saturation",
                                         value: $model.adjustments.gradients[index].saturation,
                                         range: StudioAdjustmentRange.saturation, onChange: model.scheduleRender)
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
                                Button(preset.displayName) { model.applyPreset(preset) }
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
                                        Button(preset.displayName) {
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
                                    Button("Apply \(preset.displayName) to All") {
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
                        ForEach(Array(model.photos.enumerated()), id: \.element) { index, url in
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
    @State private var isLoading = false

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
        .overlay {
            if isLoading { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            isLoading = true
            let cgImage: CGImage? = await withTaskCancellationHandler(operation: {
                await PhotoThumbnailLoader.shared.loadCGImageAsync(url: url)
            }, onCancel: {
                Task { @MainActor in isLoading = false }
            })
            guard !Task.isCancelled else { return }
            image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
            isLoading = false
        }
    }
}

final class PhotoThumbnailLoader {
    static let shared = PhotoThumbnailLoader()

    private let decoder: PhotoDecoder = ApplePhotoDecoder()
    private let renderer = ImageRenderer.shared
    private let inFlight = ThumbnailDecodeCoordinator()

    func load(url: URL) -> NSImage? {
        guard let cgImage = loadCGImage(url: url) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    func loadCGImage(url: URL) -> CGImage? {
        if let cached = PhotoThumbnailCache.shared.image(for: url) {
            return cached
        }
        // Camera RAW files commonly contain an embedded JPEG preview. Reading
        // it through ImageIO avoids constructing a Core Image RAW graph just
        // to paint the first thumbnail in the main canvas.
        if let embedded = Self.loadEmbeddedThumbnail(url: url) {
            PhotoThumbnailCache.shared.store(embedded, for: url)
            return embedded
        }
        guard let source = try? decoder.decodePreview(url: url, maxDimension: 220) else { return nil }
        guard let image = renderer.makePreview(source, adjustments: ImageAdjustments(), maxDimension: 220) else { return nil }
        PhotoThumbnailCache.shared.store(image, for: url)
        return image
    }

    func loadCGImageAsync(url: URL) async -> CGImage? {
        await inFlight.image(for: url) { [decoder, renderer] in
            if let embedded = Self.loadEmbeddedThumbnail(url: url) {
                PhotoThumbnailCache.shared.store(embedded, for: url)
                return embedded
            }
            guard let source = try? decoder.decodePreview(url: url, maxDimension: 220),
                  let image = renderer.makePreview(source, adjustments: ImageAdjustments(), maxDimension: 220)
            else { return nil }
            PhotoThumbnailCache.shared.store(image, for: url)
            return image
        }
    }

    private static func loadEmbeddedThumbnail(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let isRaw = PhotoLibrary.supportedExtensions.contains(url.pathExtension.lowercased()) &&
            !["jpg", "jpeg", "png", "tif", "tiff", "bmp", "heic"].contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !isRaw,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 220
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Shares a thumbnail decode while multiple SwiftUI cells request the same
/// file during list virtualization or rapid scrolling.
actor ThumbnailDecodeCoordinator {
    private struct Entry {
        let id: UUID
        let task: Task<CGImage?, Never>
        var waiters: Int
        var completed: Bool
    }

    private var tasks: [String: Entry] = [:]

    func image(for url: URL, operation: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        let key = PhotoFileFingerprint.key(for: url)
        let entry: Entry
        if var existing = tasks[key] {
            existing.waiters += 1
            tasks[key] = existing
            entry = existing
        } else {
            let taskID = UUID()
            let task: Task<CGImage?, Never> = Task.detached(priority: .utility) {
                guard await ThumbnailDecodeGate.shared.acquire() else { return nil }
                defer {
                    Task { await ThumbnailDecodeGate.shared.release() }
                }
                let signpostID = MorrowPerformanceLog.begin("Thumbnail decode")
                defer { MorrowPerformanceLog.end("Thumbnail decode", id: signpostID) }
                // ImageIO/Core Image may create autoreleased intermediates while
                // decoding RAW previews. Release those per job so rapid filmstrip
                // scrolling does not retain one batch of intermediates for the
                // lifetime of the utility task.
                return autoreleasepool(invoking: operation)
            }
            let created = Entry(id: taskID, task: task, waiters: 1, completed: false)
            tasks[key] = created
            entry = created
            Task { [self] in
                _ = await task.value
                markCompleted(key: key, id: taskID)
            }
        }

        let result = await awaitCancellable(entry.task)
        releaseWaiter(key: key, id: entry.id)
        return result
    }

    private func markCompleted(key: String, id: UUID) {
        guard var entry = tasks[key], entry.id == id else { return }
        entry.completed = true
        if entry.waiters == 0 {
            tasks[key] = nil
        } else {
            tasks[key] = entry
        }
    }

    private func releaseWaiter(key: String, id: UUID) {
        guard var entry = tasks[key], entry.id == id else { return }
        entry.waiters = max(0, entry.waiters - 1)
        if entry.waiters == 0 {
            tasks[key] = nil
            if !entry.completed {
                entry.task.cancel()
            }
        } else {
            tasks[key] = entry
        }
    }

    private func awaitCancellable(_ task: Task<CGImage?, Never>) async -> CGImage? {
        let waiter = ThumbnailResultWaiter()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled {
                    waiter.resume(nil)
                    return
                }
                Task {
                    waiter.resume(await task.value)
                }
            }
        }, onCancel: {
            waiter.resume(nil)
        })
    }
}

private final class ThumbnailResultWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: CGImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
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
