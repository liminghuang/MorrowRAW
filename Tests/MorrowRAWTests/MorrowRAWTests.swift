import Foundation
import CoreImage
import ImageIO
import XCTest
@testable import MorrowRAW

private final class LockedScanResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTotal = -1
    private var storedBatches: [[String]] = []
    private var storedScanned: [Int] = []

    func setTotal(_ total: Int) {
        lock.lock()
        storedTotal = total
        lock.unlock()
    }

    func appendBatch(_ batch: [String]) {
        lock.lock()
        storedBatches.append(batch)
        lock.unlock()
    }

    func appendScanProgress(_ scanned: Int) {
        lock.lock()
        storedScanned.append(scanned)
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTotal
    }

    var batches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedBatches
    }

    var scanned: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedScanned
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class CompatibilityTests: XCTestCase {
    func testAdjustmentSliderRangesFavorFineControlWithoutChangingPersistedDomain() {
        XCTAssertEqual(StudioAdjustmentRange.contrast, -50...50)
        XCTAssertEqual(StudioAdjustmentRange.highlights, -75...75)
        XCTAssertEqual(StudioAdjustmentRange.shadows, -75...75)
        XCTAssertEqual(StudioAdjustmentRange.whites, -50...50)
        XCTAssertEqual(StudioAdjustmentRange.blacks, -50...50)
        XCTAssertEqual(StudioAdjustmentRange.vibrance, -50...50)
        XCTAssertEqual(StudioAdjustmentRange.saturation, -100...100)
        XCTAssertEqual(StudioAdjustmentRange.sharpening, 0...100)

        var adjustments = ImageAdjustments()
        adjustments.contrast = 100
        adjustments.vibrance = -100
        XCTAssertEqual(adjustments.contrast, 100)
        XCTAssertEqual(adjustments.vibrance, -100)
    }

    func testDisplayDateUsesCalendarDateWithSlashSeparators() {
        XCTAssertEqual(PhotoMetadataReader.displayDate("2026:08:16 13:45:20"), "2026/08/16 13:45:20")
        XCTAssertEqual(PhotoMetadataReader.displayDate("2026-08-16"), "2026/08/16")
    }

    @MainActor
    func testZoomControlsChangeScaleWithinExpectedBounds() {
        let model = EditorViewModel()
        model.zoomIn()
        XCTAssertEqual(model.zoomScale, 1.25, accuracy: 0.0001)
        model.zoomOut()
        XCTAssertEqual(model.zoomScale, 1.0, accuracy: 0.0001)
        model.zoomScale = 4
        model.zoomIn()
        XCTAssertEqual(model.zoomScale, 4, accuracy: 0.0001)
        model.zoomScale = 0.25
        model.zoomOut()
        XCTAssertEqual(model.zoomScale, 0.25, accuracy: 0.0001)
    }

    @MainActor
    func testSliderInteractionCreatesOneUndoStepForManyValues() {
        let model = EditorViewModel()
        model.beginInteractiveAdjustment()
        model.adjustments.exposure = 0.5
        model.scheduleRender(recordHistory: false)
        model.adjustments.exposure = 1.0
        model.scheduleRender(recordHistory: false)
        model.finishInteractiveAdjustment()

        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.adjustments.exposure, 0, accuracy: 0.0001)
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testArrowNavigationSelectsAdjacentPhotoWithoutLeavingBounds() {
        let model = EditorViewModel()
        model.photos = [
            URL(fileURLWithPath: "/tmp/one.arw"),
            URL(fileURLWithPath: "/tmp/two.arw"),
            URL(fileURLWithPath: "/tmp/three.arw")
        ]
        model.selectedIndex = 1

        model.movePhotoSelection(.left)
        XCTAssertEqual(model.selectedIndex, 0)
        model.movePhotoSelection(.left)
        XCTAssertEqual(model.selectedIndex, 0)
        model.movePhotoSelection(.right)
        XCTAssertEqual(model.selectedIndex, 1)
        model.movePhotoSelection(.right)
        XCTAssertEqual(model.selectedIndex, 2)
        model.movePhotoSelection(.right)
        XCTAssertEqual(model.selectedIndex, 2)
    }

    @MainActor
    func testAdjustmentBrushStrokeStoresNormalizedPointsAndSupportsUndo() {
        let model = EditorViewModel()
        model.beginAdjustmentBrush(at: CGPoint(x: -0.2, y: 1.2))
        model.appendAdjustmentBrushPoint(CGPoint(x: 0.4, y: 0.6))
        model.appendAdjustmentBrushPoint(CGPoint(x: 1.3, y: -0.1))
        model.finishInteractiveAdjustment()

        XCTAssertEqual(model.adjustments.adjustmentBrushes.count, 1)
        XCTAssertEqual(model.adjustments.adjustmentBrushes[0].points.map(\.x), [0, 0.4, 1])
        XCTAssertEqual(model.adjustments.adjustmentBrushes[0].points.map(\.y), [1, 0.6, 0])
        model.undo()
        XCTAssertTrue(model.adjustments.adjustmentBrushes.isEmpty)

        model.beginAdjustmentBrush(at: CGPoint(x: 0.5, y: 0.5))
        model.clearAdjustmentBrushes()
        XCTAssertTrue(model.adjustments.adjustmentBrushes.isEmpty)
    }

    func testNearbyThumbnailIndicesPreferAdjacentPhotosAndExcludeCurrent() {
        XCTAssertEqual(
            EditorViewModel.nearbyThumbnailIndices(around: 2, count: 6, radius: 2),
            [3, 1, 4, 0]
        )
        XCTAssertEqual(
            EditorViewModel.nearbyThumbnailIndices(around: 0, count: 3, radius: 3),
            [1, 2]
        )
        XCTAssertEqual(EditorViewModel.nearbyThumbnailIndices(around: 0, count: 0), [])
    }

    @MainActor
    func testOpeningPhotoLoadsSidecarBeforeBackgroundDecodeCompletes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-load-state-(UUID().uuidString)")
        let photo = root.appendingPathComponent("sample.png")
        let cache = root.appendingPathComponent("RAW_TEMP")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        var saved = ImageAdjustments()
        saved.exposure = 1.5
        saved.contrast = -24
        try saved.save(to: cache.appendingPathComponent("sample.png.rawpipe.xml"))

        let model = EditorViewModel()
        model.openDropped(url: photo)

        XCTAssertEqual(model.adjustments.exposure, 1.5)
        XCTAssertEqual(model.adjustments.contrast, -24)
    }

    func testFolderScanReconcilesSelectionByURLInsteadOfResettingToFirstPhoto() {
        let first = URL(fileURLWithPath: "/tmp/first.arw")
        let selected = URL(fileURLWithPath: "/tmp/selected.arw")
        let third = URL(fileURLWithPath: "/tmp/third.arw")
        let result = EditorViewModel.reconciledSelection(
            preferredURL: selected,
            selectedURLs: [first, selected],
            in: [third, selected, first]
        )

        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.selected, [1, 2])
    }

    func testReadsExistingAdjustmentXMLScalarFields() throws {
        let xml = """
        <RawPipeDocument>
          <IsPlaceholder>false</IsPlaceholder>
          <Adjustments>
            <Exposure>0.75</Exposure>
            <Contrast>-20</Contrast>
            <Temperature>6300</Temperature>
            <Tint>12</Tint>
            <Vignette>35</Vignette>
            <CropAspectRatio>4:3</CropAspectRatio>
            <CropWidth>0.8</CropWidth>
            <Rotation>R90</Rotation>
            <HealSpots>
              <HealSpot><TargetX>0.4</TargetX><SourceX>0.7</SourceX><Strength>0.45</Strength></HealSpot>
            </HealSpots>
            <AdjustmentBrushes>
              <AdjustmentBrush>
                <RadiusNorm>0.08</RadiusNorm><Feather>0.6</Feather>
                <Exposure>0.5</Exposure><Highlights>-30</Highlights><Saturation>12</Saturation>
                <Points><Point><X>0.2</X><Y>0.3</Y></Point><Point><X>0.4</X><Y>0.5</Y></Point></Points>
              </AdjustmentBrush>
            </AdjustmentBrushes>
          </Adjustments>
        </RawPipeDocument>
        """.data(using: .utf8)!

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-test.rawpipe.xml")
        try xml.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var adjustments = ImageAdjustments()
        try adjustments.load(from: url)

        XCTAssertEqual(adjustments.exposure, 0.75)
        XCTAssertEqual(adjustments.contrast, -20)
        XCTAssertEqual(adjustments.temperature, 6300)
        XCTAssertEqual(adjustments.tint, 12)
        XCTAssertEqual(adjustments.vignette, 35)
        XCTAssertEqual(adjustments.cropAspectRatio, "4:3")
        XCTAssertEqual(adjustments.cropWidth, 0.8)
        XCTAssertEqual(adjustments.healSpots.first?.strength, 0.45)
        XCTAssertEqual(adjustments.adjustmentBrushes.count, 1)
        XCTAssertEqual(adjustments.adjustmentBrushes.first?.radiusNorm, 0.08)
        XCTAssertEqual(adjustments.adjustmentBrushes.first?.feather, 0.6)
        XCTAssertEqual(adjustments.adjustmentBrushes.first?.points.count, 2)
        XCTAssertEqual(adjustments.adjustmentBrushes.first?.exposure, 0.5)
        XCTAssertEqual(adjustments.adjustmentBrushes.first?.saturation, 12)
        XCTAssertEqual(adjustments.rotation, 90)
        XCTAssertEqual(adjustments.saturation, 0)
    }

    func testDecoderRejectsUnsupportedExtensionBeforeReadingFile() {
        let decoder = ApplePhotoDecoder()
        let url = URL(fileURLWithPath: "/tmp/not-a-photo.txt")

        XCTAssertThrowsError(try decoder.decode(url: url)) { error in
            XCTAssertEqual(error as? PhotoDecoderError, .unsupportedFormat)
        }
    }

    func testRawDecoderFallsBackToExistingRawPipeProxy() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-proxy-test-\(UUID().uuidString)")
        let cache = folder.appendingPathComponent("RAW_TEMP")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let rawURL = folder.appendingPathComponent("camera.ARW")
        try Data("not-a-real-raw-file".utf8).write(to: rawURL)
        let proxyURL = cache.appendingPathComponent("camera.ARW.rawpipe.png")
        let proxy = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 24, height: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(proxy, from: proxy.extent) else {
            XCTFail("Could not create proxy image")
            return
        }
        let destination = CGImageDestinationCreateWithURL(proxyURL as CFURL, "public.png" as CFString, 1, nil)
        CGImageDestinationAddImage(destination!, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination!))

        let decoded = try ApplePhotoDecoder().decode(url: rawURL)
        XCTAssertEqual(decoded.extent.width, 24, accuracy: 0.1)
        XCTAssertEqual(decoded.extent.height, 12, accuracy: 0.1)
    }

    func testRendererProducesPreviewForSyntheticImage() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let renderer = ImageRenderer()
        let result = renderer.makePreview(image, adjustments: ImageAdjustments())

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 32)
        XCTAssertEqual(result?.height, 24)
    }

    func testRendererAppliesFeatheredAdjustmentBrushLocally() {
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var adjustments = ImageAdjustments()
        var brush = AdjustmentBrush(points: [
            AdjustmentBrushPoint(x: 0.15, y: 0.2),
            AdjustmentBrushPoint(x: 0.85, y: 0.8)
        ])
        brush.radiusNorm = 0.3
        brush.feather = 0.5
        brush.exposure = 2
        adjustments.adjustmentBrushes = [brush]

        let context = CIContext()
        guard let result = context.createCGImage(ImageRenderer().render(source, adjustments: adjustments),
                                                  from: source.extent),
              let data = result.dataProvider?.data else {
            XCTFail("Could not render adjustment brush")
            return
        }
        let bytes = CFDataGetBytePtr(data)!
        let center = (50 * result.bytesPerRow) + (50 * 4)
        let corner = (0 * result.bytesPerRow) + (0 * 4)
        XCTAssertGreaterThan(bytes[center], bytes[corner])
    }

    func testAdjustmentBrushPreservesPixelsOutsideMask() {
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 120, y: 80, width: 160, height: 100))
        var adjustments = ImageAdjustments()
        var brush = AdjustmentBrush(points: [
            AdjustmentBrushPoint(x: 0.15, y: 0.2),
            AdjustmentBrushPoint(x: 0.85, y: 0.8)
        ])
        brush.radiusNorm = 0.08
        brush.exposure = 1.0
        adjustments.adjustmentBrushes = [brush]

        let context = CIContext()
        guard let result = context.createCGImage(ImageRenderer().render(source, adjustments: adjustments), from: source.extent),
              let data = result.dataProvider?.data else {
            XCTFail("Could not render adjustment brush mask")
            return
        }
        let bytes = CFDataGetBytePtr(data)!
        let top = 0 * result.bytesPerRow + 80 * 4
        let bottom = 99 * result.bytesPerRow + 80 * 4
        XCTAssertGreaterThan(bytes[top], 30)
        XCTAssertGreaterThan(bytes[bottom], 30)
        XCTAssertGreaterThan(bytes[top + 3], 240)
        XCTAssertGreaterThan(bytes[bottom + 3], 240)
    }

    func testEmptyAdjustmentBrushDoesNotAlterImage() {
        let source = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
        var adjustments = ImageAdjustments()
        adjustments.adjustmentBrushes = [AdjustmentBrush(points: [AdjustmentBrushPoint(x: 0.5, y: 0.5)])]
        let renderer = ImageRenderer()
        guard let result = renderer.makePreview(source, adjustments: adjustments),
              let original = renderer.makePreview(source, adjustments: ImageAdjustments()),
              let resultData = result.dataProvider?.data,
              let originalData = original.dataProvider?.data else {
            XCTFail("Could not render empty adjustment brush")
            return
        }
        XCTAssertEqual(Data(bytes: CFDataGetBytePtr(resultData)!, count: CFDataGetLength(resultData)),
                       Data(bytes: CFDataGetBytePtr(originalData)!, count: CFDataGetLength(originalData)))
    }

    func testAdjustmentBrushSidecarRoundTripPreservesMaskAndValues() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-brush-roundtrip-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }

        var original = ImageAdjustments()
        original.adjustmentBrushes = [AdjustmentBrush(
            points: [AdjustmentBrushPoint(x: 0.12, y: 0.34), AdjustmentBrushPoint(x: 0.56, y: 0.78)],
            radiusNorm: 0.091,
            feather: 0.42,
            exposure: -1.25,
            contrast: 18,
            highlights: -22,
            shadows: 31,
            whites: 7,
            blacks: -12,
            temperature: 7100,
            tint: -9,
            vibrance: 14,
            saturation: -6
        )]
        try original.save(to: url)

        var restored = ImageAdjustments()
        try restored.load(from: url)
        XCTAssertEqual(restored.adjustmentBrushes, original.adjustmentBrushes)
    }

    func testHistogramProducesNormalizedLuminanceBins() {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        guard let cgImage = ImageRenderer().makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not render histogram source")
            return
        }
        let bins = HistogramCalculator.bins(for: cgImage)
        XCTAssertEqual(bins.count, 64)
        XCTAssertEqual(bins.max(), 1)
        XCTAssertEqual(bins.filter { $0 > 0 }.count, 1)
    }

    func testRGBHistogramKeepsIndependentColorChannels() {
        let pixelData = Data([255, 0, 0, 255])
        let provider = CGDataProvider(data: pixelData as CFData)
        let cgImage = provider.flatMap { CGImage(width: 1, height: 1,
                                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                                  provider: $0, decode: nil, shouldInterpolate: false,
                                                  intent: .defaultIntent) }
        guard let cgImage else { XCTFail("Could not create RGB histogram source"); return }
        let histogram = HistogramCalculator.rgbBins(for: cgImage)
        XCTAssertEqual(histogram.red.count, 64)
        XCTAssertEqual(histogram.green.count, 64)
        XCTAssertEqual(histogram.blue.count, 64)
        XCTAssertEqual(histogram.red.max(), 1)
        XCTAssertNotEqual(histogram.red, histogram.green)
        XCTAssertNotEqual(histogram.red, histogram.blue)
    }

    func testNaturalColorAssistantSuggestsExposureForDarkImage() {
        let image = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let preview = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create color assistant fixture")
            return
        }
        let suggestion = NaturalColorAssistant.suggest(for: preview)
        XCTAssertGreaterThan(suggestion.exposureDelta, 0)
        XCTAssertTrue(suggestion.reasons.contains(.exposure))
        XCTAssertGreaterThan(suggestion.confidence, 0.3)
    }

    func testColorConstancyEnsembleAgreesOnNeutralImage() {
        let image = CIImage(color: CIColor(red: 0.45, green: 0.45, blue: 0.45))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let preview = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create color constancy fixture")
            return
        }
        let estimate = ColorConstancyAnalyzer.estimate(for: preview)
        XCTAssertEqual(estimate.methods.count, 4)
        XCTAssertLessThan(estimate.agreementDegrees, 20)
        XCTAssertGreaterThan(estimate.confidence, 0.45)
        XCTAssertEqual(estimate.correctionGains.x, estimate.correctionGains.z, accuracy: 0.08)
    }

    func testColorConstancyWarmSceneRequestsBlueChannelCompensation() {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.42, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let preview = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create color constancy fixture")
            return
        }
        let estimate = ColorConstancyAnalyzer.estimate(for: preview)
        XCTAssertLessThan(estimate.correctionGains.x, estimate.correctionGains.z)
    }

    func testNaturalColorAssistantDetectsWarmColorCastAndPreservesExistingEdits() {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.42, blue: 0.18))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let preview = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create color assistant fixture")
            return
        }
        let suggestion = NaturalColorAssistant.suggest(for: preview)
        XCTAssertLessThan(suggestion.temperatureDelta, 0)
        XCTAssertTrue(suggestion.reasons.contains(.whiteBalance))

        var existing = ImageAdjustments()
        existing.exposure = 0.5
        existing.sharpening = 24
        let adjusted = suggestion.applying(to: existing)
        XCTAssertEqual(adjusted.sharpening, 24)
        XCTAssertEqual(adjusted.exposure, 0.5 + suggestion.exposureDelta, accuracy: 0.0001)
    }

    func testColorScopesProduceWaveformVectorscopeAndClippingMetrics() {
        let image = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let preview = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create scope fixture")
            return
        }
        let scopes = ColorScopeCalculator.snapshot(for: preview)
        XCTAssertEqual(scopes.waveform.count, 128 * 64)
        XCTAssertEqual(scopes.vectorscope.count, 128 * 128)
        XCTAssertGreaterThan(scopes.waveform.max() ?? 0, 0)
        XCTAssertGreaterThan(scopes.vectorscope.max() ?? 0, 0)
        XCTAssertGreaterThan(scopes.clippedHighlightFraction, 0)
    }

    func testSemanticMaskAnalyzerFindsSkyLikeRegion() {
        let context = CGContext(data: nil, width: 64, height: 48,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context?.makeImage() else {
            XCTFail("Could not create semantic mask fixture")
            return
        }
        let regions = SemanticMaskAnalyzer.detect(in: image)
        XCTAssertTrue(regions.contains(where: { $0.kind == .sky }))
        XCTAssertGreaterThan(regions.first(where: { $0.kind == .sky })?.points.count ?? 0, 3)
    }

    func testColorCheckerCalibrationSolvesIdentityMatrix() {
        let samples = [
            ColorCheckerSample(measured: SIMD3(1, 0, 0), reference: SIMD3(1, 0, 0)),
            ColorCheckerSample(measured: SIMD3(0, 1, 0), reference: SIMD3(0, 1, 0)),
            ColorCheckerSample(measured: SIMD3(0, 0, 1), reference: SIMD3(0, 0, 1))
        ]
        guard let profile = ColorCheckerProfile.calibrate(samples: samples) else {
            XCTFail("Could not solve ColorChecker profile")
            return
        }
        XCTAssertEqual(profile.matrix, ColorCheckerProfile.identityMatrix)
        XCTAssertEqual(profile.sampleCount, 3)
    }

    func testColorProfileMatrixPersistsInSidecar() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-color-profile-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: url) }
        var original = ImageAdjustments()
        original.colorProfileMatrix = [0.98, 0.01, 0.02,
                                       0.02, 1.01, -0.01,
                                       0.00, 0.03, 0.96]
        try original.save(to: url)
        var restored = ImageAdjustments()
        try restored.load(from: url)
        XCTAssertEqual(restored.colorProfileMatrix, original.colorProfileMatrix)
    }

    func testReferenceColorMatcherSuggestsDifferenceFromReference() {
        let source = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let reference = CIImage(color: CIColor(red: 0.55, green: 0.55, blue: 0.55))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let sourceImage = ImageRenderer.shared.makePreview(source, adjustments: ImageAdjustments()),
              let referenceImage = ImageRenderer.shared.makePreview(reference, adjustments: ImageAdjustments()) else {
            XCTFail("Could not create reference match fixture")
            return
        }
        let suggestion = ReferenceColorMatcher.suggestion(source: sourceImage, reference: referenceImage)
        XCTAssertGreaterThan(suggestion.exposureDelta, 0)
        XCTAssertTrue(suggestion.reasons.contains(.exposure))
    }

    func testRendererAppliesColorProfileMatrix() {
        let source = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 0, width: 24, height: 16))
        var adjustments = ImageAdjustments()
        adjustments.colorProfileMatrix = [0, 0, 1,
                                           0, 1, 0,
                                           1, 0, 0]
        guard let rendered = ImageRenderer.shared.makePreview(source, adjustments: adjustments),
              let data = rendered.dataProvider?.data else {
            XCTFail("Could not render color profile fixture")
            return
        }
        let bytes = CFDataGetBytePtr(data)!
        XCTAssertGreaterThan(bytes[2], bytes[0])
    }

    func testHistogramDownsamplesLargeImagesBeforeAnalysis() {
        guard let context = CGContext(data: nil, width: 2048, height: 1024,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            XCTFail("Could not create large histogram source")
            return
        }
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.2, 0.6, 0.9, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        guard let image = context.makeImage() else {
            XCTFail("Could not create large histogram image")
            return
        }

        let snapshot = HistogramCalculator.snapshot(for: image)
        XCTAssertEqual(snapshot.luminance.count, 64)
        XCTAssertEqual(snapshot.rgb.red.count, 64)
        XCTAssertEqual(snapshot.luminance.max(), 1)
    }

    func testHistogramSnapshotMatchesIndividualCalculators() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        guard let cgImage = ImageRenderer.shared.makePreview(image, adjustments: ImageAdjustments()) else {
            XCTFail("Could not render histogram source")
            return
        }
        let snapshot = HistogramCalculator.snapshot(for: cgImage)
        XCTAssertEqual(snapshot.luminance, HistogramCalculator.bins(for: cgImage))
        XCTAssertEqual(snapshot.rgb.red, HistogramCalculator.rgbBins(for: cgImage).red)
        XCTAssertEqual(snapshot.rgb.green, HistogramCalculator.rgbBins(for: cgImage).green)
        XCTAssertEqual(snapshot.rgb.blue, HistogramCalculator.rgbBins(for: cgImage).blue)
    }

    func testWhiteBalanceSamplerReturnsClampedTemperatureAndTint() {
        let image = CIImage(color: CIColor(red: 0.9, green: 0.5, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let result = WhiteBalanceSampler.sample(source: image,
                                                      normalizedPoint: CGPoint(x: 0.5, y: 0.5)) else {
            XCTFail("Could not sample white balance")
            return
        }
        XCTAssertGreaterThan(result.temperature, 5200)
        XCTAssertGreaterThan(result.tint, 0)
        XCTAssertTrue((2000...12000).contains(result.temperature))
        XCTAssertTrue((-100...100).contains(result.tint))
    }

    func testExportsJPEG() throws {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-export-test.jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter().exportJPEG(source: image,
                                       adjustments: ImageAdjustments(), to: url)

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertEqual(data.prefix(2), Data([0xff, 0xd8]))
    }

    func testExportsPNGAndTIFF() throws {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        let exporter = ImageExporter()
        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-export-test.png")
        let tiffURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-export-test.tiff")
        defer {
            try? FileManager.default.removeItem(at: pngURL)
            try? FileManager.default.removeItem(at: tiffURL)
        }

        try exporter.export(source: image, adjustments: ImageAdjustments(), to: pngURL, format: .png)
        try exporter.export(source: image, adjustments: ImageAdjustments(), to: tiffURL, format: .tiff)
        XCTAssertEqual(try Data(contentsOf: pngURL).prefix(8),
                       Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        let tiffHeader = try Data(contentsOf: tiffURL).prefix(2)
        XCTAssertTrue(tiffHeader == Data([0x49, 0x49]) || tiffHeader == Data([0x4d, 0x4d]))
    }

    func testExportsBMP() throws {
        let image = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-export-test.bmp")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter().export(source: image, adjustments: ImageAdjustments(), to: url, format: .bmp)
        XCTAssertEqual(try Data(contentsOf: url).prefix(2), Data([0x42, 0x4d]))
    }

    func testBatchExporterUsesPerPhotoAdjustmentsAndUniqueNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-batch-(UUID().uuidString)")
        let cache = root.appendingPathComponent("RAW_TEMP")
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("one.png")
        let second = root.appendingPathComponent("two.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.8, green: 0.1, blue: 0.1))
        try writeTestPNG(to: second, color: CIColor(red: 0.1, green: 0.1, blue: 0.8))

        var adjustments = ImageAdjustments()
        adjustments.exposure = 1.25
        try adjustments.save(to: cache.appendingPathComponent("one.png.rawpipe.xml"))
        let result = try ImageBatchExporter().export(urls: [first, second], to: output, format: .png)

        XCTAssertEqual(result.writtenURLs.count, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.writtenURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(result.writtenURLs.contains { $0.lastPathComponent == "one_edited.png" })
        XCTAssertTrue(result.writtenURLs.contains { $0.lastPathComponent == "two_edited.png" })
    }

    func testBatchExporterSupportsSequenceNaming() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-sequence-\(UUID().uuidString)")
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
        try writeTestPNG(to: second, color: CIColor(red: 0.4, green: 0.3, blue: 0.2))

        var progress: [(Int, Int)] = []
        let result = try ImageBatchExporter().export(urls: [first, second], to: output,
                                                      format: .png, naming: .sequence,
                                                      onProgress: { progress.append(($0, $1)) })
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(progress.map(\.0), [1, 2])
        XCTAssertEqual(progress.map(\.1), [2, 2])
        XCTAssertEqual(result.writtenURLs.map(\.lastPathComponent), ["0001_edited.png", "0002_edited.png"])
    }

    func testBatchExporterReservesAppendNumberNamesBeforeParallelWorkersStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-name-reservation-\(UUID().uuidString)")
        let firstFolder = root.appendingPathComponent("first")
        let secondFolder = root.appendingPathComponent("second")
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = firstFolder.appendingPathComponent("same.png")
        let second = secondFolder.appendingPathComponent("same.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.8, green: 0.1, blue: 0.1))
        try writeTestPNG(to: second, color: CIColor(red: 0.1, green: 0.1, blue: 0.8))

        let result = try ImageBatchExporter().export(urls: [first, second], to: output, format: .png)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.writtenURLs.map(\.lastPathComponent), ["same_edited.png", "same_edited_2.png"])
    }

    func testBatchExporterHonoursCancellationBeforeStartingNextPhoto() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-cancel-\(UUID().uuidString)")
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
        try writeTestPNG(to: second, color: CIColor(red: 0.4, green: 0.3, blue: 0.2))

        let token = BatchExportCancellationToken()
        token.cancel()
        let result = try ImageBatchExporter().export(urls: [first, second], to: output, format: .png,
                                                      shouldCancel: { token.isCancelled })
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.writtenURLs.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testBatchExporterCanOverwriteExistingOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-overwrite-\(UUID().uuidString)")
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        try writeTestPNG(to: source, color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
        let existing = output.appendingPathComponent("photo_edited.png")
        try Data("old".utf8).write(to: existing)

        let result = try ImageBatchExporter().export(urls: [source], to: output, format: .png,
                                                      conflict: .overwrite)
        XCTAssertEqual(result.writtenURLs.map(\.lastPathComponent), ["photo_edited.png"])
        XCTAssertGreaterThan(try Data(contentsOf: existing).count, 100)
    }

    @MainActor
    func testVirtualCopyCreatesCompatibleCopyXMLAndCanSwitch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-copy-\(UUID().uuidString)")
        let photo = root.appendingPathComponent("sample.png")
        let cache = root.appendingPathComponent("RAW_TEMP")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        let model = EditorViewModel()
        model.open(url: photo)
        model.adjustments.exposure = 1.0
        model.flushPendingSave()
        model.createVirtualCopy()

        let copyURL = cache.appendingPathComponent("sample.png.copy1.rawpipe.xml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(model.virtualCopyIndex, 1)
        model.switchVirtualCopy(by: -1)
        XCTAssertEqual(model.virtualCopyIndex, 0)
        XCTAssertEqual(model.adjustments.exposure, 1.0)
    }

    @MainActor
    func testUndoRedoRestoresAdjustmentStates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-history-\(UUID().uuidString)")
        let photo = root.appendingPathComponent("sample.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        let model = EditorViewModel()
        model.open(url: photo)
        model.adjustments.exposure = 1.0
        model.scheduleRender()
        model.adjustments.contrast = 25
        model.scheduleRender()

        model.undo()
        XCTAssertEqual(model.adjustments.exposure, 1.0)
        XCTAssertEqual(model.adjustments.contrast, 0)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.adjustments.contrast, 25)
        XCTAssertFalse(model.canRedo)
    }

    @MainActor
    func testInteractiveLocalToolDragCreatesOneUndoStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-interactive-history-\(UUID().uuidString)")
        let photo = root.appendingPathComponent("sample.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        let model = EditorViewModel()
        model.open(url: photo)
        model.addGradient()
        model.moveGradientCenter(at: 0, to: CGPoint(x: 0.6, y: 0.6))
        model.moveGradientCenter(at: 0, to: CGPoint(x: 0.7, y: 0.7))
        model.moveGradientCenter(at: 0, to: CGPoint(x: 0.8, y: 0.8))
        model.finishInteractiveAdjustment()

        model.undo()
        XCTAssertEqual(model.adjustments.gradients.first?.centerX, 0.5)
        XCTAssertEqual(model.adjustments.gradients.first?.centerY, 0.15)
        XCTAssertTrue(model.canUndo)
    }

    @MainActor
    func testOriginalPreviewNeutralizesEditsButKeepsGeometry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-original-preview-\(UUID().uuidString)")
        let photo = root.appendingPathComponent("sample.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        let model = EditorViewModel()
        model.open(url: photo)
        model.adjustments.exposure = 1.25
        model.adjustments.cropX = 0.2
        model.adjustments.rotation = 90
        model.adjustments.gradients = [LinearGradient()]
        model.adjustments.healSpots = [HealSpot()]
        let neutral = model.originalPreviewAdjustments()

        XCTAssertEqual(neutral.exposure, 0)
        XCTAssertEqual(neutral.cropX, 0.2)
        XCTAssertEqual(neutral.rotation, 90)
        XCTAssertTrue(neutral.gradients.isEmpty)
        XCTAssertTrue(neutral.healSpots.isEmpty)
        XCTAssertEqual(model.adjustments.exposure, 1.25)
    }

    @MainActor
    func testBeforeAfterModeTracksSplitAndDoesNotMutateAdjustments() {
        let model = EditorViewModel()
        model.adjustments.exposure = 1.5
        model.toggleBeforeAfter()

        XCTAssertTrue(model.beforeAfterEnabled)
        XCTAssertFalse(model.showOriginal)
        model.setBeforeAfterPosition(0.72)
        XCTAssertEqual(model.beforeAfterPosition, 0.72, accuracy: 0.001)

        model.toggleShowOriginal()
        XCTAssertFalse(model.beforeAfterEnabled)
        XCTAssertTrue(model.showOriginal)
        XCTAssertEqual(model.adjustments.exposure, 1.5)
    }

    @MainActor
    func testLanguageDefaultsToTraditionalChineseAndPersistsEnglishSelection() {
        let defaults = UserDefaults.standard
        let key = "MorrowRAW.language"
        let previous = defaults.string(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(EditorViewModel().language, .traditionalChinese)

        let model = EditorViewModel()
        model.language = .english
        XCTAssertEqual(defaults.string(forKey: key), AppLanguage.english.rawValue)
        XCTAssertEqual(EditorViewModel().language, .english)
        XCTAssertEqual(StudioText.filmstrip, "Filmstrip")
        XCTAssertEqual(StudioText.loadingPhotos(2, 5), "Loading photos… 2/5")
        XCTAssertEqual(BuiltInPreset.landscape.displayName, "Landscape")

        defaults.set(AppLanguage.traditionalChinese.rawValue, forKey: key)
        XCTAssertEqual(StudioText.filmstrip, "膠卷")
        XCTAssertEqual(StudioText.loadingPhotos(2, 5), "正在讀取照片… 2/5")
        XCTAssertEqual(BuiltInPreset.landscape.displayName, "風景")
    }

    @MainActor
    func testCopyPasteAdjustmentsPreservesDestinationExif() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-copy-paste-(UUID().uuidString)")
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: first, color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
        try writeTestPNG(to: second, color: CIColor(red: 0.6, green: 0.5, blue: 0.4))

        let model = EditorViewModel()
        model.open(url: first)
        model.adjustments.exposure = 1.25
        model.adjustments.cropX = 0.2
        model.adjustments.cachedExif = ExifData(cameraMake: "SourceCamera")
        model.copyPhotoAdjustments()
        XCTAssertTrue(model.canPasteAdjustments)

        model.open(url: second)
        model.adjustments.cachedExif = ExifData(cameraMake: "DestinationCamera")
        model.pastePhotoAdjustments()

        XCTAssertEqual(model.adjustments.exposure, 1.25)
        XCTAssertEqual(model.adjustments.cropX, 0.2)
        XCTAssertEqual(model.adjustments.cachedExif?.cameraMake, "DestinationCamera")
    }

    @MainActor
    func testSelectedBatchEditCopiesOnlyCheckedPhotos() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-selected-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        let third = root.appendingPathComponent("third.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
        try writeTestPNG(to: second, color: CIColor(red: 0.3, green: 0.2, blue: 0.1))
        try writeTestPNG(to: third, color: CIColor(red: 0.6, green: 0.5, blue: 0.4))

        let model = EditorViewModel()
        model.openSynchronously(urls: [first, second, third])
        model.adjustments.exposure = 1.5
        model.selectedPhotoIndices = [1]
        model.copyCurrentAdjustmentsToSelected()
        while model.isBatchAdjusting {
            try await Task.sleep(for: .milliseconds(1))
        }

        var selected = ImageAdjustments()
        try selected.load(from: root.appendingPathComponent("RAW_TEMP/second.png.rawpipe.xml"))
        XCTAssertEqual(selected.exposure, 1.5)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("RAW_TEMP/third.png.rawpipe.xml").path))
    }

    @MainActor
    func testSelectedBatchEditCanApplyPresetOnlyToCheckedPhotos() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-selected-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
        try writeTestPNG(to: second, color: CIColor(red: 0.3, green: 0.2, blue: 0.1))

        let model = EditorViewModel()
        model.openSynchronously(urls: [first, second])
        model.selectedPhotoIndices = [1]
        model.applyPresetToSelected(.vivid)
        while model.isBatchAdjusting {
            try await Task.sleep(for: .milliseconds(1))
        }

        var restored = ImageAdjustments()
        try restored.load(from: root.appendingPathComponent("RAW_TEMP/second.png.rawpipe.xml"))
        XCTAssertGreaterThan(restored.saturation, 0)
        var untouched = ImageAdjustments()
        try untouched.load(from: root.appendingPathComponent("RAW_TEMP/first.png.rawpipe.xml"))
        XCTAssertEqual(untouched.saturation, 0)
    }

    func testExportsWithWatermark() throws {
        let image = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-watermark-test.png")
        defer { try? FileManager.default.removeItem(at: url) }
        var watermark = WatermarkSettings()
        watermark.enabled = true
        watermark.text = "Test"
        watermark.color = .orange
        try ImageExporter().export(source: image, adjustments: ImageAdjustments(),
                                   to: url, format: .png, watermark: watermark)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 100)
    }

    func testJPEGQualityRangeCanBePassedToExporter() throws {
        let image = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-quality-test.jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageExporter().export(source: image, adjustments: ImageAdjustments(),
                                   to: url, format: .jpeg, quality: 0.35)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 100)
    }

    func testExportCanLimitLongEdge() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-sized-(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter().export(source: image, adjustments: ImageAdjustments(), to: url,
                                   format: .jpeg, maxLongEdge: 12)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            XCTFail("Could not read exported dimensions")
            return
        }
        XCTAssertEqual(max(width, height), 12)
    }

    func testExportWritesRequestedDPI() throws {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-dpi-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter().export(source: image, adjustments: ImageAdjustments(), to: url,
                                   format: .jpeg, dpi: 600, preserveMetadata: false)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let dpi = properties[kCGImagePropertyDPIWidth as String] as? Double else {
            XCTFail("Could not read exported DPI")
            return
        }
        XCTAssertEqual(dpi, 600, accuracy: 0.1)
    }

    func testExportPreservesSourceMetadataWhenEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.jpg")
        let outputURL = root.appendingPathComponent("output.jpg")
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw ImageExporterError.cannotRender }
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "AwayCamera"
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageExporterError.cannotFinalize }

        try ImageExporter().export(source: image, adjustments: ImageAdjustments(), to: outputURL,
                                   format: .jpeg, sourceURL: sourceURL, preserveMetadata: true)
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let outputProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let tiff = outputProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] else {
            XCTFail("Could not read exported metadata")
            return
        }
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "AwayCamera")
        XCTAssertEqual(outputProperties[kCGImagePropertyOrientation as String] as? Int, 1)
    }

    func testBatchAdjustmentServiceAppliesPresetAndPreservesEachPhotoExif() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-batch-edit-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("RAW_TEMP")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.png")
        let second = root.appendingPathComponent("two.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
        try writeTestPNG(to: second, color: CIColor(red: 0.5, green: 0.4, blue: 0.3))
        var secondAdjustments = ImageAdjustments()
        secondAdjustments.cachedExif = ExifData(cameraMake: "SecondCamera")
        try secondAdjustments.save(to: cache.appendingPathComponent("two.png.rawpipe.xml"))

        let result = BatchAdjustmentService.applyPreset(.vivid, to: [first, second])
        XCTAssertEqual(result.updatedCount, 2)
        XCTAssertEqual(result.failureCount, 0)
        var restored = ImageAdjustments()
        try restored.load(from: cache.appendingPathComponent("two.png.rawpipe.xml"))
        XCTAssertEqual(restored.cachedExif?.cameraMake, "SecondCamera")
        XCTAssertGreaterThan(restored.saturation, 0)
    }

    func testTerminationNotificationNameIsStable() {
        XCTAssertEqual(Notification.Name.morrowRAWWillTerminate.rawValue,
                       "MorrowRAW.willTerminate")
    }

    func testPhotoLibraryScansSupportedFilesAndSortsNaturally() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-library-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG10.JPG").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG2.ARW").path, contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("notes.txt").path, contents: nil)

        let result = PhotoLibrary.scan(folder: folder)

        XCTAssertEqual(result.map(\.lastPathComponent), ["IMG2.ARW", "IMG10.JPG"])
    }

    func testPhotoLibraryIncrementalScanReportsTotalAndBatchesRawFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-library-incremental-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["IMG10.ARW", "IMG2.ARW", "IMG1.ARW"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("preview.JPG").path, contents: nil)

        let callbacks = LockedScanResults()
        let result = PhotoLibrary.scanIncrementally(folder: folder, rawOnly: true, batchSize: 2,
                                                    onTotal: { callbacks.setTotal($0) },
                                                    onScanProgress: { scanned, _ in callbacks.appendScanProgress(scanned) },
                                                    onBatch: { callbacks.appendBatch($0.map(\.lastPathComponent)) })

        XCTAssertEqual(callbacks.total, 3)
        XCTAssertEqual(callbacks.scanned, [0, 4])
        XCTAssertEqual(callbacks.batches.map(\.count), [2, 1])
        XCTAssertEqual(callbacks.batches.flatMap { $0 }, ["IMG1.ARW", "IMG2.ARW", "IMG10.ARW"])
        XCTAssertEqual(result.map(\.lastPathComponent), ["IMG1.ARW", "IMG2.ARW", "IMG10.ARW"])
    }

    func testPhotoLibraryIgnoresHiddenFilesAndDirectories() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-library-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested.JPG"),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".hidden.JPG").path,
                                       contents: nil)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("visible.HEIC").path,
                                       contents: nil)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertEqual(PhotoLibrary.scan(folder: folder).map(\.lastPathComponent), ["visible.HEIC"])
    }

    func testPhotoLibraryStateHidesAndRestoresPhotoWithoutChangingScanData() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.png")
        let second = folder.appendingPathComponent("second.png")
        try writeTestPNG(to: first, color: CIColor(red: 0.1, green: 0.2, blue: 0.3))
        try writeTestPNG(to: second, color: CIColor(red: 0.4, green: 0.5, blue: 0.6))

        var state = PhotoLibraryState.load(folder: folder)
        state.hide(first)
        try state.save(folder: folder)

        XCTAssertEqual(PhotoLibrary.scan(folder: folder).map(\.lastPathComponent), ["second.png"])
        XCTAssertEqual(PhotoLibrary.scan(folder: folder, includeHidden: true)
            .map(\.lastPathComponent), ["first.png", "second.png"])

        var restored = PhotoLibraryState.load(folder: folder)
        XCTAssertTrue(restored.contains(first))
        restored.show(first)
        try restored.save(folder: folder)
        XCTAssertEqual(PhotoLibrary.scan(folder: folder).count, 2)
    }

    func testHiddenPhotosAreExcludedFromBatchExportCandidates() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-export-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hidden = folder.appendingPathComponent("hidden.png")
        let visible = folder.appendingPathComponent("visible.png")
        try writeTestPNG(to: hidden, color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
        try writeTestPNG(to: visible, color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
        var state = PhotoLibraryState()
        state.hide(hidden)
        try state.save(folder: folder)

        XCTAssertEqual(PhotoLibrary.exportable([hidden, visible], from: folder), [visible])
    }

    func testToneCurveMatchesExpectedAdjustmentDirections() {
        let neutral = ImageAdjustments()
        XCTAssertEqual(ToneCurve.value(0.5, adjustments: neutral), 0.5, accuracy: 0.001)

        var lifted = neutral
        lifted.shadows = 50
        XCTAssertGreaterThan(ToneCurve.value(0.15, adjustments: lifted), 0.15)

        var deepened = neutral
        deepened.blacks = -50
        XCTAssertLessThan(ToneCurve.value(0.15, adjustments: deepened), 0.15)
    }

    func testPresetChangesTonalValuesButPreservesGeometryAndLocalEdits() {
        var adjustments = ImageAdjustments()
        adjustments.cropX = 0.2
        adjustments.gradients = [LinearGradient()]
        adjustments.healSpots = [HealSpot()]
        BuiltInPreset.landscape.apply(to: &adjustments)

        XCTAssertEqual(adjustments.contrast, 18)
        XCTAssertEqual(adjustments.vibrance, 28)
        XCTAssertEqual(adjustments.cropX, 0.2)
        XCTAssertEqual(adjustments.gradients.count, 1)
        XCTAssertEqual(adjustments.healSpots.count, 1)
    }

    func testCustomPresetPersistsOnlyTonalValues() {
        let name = "MorrowRAWTestPreset-\(UUID().uuidString)"
        var original = ImageAdjustments()
        original.exposure = 1.25
        original.cropX = 0.3
        original.gradients = [LinearGradient()]
        CustomPresetStore.save(name, adjustments: original)
        defer { UserDefaults.standard.removeObject(forKey: "MorrowRAW.customPresets") }

        var restored = ImageAdjustments()
        restored.cropX = 0.8
        XCTAssertTrue(CustomPresetStore.apply(name, to: &restored))
        XCTAssertEqual(restored.exposure, 1.25)
        XCTAssertEqual(restored.cropX, 0.8)
        XCTAssertTrue(restored.gradients.isEmpty)
    }

    func testCustomPresetSupportsUserNamedEntriesAlongsideLegacySlots() {
        let name = "我的夜景-\(UUID().uuidString)"
        var original = ImageAdjustments()
        original.exposure = -0.75
        CustomPresetStore.save(name, adjustments: original)
        defer { UserDefaults.standard.removeObject(forKey: "MorrowRAW.customPresets") }

        XCTAssertTrue(CustomPresetStore.names.contains(name))
        var restored = ImageAdjustments()
        XCTAssertTrue(CustomPresetStore.apply(name, to: &restored))
        XCTAssertEqual(restored.exposure, -0.75)
        XCTAssertTrue(CustomPresetStore.names.contains("自訂1"))
    }

    func testCustomPresetsCanBeExportedAndImportedAsJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-presets-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "MorrowRAW.customPresets")
        }
        UserDefaults.standard.removeObject(forKey: "MorrowRAW.customPresets")
        var original = ImageAdjustments()
        original.exposure = 1.5
        CustomPresetStore.save("自訂1", adjustments: original)
        try CustomPresetStore.export(to: url)

        var changed = ImageAdjustments()
        changed.exposure = -2
        CustomPresetStore.save("自訂1", adjustments: changed)
        let names = try CustomPresetStore.import(from: url)
        XCTAssertTrue(names.contains("自訂1"))
        XCTAssertTrue(CustomPresetStore.apply("自訂1", to: &changed))
        XCTAssertEqual(changed.exposure, 1.5)
    }

    func testAppearanceOptionsMapToExpectedColorSchemes() {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    }

    func testExportPreferencesRoundTripPersistsWatermarkAndBatchOptions() {
        let suiteName = "away-photo-export-preferences-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        var preferences = ExportPreferences()
        preferences.quality = 0.73
        preferences.maxLongEdge = 2400
        preferences.dpi = 600
        preferences.preserveMetadata = false
        preferences.naming = .dateTime
        preferences.conflict = .overwrite
        preferences.watermark.fontName = "Georgia"
        preferences.watermark.margin = 88
        ExportPreferencesStore.save(preferences, defaults: suite)

        XCTAssertEqual(ExportPreferencesStore.load(defaults: suite), preferences)
    }

    func testRecentFoldersDeduplicateAndDropMissingPaths() throws {
        let suiteName = "away-photo-recent-folders-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = RecentFoldersStore.remember(folder, defaults: suite)
        _ = RecentFoldersStore.remember(folder, defaults: suite)
        suite.set([folder.path, "/path/that/does/not/exist"], forKey: "MorrowRAW.recentFolders")

        XCTAssertEqual(RecentFoldersStore.load(defaults: suite), [folder.standardizedFileURL.path])
    }

    func testPhotoFingerprintChangesWhenFileSizeChanges() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-fingerprint-(UUID().uuidString).arw")
        defer { try? FileManager.default.removeItem(at: file) }

        try Data([0x01]).write(to: file)
        let original = PhotoFileFingerprint.key(for: file)
        try Data([0x01, 0x02]).write(to: file)
        let changed = PhotoFileFingerprint.key(for: file)

        XCTAssertNotEqual(original, changed)
    }

    @MainActor
    func testOpeningEmptyRecentFolderClearsPreviouslyLoadedPhoto() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-empty-folder-\(UUID().uuidString)")
        let photo = root.appendingPathComponent("photo.png")
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTestPNG(to: photo, color: CIColor(red: 0.3, green: 0.4, blue: 0.5))

        let model = EditorViewModel()
        model.open(url: photo)
        XCTAssertEqual(model.sourceName, "photo.png")
        model.openRecentFolder(empty.path)

        XCTAssertTrue(model.photos.isEmpty)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.sourceName, "尚未選擇照片")
    }

    func testPhotoMetadataReaderReadsImageDimensions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-metadata-test.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 30, height: 18))
        let context = CIContext()
        let cgImage = context.createCGImage(image, from: image.extent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let metadata = PhotoMetadataReader.read(url: url)
        XCTAssertEqual(metadata?.width, 30)
        XCTAssertEqual(metadata?.height, 18)
        XCTAssertEqual(metadata?.filePath, url.path)
    }

    func testAdjustmentXMLRoundTripPreservesMacOSValues() throws {
        var original = ImageAdjustments()
        original.exposure = 0.35
        original.highlights = -42
        original.temperature = 6400
        original.cropAspectRatio = "16:9"
        original.rotation = 270
        original.gradients = [LinearGradient(centerX: 0.5, centerY: 0.2, angle: 18,
                                              range: 0.3, exposure: -0.5, contrast: 12,
                                              highlights: -20, shadows: 25, saturation: 8)]
        original.healSpots = [HealSpot(targetX: 0.4, targetY: 0.6, sourceX: 0.2,
                                       sourceY: 0.3, radius: 12, radiusNorm: 0.04,
                                       useInpaint: true)]
        original.cachedExif = ExifData(cameraMake: "Sony", cameraModel: "A7", lens: "35mm",
                                       iso: "400", aperture: "f/2", shutter: "1/125",
                                       focalLength: "35 mm", exposureBias: "+0.3 EV",
                                       whiteBalance: "Auto", meteringMode: "Matrix",
                                       colorTemperature: 5600, tint: 2, dateTaken: "2026-08-16",
                                       width: 6000, height: 4000, fileSize: 1234,
                                       filePath: "/photos/IMG.ARW")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("away-photo-roundtrip-\(UUID().uuidString).rawpipe.xml")
        defer { try? FileManager.default.removeItem(at: url) }
        try original.save(to: url)

        var restored = ImageAdjustments()
        try restored.load(from: url)
        XCTAssertEqual(restored.exposure, original.exposure, accuracy: 0.000001)
        XCTAssertEqual(restored.highlights, original.highlights, accuracy: 0.000001)
        XCTAssertEqual(restored.temperature, original.temperature, accuracy: 0.000001)
        XCTAssertEqual(restored.cropAspectRatio, original.cropAspectRatio)
        XCTAssertEqual(restored.rotation, original.rotation)
        XCTAssertEqual(restored.gradients, original.gradients)
        XCTAssertEqual(restored.healSpots, original.healSpots)
        XCTAssertEqual(restored.cachedExif, original.cachedExif)
    }

    func testRendererAppliesRotationAndCropGeometry() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let renderer = ImageRenderer()
        var adjustments = ImageAdjustments()
        adjustments.rotation = 90
        adjustments.cropWidth = 0.5
        adjustments.cropHeight = 0.5

        let result = renderer.makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 10)
        XCTAssertEqual(result?.height, 20)
    }

    func testRendererAppliesCropAspectRatio() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.cropAspectRatio = "1:1"

        let result = ImageRenderer().makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 20)
        XCTAssertEqual(result?.height, 20)
    }

    func testRendererAppliesCustomCropAspectRatio() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.cropAspectRatio = "5:4"

        let result = ImageRenderer().makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 25)
        XCTAssertEqual(result?.height, 20)
    }

    func testRendererSupportsDetailFiltersAndFineRotation() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.sharpening = 35
        adjustments.noiseReduction = 25
        adjustments.cropAngle = 12

        XCTAssertNotNil(ImageRenderer().makePreview(image, adjustments: adjustments))
    }

    func testRendererUsesNonLocalMeansPathAtHighNoiseReduction() {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 20)
        gradient.point1 = CGPoint(x: 40, y: 20)
        gradient.color0 = CIColor(red: 0.2, green: 0.2, blue: 0.2)
        gradient.color1 = CIColor(red: 0.8, green: 0.8, blue: 0.8)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.noiseReduction = 85

        let result = ImageRenderer().makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 40)
        XCTAssertEqual(result?.height, 20)
    }

    func testRendererUsesPerceptualLabColorPathForSaturation() {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 20)
        gradient.point1 = CGPoint(x: 40, y: 20)
        gradient.color0 = CIColor(red: 0.2, green: 0.4, blue: 0.8)
        gradient.color1 = CIColor(red: 0.8, green: 0.4, blue: 0.2)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.saturation = 80
        adjustments.vibrance = 40

        let renderer = ImageRenderer()
        let result = renderer.makePreview(image, adjustments: adjustments)
        let original = renderer.makePreview(image, adjustments: ImageAdjustments())

        XCTAssertEqual(result?.width, 40)
        XCTAssertEqual(result?.height, 20)
        guard let result, let original,
              let resultData = result.dataProvider?.data,
              let originalData = original.dataProvider?.data,
              let resultBytes = CFDataGetBytePtr(resultData),
              let originalBytes = CFDataGetBytePtr(originalData) else {
            XCTFail("Perceptual colour output was not rendered")
            return
        }
        XCTAssertNotEqual(resultBytes[10 * result.bytesPerRow + 20 * 4],
                          originalBytes[10 * original.bytesPerRow + 20 * 4])
    }

    func testAppleGPUKernelsCanProcessPreviewTextures() {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 32, y: 24)
        gradient.color0 = CIColor(red: 0.05, green: 0.15, blue: 0.75)
        gradient.color1 = CIColor(red: 0.9, green: 0.7, blue: 0.1)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let context = CIContext()
        XCTAssertNotNil(MetalImageProcessor.shared.nonLocalMeans(
            image, strength: 0.85, context: context
        ))
        XCTAssertNotNil(MetalImageProcessor.shared.labChroma(
            image, saturation: 0.6, vibrance: 0.3, context: context
        ))
        XCTAssertNotNil(MetalImageProcessor.shared.brownConrady(
            image, amount: 35, context: context
        ))
        let telea = MetalImageProcessor.shared.teleaInpaint(
            image, center: CGPoint(x: 16, y: 12), radius: 5, strength: 1, context: context
        )
        let poisson = MetalImageProcessor.shared.poissonClone(
            image, sourceCenter: CGPoint(x: 8, y: 8), targetCenter: CGPoint(x: 16, y: 12),
            radius: 5, strength: 1, context: context
        )
        XCTAssertNotNil(telea)
        XCTAssertNotNil(poisson)
        guard let original = context.createCGImage(image, from: image.extent),
              let telea, let teleaImage = context.createCGImage(telea, from: telea.extent),
              let poisson, let poissonImage = context.createCGImage(poisson, from: poisson.extent),
              let originalData = original.dataProvider?.data,
              let teleaData = teleaImage.dataProvider?.data,
              let poissonData = poissonImage.dataProvider?.data,
              let originalBytes = CFDataGetBytePtr(originalData),
              let teleaBytes = CFDataGetBytePtr(teleaData),
              let poissonBytes = CFDataGetBytePtr(poissonData) else {
            XCTFail("GPU repair kernels did not produce readable rasters")
            return
        }
        let byteCount = min(original.bytesPerRow * original.height,
                            min(teleaImage.bytesPerRow * teleaImage.height,
                                poissonImage.bytesPerRow * poissonImage.height))
        XCTAssertTrue((0..<byteCount).contains { originalBytes[$0] != teleaBytes[$0] })
        XCTAssertTrue((0..<byteCount).contains { originalBytes[$0] != poissonBytes[$0] })
    }

    func testAsyncMetalPreviewPipelineCompletesRepairWithoutBlockingWait() async {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 40, y: 30)
        gradient.color0 = CIColor(red: 0.1, green: 0.2, blue: 0.8)
        gradient.color1 = CIColor(red: 0.9, green: 0.7, blue: 0.1)
        let source = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        var adjustments = ImageAdjustments()
        adjustments.healSpots = [
            HealSpot(targetX: 0.5, targetY: 0.5, sourceX: 0.25, sourceY: 0.25,
                     radiusNorm: 0.12, strength: 1, useInpaint: true),
            HealSpot(targetX: 0.18, targetY: 0.18, sourceX: 0.78, sourceY: 0.78,
                     radiusNorm: 0.08, strength: 1, useInpaint: false)
        ]
        let preview = await ImageRenderer().makePreviewAsync(
            source, adjustments: adjustments, maxDimension: 900, quality: .interactive
        )
        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.width, 40)
        XCTAssertEqual(preview?.height, 30)
    }

    func testAsyncMetalPreviewReusesScratchTexturesAcrossRepeatedRenders() async {
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        var adjustments = ImageAdjustments()
        adjustments.noiseReduction = 70
        adjustments.saturation = 24
        adjustments.distortion = 12

        for _ in 0..<12 {
            let preview = await ImageRenderer.shared.makePreviewAsync(
                source, adjustments: adjustments, maxDimension: 256, quality: .interactive
            )
            XCTAssertNotNil(preview)
        }
    }

    func testThumbnailDecodeGateCancelsQueuedWaiterWithoutLeakingPermit() async {
        let gate = ThumbnailDecodeGate(limit: 1)
        let initiallyAcquired = await gate.acquire()
        XCTAssertTrue(initiallyAcquired)

        let waiting = Task { await gate.acquire() }
        await Task.yield()
        waiting.cancel()
        let waiterAcquired = await waiting.value
        XCTAssertFalse(waiterAcquired)

        await gate.release()
        let reacquired = await gate.acquire()
        XCTAssertTrue(reacquired)
        await gate.release()
    }

    func testProgressUpdateGateAlwaysPublishesFirstAndFinalUpdates() {
        let gate = ProgressUpdateGate(minimumInterval: 60)
        XCTAssertTrue(gate.shouldPublish(completed: 1, total: 10))
        XCTAssertFalse(gate.shouldPublish(completed: 2, total: 10))
        XCTAssertTrue(gate.shouldPublish(completed: 10, total: 10))
    }

    func testThumbnailDecodeCoordinatorSharesConcurrentRequests() async {
        let coordinator = ThumbnailDecodeCoordinator()
        let counter = LockedCounter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-thumbnail-coordinator.raw")

        let first = Task {
            await coordinator.image(for: url) {
                counter.increment()
                usleep(50_000)
                return nil
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let second = Task {
            await coordinator.image(for: url) {
                counter.increment()
                return nil
            }
        }

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(counter.count, 1)
    }

    func testThumbnailDecodeCoordinatorCancelsCallerWithoutWaitingForDecode() async {
        let coordinator = ThumbnailDecodeCoordinator()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-raw-thumbnail-cancel.raw")
        let request = Task {
            await coordinator.image(for: url) {
                usleep(200_000)
                return nil
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let start = Date()
        request.cancel()
        let result = await request.value

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.15)
    }

    func testPreviewRenderGateCancelsQueuedRenderWithoutReleasingActivePermit() async {
        let gate = PreviewRenderGate()
        let initiallyAcquired = await gate.acquire()
        XCTAssertTrue(initiallyAcquired)

        let waiting = Task { await gate.acquire() }
        await Task.yield()
        waiting.cancel()
        let waiterAcquired = await waiting.value
        XCTAssertFalse(waiterAcquired)

        await gate.release()
        let reacquired = await gate.acquire()
        XCTAssertTrue(reacquired)
        await gate.release()
    }

    func testMetalRepairPerformanceAndMemoryBudget() {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: 128, y: 128)
        gradient.color0 = CIColor(red: 0.1, green: 0.2, blue: 0.8)
        gradient.color1 = CIColor(red: 0.9, green: 0.7, blue: 0.1)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let context = CIContext()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            XCTAssertNotNil(MetalImageProcessor.shared.teleaInpaint(
                image, center: CGPoint(x: 64, y: 64), radius: 24, strength: 1, context: context
            ))
        }
    }

    func testRendererSupportsDistortionCorrection() {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: 20)
        gradient.point1 = CGPoint(x: 40, y: 20)
        gradient.color0 = CIColor(red: 1, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 1)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.distortion = 35

        let renderer = ImageRenderer()
        let result = renderer.makePreview(image, adjustments: adjustments)
        let original = renderer.makePreview(image, adjustments: ImageAdjustments())

        XCTAssertEqual(result?.width, 40)
        XCTAssertEqual(result?.height, 20)
        guard let result, let original,
              let resultData = result.dataProvider?.data,
              let originalData = original.dataProvider?.data,
              let resultBytes = CFDataGetBytePtr(resultData),
              let originalBytes = CFDataGetBytePtr(originalData) else {
            XCTFail("Distortion output was not rendered")
            return
        }
        let byteCount = result.bytesPerRow * result.height
        let changed = (0..<byteCount).contains { index in
            resultBytes[index] != originalBytes[index]
        }
        XCTAssertTrue(changed)
    }

    func testRendererAppliesLinearGradientToDifferentRows() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 20, height: 20))
        var adjustments = ImageAdjustments()
        adjustments.gradients = [LinearGradient(centerX: 0.5, centerY: 0.5,
                                                 angle: 0, range: 0.5,
                                                 exposure: 2)]

        guard let result = ImageRenderer().makePreview(image, adjustments: adjustments),
              let data = result.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            XCTFail("Gradient output was not rendered")
            return
        }
        let top = bytes[0]
        let bottom = bytes[(result.height - 1) * result.bytesPerRow]
        XCTAssertNotEqual(top, bottom)
    }

    func testRendererAppliesHealSpotWithoutChangingExtent() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        var adjustments = ImageAdjustments()
        adjustments.healSpots = [HealSpot(targetX: 0.5, targetY: 0.5,
                                          sourceX: 0.2, sourceY: 0.2,
                                          radiusNorm: 0.1)]

        let result = ImageRenderer().makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 32)
        XCTAssertEqual(result?.height, 24)
    }

    func testRendererAppliesTeleaInpaintWithoutChangingExtent() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        var adjustments = ImageAdjustments()
        adjustments.healSpots = [HealSpot(targetX: 0.5, targetY: 0.5,
                                          sourceX: 0.2, sourceY: 0.2,
                                          radiusNorm: 0.1, useInpaint: true)]

        let result = ImageRenderer().makePreview(image, adjustments: adjustments)

        XCTAssertEqual(result?.width, 32)
        XCTAssertEqual(result?.height, 24)
    }

    func testTeleaInpaintingPropagatesSurroundingColourIntoRepairRegion() {
        let size = 32
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let sourceContext = CGContext(data: nil, width: size, height: size,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("Could not create source bitmap")
            return
        }
        sourceContext.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.85, alpha: 1))
        sourceContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
        sourceContext.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        sourceContext.fillEllipse(in: CGRect(x: 11, y: 11, width: 10, height: 10))
        guard let source = sourceContext.makeImage(),
              let repaired = TeleaInpainting.inpaint(source, center: CGPoint(x: 16, y: 16), radius: 5) else {
            XCTFail("Telea inpainting did not produce an image")
            return
        }

        var outputBytes = [UInt8](repeating: 0, count: size * size * 4)
        guard let outputContext = CGContext(data: &outputBytes, width: size, height: size,
                                             bitsPerComponent: 8, bytesPerRow: size * 4,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("Could not create output bitmap")
            return
        }
        outputContext.draw(repaired, in: CGRect(x: 0, y: 0, width: size, height: size))
        let center = (16 * size + 16) * 4
        XCTAssertLessThan(outputBytes[center], 100)
        XCTAssertGreaterThan(outputBytes[center + 2], 150)
    }

    private func writeTestPNG(to url: URL, color: CIColor) throws {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw ImageExporterError.cannotRender }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageExporterError.cannotFinalize }
    }
}
