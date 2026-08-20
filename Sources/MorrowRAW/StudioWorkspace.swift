import AppKit
import SwiftUI

private enum LocalToolMode: Equatable {
    case none
    case heal
    case gradient
    case brush
    case colorChecker
}

struct StudioWorkspace: View {
    @ObservedObject var model: EditorViewModel
    @State private var activeTab = 0
    @State private var basicOpen = true
    @State private var naturalColorOpen = true
    @State private var referenceMatchOpen = true
    @State private var scopesOpen = false
    @State private var semanticOpen = false
    @State private var colorCheckerOpen = false
    @State private var colorOpen = true
    @State private var detailOpen = false
    @State private var geometryOpen = false
    @State private var gradientOpen = false
    @State private var healOpen = false
    @State private var brushOpen = false
    @State private var versionsOpen = false
    @State private var localTool: LocalToolMode = .none
    @State private var isBrushParameterEditing = false
    @State private var pendingHealTarget: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(model: model)
            HStack(spacing: 0) {
                StudioLibrary(model: model)
                    .frame(width: 224)
                Rectangle().fill(StudioUI.divider).frame(width: 1)
                StudioCanvas(model: model, localTool: $localTool, pendingHealTarget: $pendingHealTarget,
                             isBrushParameterEditing: isBrushParameterEditing)
                Rectangle().fill(StudioUI.divider).frame(width: 1)
                StudioInspector(model: model, activeTab: $activeTab,
                                basicOpen: $basicOpen, naturalColorOpen: $naturalColorOpen,
                                referenceMatchOpen: $referenceMatchOpen,
                                isBrushParameterEditing: $isBrushParameterEditing,
                                scopesOpen: $scopesOpen,
                                semanticOpen: $semanticOpen,
                                colorCheckerOpen: $colorCheckerOpen,
                                colorOpen: $colorOpen,
                                detailOpen: $detailOpen, geometryOpen: $geometryOpen,
                                gradientOpen: $gradientOpen, healOpen: $healOpen, brushOpen: $brushOpen,
                                versionsOpen: $versionsOpen,
                                localTool: $localTool, pendingHealTarget: $pendingHealTarget)
                    .frame(width: 332)
            }
            if !model.photos.isEmpty {
                Rectangle().fill(StudioUI.divider).frame(height: 1)
                StudioFilmstrip(model: model).frame(height: 132)
            }
        }
        .background(StudioUI.background)
        .foregroundStyle(StudioUI.primary)
        .environment(\.locale, model.language.locale)
        .overlay(alignment: .top) {
            if model.isSingleExporting {
                SingleExportProgressView()
                    .padding(.top, 58)
            } else if model.isExporting {
                BatchExportProgressView(model: model)
                    .padding(.top, 58)
            } else if model.isBatchAdjusting {
                BatchAdjustmentProgressView(model: model)
                    .padding(.top, 58)
            }
        }
        .alert(StudioText.photoOpenError, isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(StudioText.ok) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? StudioText.unknownError) }
        .sheet(isPresented: $model.showingPresetNameSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text(StudioText.addCustomPreset).font(.headline)
                TextField(StudioText.presetName, text: $model.presetNameDraft).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button(StudioText.cancel) { model.showingPresetNameSheet = false }; Button(StudioText.save) { model.saveNewCustomPreset() }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 360)
        }
    }
}

private struct SingleExportProgressView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(StudioText.exporting)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 5)
    }
}

private struct BatchExportProgressView: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(model.exportCompletedCount),
                         total: Double(max(1, model.exportTotalCount)))
                .frame(width: 150)
            Text(StudioText.exporting(model.exportCompletedCount, model.exportTotalCount))
                .font(.caption.monospacedDigit())
            Button(StudioText.cancel) { model.cancelBatchExport() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 5)
    }
}

private struct BatchAdjustmentProgressView: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: Double(model.batchAdjustmentCompleted),
                         total: Double(max(1, model.batchAdjustmentTotal)))
                .frame(width: 150)
            Text("\(StudioText.applyingAdjustments) \(model.batchAdjustmentCompleted)/\(model.batchAdjustmentTotal)")
                .font(.caption.monospacedDigit())
            Button(StudioText.cancel) { model.cancelBatchAdjustment() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 5)
    }
}

private struct StudioToolbar: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.title2).foregroundStyle(StudioUI.accent)
            Text("Morrow RAW").font(.headline)
            Divider().frame(height: 22)
            Button(StudioText.openFolder, action: model.openFolder).keyboardShortcut("o", modifiers: [.command, .shift])
            Button(StudioText.openPhoto, action: model.openPhoto).keyboardShortcut("o", modifiers: [.command])
            Spacer()
            Text(model.sourceName).font(.callout).foregroundStyle(StudioUI.secondary).lineLimit(1)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help(StudioText.undo)
                .keyboardShortcut("z", modifiers: [.command])
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help(StudioText.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button(StudioText.reset) { model.resetAllAdjustments() }
            Menu { exportMenu } label: { Label(StudioText.export, systemImage: "square.and.arrow.up") }
            .disabled(model.preview == nil || model.isExporting || model.isSingleExporting || model.isBatchAdjusting)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14).frame(height: 52)
        .background(StudioUI.panel)
    }

    @ViewBuilder private var exportMenu: some View {
        Button("JPEG…") { model.export(format: .jpeg) }
        Button("PNG…") { model.export(format: .png) }
        Button("TIFF…") { model.export(format: .tiff) }
        Button("BMP…") { model.export(format: .bmp) }
        if model.photos.count > 1 {
            Divider()
            Menu(StudioText.allPhotos) {
                Button("JPEG") { model.exportAll(format: .jpeg) }
                Button("PNG") { model.exportAll(format: .png) }
                Button("TIFF") { model.exportAll(format: .tiff) }
            }
        }
    }
}

private struct StudioLibrary: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StudioText.library).font(.title3.weight(.semibold)).padding(16)
            VStack(alignment: .leading, spacing: 5) {
                Button { model.openFolder() } label: { Label(StudioText.folder, systemImage: "folder") }
                Button { model.openPhoto() } label: { Label(StudioText.singlePhoto, systemImage: "photo") }
                Menu { 
                    if model.recentFolders.isEmpty { Text(StudioText.noHistory) }
                    else { ForEach(model.recentFolders, id: \.self) { path in Button(path) { model.openRecentFolder(path) } } }
                } label: { Label(StudioText.recentFolders, systemImage: "clock") }
            }
            .buttonStyle(.plain).padding(.horizontal, 16)
            Divider().padding(.vertical, 14)
            if let folder = model.currentFolderURL {
                Label(folder.lastPathComponent, systemImage: "square.grid.2x2")
                    .font(.callout.weight(.medium)).padding(.horizontal, 16)
            }
            Spacer()
            if let exif = model.adjustments.cachedExif {
                VStack(alignment: .leading, spacing: 7) {
                    Text(StudioText.photoInfo).font(.headline)
                    PhotoMetadataSummary(exif: exif)
                }.font(.caption).foregroundStyle(StudioUI.secondary).padding(16)
            }
        }.frame(maxHeight: .infinity, alignment: .topLeading).background(StudioUI.panel)
    }
}

private struct StudioCanvas: View {
    @ObservedObject var model: EditorViewModel
    @Binding var localTool: LocalToolMode
    @Binding var pendingHealTarget: CGPoint?
    let isBrushParameterEditing: Bool
    @State private var pointerLocation: CGPoint?
    @State private var draggingSourceIndex: Int?
    @State private var hoveredSourceIndex: Int?
    @State private var draggingGradientIndex: Int?
    @State private var hoveredGradientIndex: Int?
    @State private var drawingAdjustmentBrush = false
    @State private var magnificationStart: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panStartOffset: CGSize?
    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
            if model.beforeAfterEnabled,
               let preview = model.preview,
               let original = model.beforeAfterOriginalPreview {
                BeforeAfterPreview(edited: preview, original: original,
                                   position: Binding(get: { model.beforeAfterPosition },
                                                     set: { model.setBeforeAfterPosition($0) }),
                                   zoomScale: model.zoomScale,
                                   panOffset: $panOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
            } else if let preview = model.preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .scaleEffect(model.zoomScale)
                    .offset(panOffset)
                    .padding(28)
            } else { VStack(spacing: 10) { Image(systemName: "photo.on.rectangle").font(.system(size: 42)); Text(StudioText.openPhotoToEdit).font(.title3) }.foregroundStyle(StudioUI.secondary) }
            VStack {
                if model.isLoadingFolder {
                    HStack(spacing: 10) {
                        if model.folderTotalCount > 0 {
                            let progress = min(1, max(0, Double(model.folderLoadCount) / Double(model.folderTotalCount)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(StudioText.loadingPhotos(model.folderLoadCount, model.folderTotalCount))
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 150)
                            }
                        } else if model.folderScanEntryCount > 0 {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(StudioText.scanningFolder(model.folderScannedCount,
                                                               model.folderScanEntryCount))
                                ProgressView(value: Double(model.folderScannedCount),
                                             total: Double(model.folderScanEntryCount))
                                    .progressViewStyle(.linear)
                                    .frame(width: 150)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(StudioText.loadingPhotos(model.folderLoadCount, model.folderTotalCount))
                        }
                        Button(StudioText.cancel) { model.cancelFolderLoading() }
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(StudioText.localized("資料夾讀取進度", "Folder loading progress"))
                    .accessibilityValue(model.folderTotalCount > 0
                                        ? "\(model.folderLoadCount)/\(model.folderTotalCount)"
                                        : "\(model.folderScannedCount)/\(model.folderScanEntryCount)")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(14)
                }
                if model.isLoadingPhoto {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.isPhotoPreviewReady
                             ? StudioText.localized("預覽已載入，正在解碼原圖：\(model.sourceName)",
                                                    "Preview loaded; decoding original: \(model.sourceName)")
                             : StudioText.decoding(model.sourceName))
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.horizontal, 14)
                }
                if model.whiteBalancePickerEnabled {
                    HStack {
                        Label(StudioText.localized("白平衡取樣：請點擊照片", "White balance sampling: click the photo"),
                              systemImage: "eyedropper")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.72), in: Capsule())
                        Spacer()
                    }.padding(14)
                } else if localTool != .none {
                    HStack {
                        Label(localTool == .heal
                              ? (pendingHealTarget == nil
                                 ? StudioText.localized("仿製修補：第 1 步，點擊要移除的電線", "Clone heal: Step 1, click the wire to remove")
                                 : StudioText.localized("仿製修補：第 2 步，點擊乾淨天空作為來源", "Clone heal: Step 2, click clean sky as the source"))
                              : localTool == .gradient
                              ? StudioText.localized("漸層工具：紫色虛線是作用方向與範圍，請調整右側滑桿", "Gradient tool: the purple dashed line shows direction and range; adjust the sliders on the right")
                              : localTool == .brush
                              ? StudioText.localized("調整筆刷：在照片上拖曳塗抹，右側可調整羽化與基本參數", "Adjustment brush: paint over the photo; adjust feather and basic values on the right")
                              : StudioText.localized("ColorChecker：依序點擊 24 個色卡色塊", "ColorChecker: click the 24 chart patches in order"),
                              systemImage: localTool == .heal ? "paintbrush.pointed" : (localTool == .gradient ? "line.diagonal" : (localTool == .brush ? "paintbrush.fill" : "square.grid.3x3")))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.72), in: Capsule())
                        Spacer()
                    }.padding(14)
                }
                HStack { 
                    Spacer()
                    if !model.rgbHistogram.isEmpty {
                        VStack(alignment: .trailing, spacing: 3) {
                            RGBHistogramView(histogram: model.rgbHistogram).frame(width: 210, height: 88)
                            HStack(spacing: 8) {
                                Text("R").foregroundStyle(.red)
                                Text("G").foregroundStyle(.green)
                                Text("B").foregroundStyle(.blue)
                            }.font(.caption2.weight(.bold))
                        }.padding(12)
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { GeometryReader { geometry in
            ZStack {
                LocalToolMarkers(model: model, localTool: localTool,
                                 pointerLocation: pointerLocation,
                                 pendingHealTarget: pendingHealTarget,
                                 hoveredSourceIndex: hoveredSourceIndex,
                                 hoveredGradientIndex: hoveredGradientIndex,
                                 zoomScale: model.zoomScale,
                                 panOffset: panOffset,
                                 isBrushParameterEditing: isBrushParameterEditing)
                    .scaleEffect(model.zoomScale)
                    .offset(panOffset)
            }
            Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(!model.beforeAfterEnabled)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    pointerLocation = location
                    let point = normalizedPoint(from: location, in: geometry.size)
                    hoveredSourceIndex = model.healSpotIndexNearSource(point)
                    hoveredGradientIndex = model.gradientIndexNearCenter(point)
                case .ended:
                    pointerLocation = nil
                    hoveredSourceIndex = nil
                    hoveredGradientIndex = nil
                }
            }
            .onAppear { model.updatePreviewViewport(geometry.size) }
            .onChange(of: geometry.size) { newSize in
                model.updatePreviewViewport(newSize)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard model.preview == nil else { return }
                model.openPhoto()
            })
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                pointerLocation = value.location
                let point = normalizedPoint(from: value.location, in: geometry.size)
                if localTool == .heal, model.healingBrushEnabled {
                    if let draggingSourceIndex {
                        model.moveHealSource(at: draggingSourceIndex, to: point)
                        return
                    }
                    if let sourceIndex = model.healSpotIndexNearSource(point) {
                        model.beginInteractiveAdjustment()
                        draggingSourceIndex = sourceIndex
                        hoveredSourceIndex = sourceIndex
                        return
                    }
                }
                if localTool == .gradient {
                    if let draggingGradientIndex {
                        model.moveGradientCenter(at: draggingGradientIndex, to: point)
                        return
                    }
                    if let gradientIndex = model.gradientIndexNearCenter(point) {
                        model.beginInteractiveAdjustment()
                        draggingGradientIndex = gradientIndex
                        hoveredGradientIndex = gradientIndex
                        return
                    }
                }
                if localTool == .brush {
                    if !drawingAdjustmentBrush {
                        drawingAdjustmentBrush = true
                        model.beginAdjustmentBrush(at: point)
                    } else {
                        model.appendAdjustmentBrushPoint(point)
                    }
                    return
                }
                if localTool == .colorChecker {
                    return
                }
                if localTool == .none,
                   !model.healingBrushEnabled,
                   !model.whiteBalancePickerEnabled,
                   model.zoomScale > 1 {
                    if panStartOffset == nil { panStartOffset = panOffset }
                    let start = panStartOffset ?? panOffset
                    panOffset = clampedPanOffset(
                        CGSize(width: start.width + value.translation.width,
                               height: start.height + value.translation.height),
                        in: geometry.size,
                        zoomScale: model.zoomScale
                    )
                    return
                }
            }.onEnded { value in
                if panStartOffset != nil {
                    panStartOffset = nil
                    return
                }
                if draggingSourceIndex != nil {
                    draggingSourceIndex = nil
                    model.finishInteractiveAdjustment()
                    return
                }
                if draggingGradientIndex != nil {
                    draggingGradientIndex = nil
                    model.finishInteractiveAdjustment()
                    return
                }
                if drawingAdjustmentBrush {
                    drawingAdjustmentBrush = false
                    model.finishInteractiveAdjustment()
                    return
                }
                if localTool == .colorChecker {
                    let point = normalizedPoint(from: value.location, in: geometry.size)
                    model.captureColorCheckerSample(at: point)
                    return
                }
                guard model.whiteBalancePickerEnabled ||
                        (localTool == .heal && model.healingBrushEnabled) else { return }
                // SwiftUI uses a top-left origin while Core Image uses a bottom-left origin.
                let point = normalizedPoint(from: value.location, in: geometry.size)
                if model.whiteBalancePickerEnabled { model.pickWhiteBalance(at: point) }
                else if let target = pendingHealTarget {
                    model.addHealSpot(target: target, source: point)
                    pendingHealTarget = nil
                } else {
                    pendingHealTarget = point
                }
            }).simultaneousGesture(MagnificationGesture()
                .onChanged { value in
                    guard !model.healingBrushEnabled else { return }
                    if magnificationStart == nil { magnificationStart = model.zoomScale }
                    let start = magnificationStart ?? model.zoomScale
                    model.zoomScale = min(4, max(0.25, start * value))
                }
                .onEnded { _ in magnificationStart = nil }
            )
        }}
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Button("−") { model.zoomOut() }
                    .help(StudioText.zoomOut)
                    .accessibilityLabel(StudioText.zoomOut)
                Button(StudioText.fit) {
                    model.resetZoom()
                    panOffset = .zero
                }
                Text("\(Int(model.zoomScale * 100))%")
                    .monospacedDigit().frame(width: 48)
                Button("+") { model.zoomIn() }
                    .help(StudioText.zoomIn)
                    .accessibilityLabel(StudioText.zoomIn)
                Button(model.showOriginal ? StudioText.edited : StudioText.original) {
                    model.toggleShowOriginal()
                }
                Button(model.beforeAfterEnabled ? StudioText.closeBeforeAfter : StudioText.beforeAfter) {
                    model.toggleBeforeAfter()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.preview == nil || model.beforeAfterEnabled && model.beforeAfterOriginalPreview == nil)
            }
            .buttonStyle(.bordered)
            .padding(12)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        }
        .onChange(of: model.selectedIndex) { _ in
            panOffset = .zero
            panStartOffset = nil
        }
        .onChange(of: model.zoomScale) { scale in
            if scale <= 1 {
                panOffset = .zero
            } else {
                panStartOffset = nil
            }
        }
    }

    private func clampedPanOffset(_ offset: CGSize, in canvasSize: CGSize, zoomScale: CGFloat) -> CGSize {
        let limitX = max(0, canvasSize.width * (zoomScale - 1) * 0.5)
        let limitY = max(0, canvasSize.height * (zoomScale - 1) * 0.5)
        return CGSize(width: min(limitX, max(-limitX, offset.width)),
                      height: min(limitY, max(-limitY, offset.height)))
    }

    private func normalizedPoint(from screenPoint: CGPoint, in canvasSize: CGSize) -> CGPoint {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let logicalX = (screenPoint.x - center.x - panOffset.width) / max(0.001, model.zoomScale) + center.x
        let logicalY = (screenPoint.y - center.y - panOffset.height) / max(0.001, model.zoomScale) + center.y
        return CGPoint(x: logicalX / max(1, canvasSize.width),
                       y: 1 - logicalY / max(1, canvasSize.height))
    }
}

private struct BeforeAfterPreview: NSViewRepresentable {
    let edited: NSImage
    let original: NSImage
    @Binding var position: CGFloat
    let zoomScale: CGFloat
    @Binding var panOffset: CGSize

    func makeNSView(context: Context) -> ComparisonView {
        let view = ComparisonView()
        view.update(edited: edited, original: original, position: position,
                    zoomScale: zoomScale, panOffset: panOffset,
                    onPositionChanged: context.coordinator.onPositionChanged,
                    onPanChanged: context.coordinator.onPanChanged)
        return view
    }

    func updateNSView(_ nsView: ComparisonView, context: Context) {
        nsView.update(edited: edited, original: original, position: position,
                      zoomScale: zoomScale, panOffset: panOffset,
                      onPositionChanged: context.coordinator.onPositionChanged,
                      onPanChanged: context.coordinator.onPanChanged)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPositionChanged: { value in position = value },
                    onPanChanged: { value in panOffset = value })
    }

    final class Coordinator {
        let onPositionChanged: (CGFloat) -> Void
        let onPanChanged: (CGSize) -> Void
        init(onPositionChanged: @escaping (CGFloat) -> Void,
             onPanChanged: @escaping (CGSize) -> Void) {
            self.onPositionChanged = onPositionChanged
            self.onPanChanged = onPanChanged
        }
    }

    final class ComparisonView: NSView {
        private var editedImage: NSImage?
        private var originalImage: NSImage?
        private var position: CGFloat = 0.5
        private var zoomScale: CGFloat = 1
        private var panOffset: CGSize = .zero
        var onPositionChanged: ((CGFloat) -> Void)?
        var onPanChanged: ((CGSize) -> Void)?
        private var draggingDivider = false
        private var panStart: NSPoint?
        private var panStartOffset: CGSize = .zero

        override var isOpaque: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        func update(edited: NSImage, original: NSImage, position: CGFloat,
                    zoomScale: CGFloat, panOffset: CGSize,
                    onPositionChanged: @escaping (CGFloat) -> Void,
                    onPanChanged: @escaping (CGSize) -> Void) {
            editedImage = edited
            originalImage = original
            self.position = min(1, max(0, position))
            self.zoomScale = zoomScale
            self.panOffset = panOffset
            self.onPositionChanged = onPositionChanged
            self.onPanChanged = onPanChanged
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let splitX = bounds.minX + bounds.width * position
            if abs(point.x - splitX) <= 24 {
                draggingDivider = true
                updatePosition(with: event)
            } else if zoomScale > 1 {
                draggingDivider = false
                panStart = point
                panStartOffset = panOffset
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if draggingDivider {
                updatePosition(with: event)
            } else if let panStart {
                let point = convert(event.locationInWindow, from: nil)
                let proposed = CGSize(width: panStartOffset.width + point.x - panStart.x,
                                      height: panStartOffset.height + point.y - panStart.y)
                panOffset = clampedPanOffset(proposed)
                onPanChanged?(panOffset)
                needsDisplay = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            draggingDivider = false
            panStart = nil
        }

        private func updatePosition(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let value = min(1, max(0, point.x / max(1, bounds.width)))
            position = value
            onPositionChanged?(value)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let editedImage, let originalImage else { return }
            NSColor.black.setFill()
            dirtyRect.fill()
            let imageSize = editedImage.size
            let scale = min(bounds.width / max(1, imageSize.width),
                            bounds.height / max(1, imageSize.height)) * zoomScale
            let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let imageRect = NSRect(x: bounds.midX - drawSize.width / 2 + panOffset.width,
                                   y: bounds.midY - drawSize.height / 2 + panOffset.height,
                                   width: drawSize.width, height: drawSize.height)

            editedImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.saveGraphicsState()
            let splitX = bounds.minX + bounds.width * position
            NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY,
                                      width: max(0, splitX - bounds.minX), height: bounds.height)).addClip()
            originalImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.setFill()
            NSRect(x: splitX - 1, y: bounds.minY, width: 2, height: bounds.height).fill()
            NSBezierPath(roundedRect: NSRect(x: splitX - 14, y: bounds.midY - 21,
                                             width: 28, height: 42), xRadius: 14, yRadius: 14).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
                .shadow: {
                    let shadow = NSShadow(); shadow.shadowColor = NSColor.black; shadow.shadowBlurRadius = 3; return shadow
                }()
            ]
            NSString(string: StudioText.before).draw(at: NSPoint(x: bounds.minX + 12, y: bounds.maxY - 24), withAttributes: attributes)
            let after = NSString(string: StudioText.after)
            after.draw(at: NSPoint(x: bounds.maxX - after.size(withAttributes: attributes).width - 12,
                                   y: bounds.maxY - 24), withAttributes: attributes)
        }

        private func clampedPanOffset(_ offset: CGSize) -> CGSize {
            let limitX = max(0, bounds.width * (zoomScale - 1) * 0.5)
            let limitY = max(0, bounds.height * (zoomScale - 1) * 0.5)
            return CGSize(width: min(limitX, max(-limitX, offset.width)),
                          height: min(limitY, max(-limitY, offset.height)))
        }
    }
}

private struct StudioInspector: View {
    @ObservedObject var model: EditorViewModel
    @Binding var activeTab: Int
    @Binding var basicOpen: Bool
    @Binding var naturalColorOpen: Bool
    @Binding var referenceMatchOpen: Bool
    @Binding var isBrushParameterEditing: Bool
    @Binding var scopesOpen: Bool
    @Binding var semanticOpen: Bool
    @Binding var colorCheckerOpen: Bool
    @Binding var colorOpen: Bool
    @Binding var detailOpen: Bool
    @Binding var geometryOpen: Bool
    @Binding var gradientOpen: Bool
    @Binding var healOpen: Bool
    @Binding var brushOpen: Bool
    @Binding var versionsOpen: Bool
    @Binding var localTool: LocalToolMode
    @Binding var pendingHealTarget: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            Picker(StudioText.localized("檢查器分頁", "Inspector Tabs"), selection: $activeTab) {
                Text(StudioText.adjustments).tag(0)
                Text(StudioText.presets).tag(1)
                Text(StudioText.export).tag(2)
                Text(StudioText.info).tag(3)
                Text(StudioText.colorManagement).tag(4)
            }.pickerStyle(.segmented).padding(12)
            ScrollView {
                if activeTab == 0 { adjustmentTab }
                else if activeTab == 1 { presetTab }
                else if activeTab == 2 { exportTab }
                else if activeTab == 3 { infoTab }
                else { colorManagementTab }
            }
        }.background(StudioUI.panel)
    }

    @ViewBuilder private var adjustmentTab: some View {
        StudioSection(title: StudioText.localized("自然色彩助手", "Natural Color Assistant"),
                      systemImage: "wand.and.stars", isExpanded: $naturalColorOpen) {
            Text(StudioText.localized(
                "分析曝光、色偏與對比，產生可調整、可復原的色彩建議。",
                "Analyze exposure, color cast, and contrast into editable, undoable suggestions."
            ))
            .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button(model.isAnalyzingNaturalColor
                       ? StudioText.localized("分析中…", "Analyzing…")
                       : StudioText.localized("分析色彩", "Analyze Color")) {
                    model.suggestNaturalColor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isAnalyzingNaturalColor || model.preview == nil)
                Button(StudioText.localized("套用建議", "Apply Suggestion")) {
                    model.applyNaturalColorSuggestion()
                }
                .disabled(model.naturalColorSuggestion?.hasChanges != true)
                Button(StudioText.localized("清除", "Clear")) {
                    model.clearNaturalColorSuggestion()
                }
                .disabled(model.naturalColorSuggestion == nil)
            }
            if let suggestion = model.naturalColorSuggestion {
                HStack {
                    Text(StudioText.localized("信心度", "Confidence"))
                    Spacer()
                    Text("\(Int((suggestion.confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioUI.secondary)
                }
                StudioAdjustmentSlider(
                    title: StudioText.localized("建議強度", "Suggestion Strength"),
                    value: Binding(get: { model.naturalColorStrength * 100 },
                                   set: { model.naturalColorStrength = min(2, max(0, $0 / 100)) }),
                    range: 0...200,
                    onChange: {},
                    onEditingChanged: { _ in }
                )
                Text(StudioText.localized(
                    "演算法共識：\(suggestion.constancyMethods.joined(separator: "、"))；分歧 \(String(format: "%.1f°", suggestion.constancyAgreementDegrees))",
                    "Estimator consensus: \(suggestion.constancyMethods.joined(separator: ", ")); disagreement \(String(format: "%.1f°", suggestion.constancyAgreementDegrees))"
                ))
                .font(.caption2).foregroundStyle(StudioUI.secondary)
                if suggestion.reasons.isEmpty {
                    Text(StudioText.localized("目前影像已接近自然色彩基準。", "The image is already close to the natural color baseline."))
                        .font(.caption2).foregroundStyle(StudioUI.secondary)
                } else {
                    Text(suggestion.reasons.map(\.displayName).joined(separator: " · "))
                        .font(.caption2).foregroundStyle(StudioUI.secondary)
                }
                let exposure = String(format: "%+.2f", suggestion.exposureDelta)
                let temperature = String(format: "%+.0f", suggestion.temperatureDelta)
                let contrast = String(format: "%+.0f", suggestion.contrastDelta)
                Text(StudioText.localized(
                    "建議：曝光 \(exposure) EV、色溫 \(temperature) K、對比 \(contrast)",
                    "Suggested: Exposure \(exposure) EV, Temp \(temperature) K, Contrast \(contrast)"
                ))
                .font(.caption2).foregroundStyle(StudioUI.secondary)
            }
        }
        StudioSection(title: "Scopes", systemImage: "scope", isExpanded: $scopesOpen) {
            ColorScopesView(snapshot: model.colorScopes)
                .frame(maxWidth: .infinity)
            Button(StudioText.localized("更新 scopes", "Refresh Scopes")) {
                model.refreshColorScopes()
            }
            .buttonStyle(.bordered)
        }
        StudioSection(title: StudioText.localized("語意遮罩", "Semantic Masks"),
                      systemImage: "person.crop.rectangle.badge.plus", isExpanded: $semanticOpen) {
            Text(StudioText.localized(
                "使用 Vision 與離線色彩模型辨識人物、天空、皮膚與植物，結果會轉成可編輯筆刷。",
                "Use Vision and offline color models to detect people, sky, skin, and vegetation as editable brushes."
            ))
            .font(.caption).foregroundStyle(StudioUI.secondary)
            Button {
                model.analyzeSemanticRegions()
            } label: {
                Label(model.isAnalyzingSemanticRegions
                      ? StudioText.localized("分析中…", "Analyzing…")
                      : StudioText.localized("分析語意區域", "Analyze Regions"),
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.preview == nil || model.isAnalyzingSemanticRegions)
            ForEach(model.semanticRegions) { region in
                HStack {
                    Text(region.kind.displayName)
                    Spacer()
                    Text("\(Int((region.confidence * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioUI.secondary)
                    Button(StudioText.localized("建立筆刷", "Create Brush")) {
                        model.applySemanticRegion(region)
                    }
                }
                .font(.caption)
            }
        }
        StudioSection(title: StudioText.basic, systemImage: "slider.horizontal.3", isExpanded: $basicOpen) {
            slider(StudioText.localized("曝光", "Exposure"), $model.adjustments.exposure, -5...5); slider(StudioText.localized("對比", "Contrast"), $model.adjustments.contrast, -100...100); slider(StudioText.localized("亮部", "Highlights"), $model.adjustments.highlights, -100...100); slider(StudioText.localized("暗部", "Shadows"), $model.adjustments.shadows, -100...100); slider(StudioText.localized("白色", "Whites"), $model.adjustments.whites, -100...100); slider(StudioText.localized("黑色", "Blacks"), $model.adjustments.blacks, -100...100)
        }
        StudioSection(title: StudioText.color, systemImage: "paintpalette", isExpanded: $colorOpen) {
            slider(StudioText.localized("色溫", "Temperature"), $model.adjustments.temperature, 2000...12000); slider(StudioText.localized("色調", "Tint"), $model.adjustments.tint, -100...100)
            Button(model.whiteBalancePickerEnabled ? StudioText.localized("請在影像上取樣…", "Sample from image…") : StudioText.localized("白平衡滴管", "White Balance Picker")) { model.toggleWhiteBalancePicker() }
            slider(StudioText.localized("鮮豔度", "Vibrance"), $model.adjustments.vibrance, -100...100); slider(StudioText.localized("飽和度", "Saturation"), $model.adjustments.saturation, -100...100)
        }
        StudioSection(title: StudioText.detail, systemImage: "sparkles", isExpanded: $detailOpen) {
            slider(StudioText.localized("銳利度", "Sharpening"), $model.adjustments.sharpening, -100...100); slider(StudioText.localized("降噪", "Noise Reduction"), $model.adjustments.noiseReduction, 0...100); slider(StudioText.localized("暗角", "Vignette"), $model.adjustments.vignette, -100...100); slider(StudioText.localized("鏡頭變形", "Lens Distortion"), $model.adjustments.distortion, -100...100)
        }
        StudioSection(title: StudioText.geometry, systemImage: "crop", isExpanded: $geometryOpen) {
            Picker(StudioText.localized("比例", "Aspect Ratio"), selection: $model.adjustments.cropAspectRatio) { Text(StudioText.localized("原始", "Original")).tag("Original"); Text("3:2").tag("3:2"); Text("4:3").tag("4:3"); Text("16:9").tag("16:9"); Text("1:1").tag("1:1") }.onChange(of: model.adjustments.cropAspectRatio) { _ in model.scheduleRender() }
            HStack { TextField(StudioText.localized("自訂比例", "Custom Ratio"), text: $model.customCropRatio); Button(StudioText.localized("套用", "Apply")) { model.applyCustomCropRatio() } }
            slider(StudioText.localized("水平位置", "Horizontal Position"), $model.adjustments.cropX, 0...0.9); slider(StudioText.localized("垂直位置", "Vertical Position"), $model.adjustments.cropY, 0...0.9); slider(StudioText.localized("寬度", "Width"), $model.adjustments.cropWidth, 0.1...1); slider(StudioText.localized("高度", "Height"), $model.adjustments.cropHeight, 0.1...1); slider(StudioText.localized("角度", "Angle"), $model.adjustments.cropAngle, -45...45)
            HStack { Button(StudioText.localized("左轉", "Rotate Left")) { model.rotateLeft() }; Button(StudioText.localized("右轉", "Rotate Right")) { model.rotateRight() }; Button(StudioText.localized("重設裁切", "Reset Crop")) { model.resetCrop() } }
        }
        StudioSection(title: StudioText.localized("漸層工具", "Gradient Tool"), systemImage: "line.diagonal", isExpanded: $gradientOpen) {
            Text(StudioText.localized("漸層是獨立的局部調整工具，沿紫色方向逐步影響照片。", "The gradient is an independent local adjustment. Its purple direction shows the gradual effect across the photo."))
                .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button(StudioText.localized("新增漸層", "Add Gradient")) {
                    if model.healingBrushEnabled { model.toggleHealingBrush() }
                    pendingHealTarget = nil
                    model.addGradient()
                    localTool = .gradient
                }.buttonStyle(.borderedProminent)
                Button(StudioText.localized("結束漸層", "Finish Gradient")) { localTool = .none }
                    .disabled(localTool != .gradient)
                Button("−") { model.removeLastGradient() }
                    .disabled(model.adjustments.gradients.isEmpty)
            }
            Text(StudioText.localized("拖曳照片上的 G1 中心可移動範圍；紫色半透明區是羽化遮罩，顏色越深代表影響越強。", "Drag the G1 center to move the range. The purple dashed line shows direction; stronger color means a stronger effect."))
                .font(.caption2).foregroundStyle(StudioUI.secondary)
            if !model.adjustments.gradients.isEmpty {
                let index = model.adjustments.gradients.count - 1
                Text(StudioText.localized("目前編輯：G\(index + 1)", "Editing: G\(index + 1)")).font(.caption.weight(.semibold))
                slider(StudioText.localized("漸層曝光", "Gradient Exposure"), $model.adjustments.gradients[index].exposure, -2...2)
                slider(StudioText.localized("漸層對比", "Gradient Contrast"), $model.adjustments.gradients[index].contrast, StudioAdjustmentRange.contrast)
                slider(StudioText.localized("漸層亮部", "Gradient Highlights"), $model.adjustments.gradients[index].highlights, StudioAdjustmentRange.highlights)
                slider(StudioText.localized("漸層暗部", "Gradient Shadows"), $model.adjustments.gradients[index].shadows, StudioAdjustmentRange.shadows)
                slider(StudioText.localized("漸層飽和度", "Gradient Saturation"), $model.adjustments.gradients[index].saturation, StudioAdjustmentRange.saturation)
                slider(StudioText.localized("漸層角度", "Gradient Angle"), $model.adjustments.gradients[index].angle, -180...180)
                slider(StudioText.localized("漸層羽化寬度", "Gradient Feather"), $model.adjustments.gradients[index].range, 0.02...0.4)
            }
        }
        StudioSection(title: StudioText.localized("修補工具", "Heal Tool"), systemImage: "paintbrush.pointed", isExpanded: $healOpen) {
            Text(StudioText.localized("修補需要兩次點擊：先點要修復的目標（T），再點乾淨來源（S）。", "Healing uses two clicks: click the target to repair (T), then click a clean source (S)."))
                .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button {
                    if model.healingBrushEnabled { model.toggleHealingBrush(); localTool = .none; pendingHealTarget = nil }
                    else { localTool = .heal; model.toggleHealingBrush() }
                } label: {
                    Label(model.healingBrushEnabled ? StudioText.localized("結束修補", "Finish Healing") : StudioText.localized("自動修補", "Auto Heal"), systemImage: "paintbrush.pointed")
                }.buttonStyle(.borderedProminent)
                Button(StudioText.localized("取消工具", "Cancel Tool")) { if model.healingBrushEnabled { model.toggleHealingBrush() }; localTool = .none; pendingHealTarget = nil }
                    .disabled(localTool == .none)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(StudioText.localized("使用方式", "How to use")).font(.caption.weight(.semibold))
                Text(StudioText.localized("• 白色虛線圓圈：目前筆刷大小，只是游標。", "• White dashed circle: current brush size and cursor only."))
                Text(StudioText.localized("• 第一次點電線：設定目標位置（T）。", "• First click on the wire: set the target (T)."))
                Text(StudioText.localized("• 第二次點乾淨天空：設定來源位置（S），才會建立修補點。", "• Second click on clean sky: set the source (S) and create the heal spot."))
                Text(StudioText.localized("• T 與 S 的連線：表示天空會複製到電線。", "• The T–S line shows the source copied onto the target."))
            }.font(.caption2).foregroundStyle(StudioUI.secondary)
            StudioAdjustmentSlider(title: StudioText.localized("筆刷大小", "Brush Size"), value: $model.adjustments.healSize,
                                   range: 4...80,
                                   onChange: { model.scheduleRender(recordHistory: false) },
                                   onEditingChanged: { editing in
                                       if editing { model.beginInteractiveAdjustment() }
                                       else { model.finishInteractiveAdjustment() }
                                   })
            HStack {
                Label(StudioText.localized("修補點 \(model.adjustments.healSpots.count)", "Heal Spots \(model.adjustments.healSpots.count)"), systemImage: "circle.dotted")
                Spacer()
                Button(StudioText.localized("新增仿製點", "Add Clone Spot")) { model.addHealSpot(inpaint: false); localTool = .heal; pendingHealTarget = nil }
                Button(StudioText.localized("移除最後", "Remove Last")) { model.removeLastHealSpot() }.disabled(model.adjustments.healSpots.isEmpty)
                Button(StudioText.localized("清除全部", "Clear All")) { model.clearHealSpots() }.disabled(model.adjustments.healSpots.isEmpty)
            }
            if !model.adjustments.healSpots.isEmpty {
                let index = model.adjustments.healSpots.count - 1
                StudioAdjustmentSlider(title: StudioText.localized("目前修補強度", "Current Heal Strength"), value: Binding(
                    get: { model.adjustments.healSpots[index].strength * 100 },
                    set: { model.adjustments.healSpots[index].strength = min(1, max(0, $0 / 100)) }
                ), range: 0...100,
                onChange: { model.scheduleRender(recordHistory: false) },
                onEditingChanged: { editing in
                    if editing { model.beginInteractiveAdjustment() }
                    else { model.finishInteractiveAdjustment() }
                })
                Text(StudioText.localized("100% 完全套用來源；降低百分比可讓修補與原照片自然混合。", "100% fully applies the source; lower values blend the repair with the original."))
                    .font(.caption2).foregroundStyle(StudioUI.secondary)
            }
        }
        StudioSection(title: StudioText.localized("調整筆刷", "Adjustment Brush"), systemImage: "paintbrush.fill", isExpanded: $brushOpen) {
            Text(StudioText.localized("在照片上拖曳建立羽化遮罩，遮罩內的基本調整不會影響整張照片。",
                                     "Paint on the photo to create a feathered mask. Basic adjustments affect only the painted area."))
                .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button {
                    if model.healingBrushEnabled { model.toggleHealingBrush() }
                    pendingHealTarget = nil
                    localTool = .brush
                } label: {
                    Label(StudioText.localized("開始筆刷", "Brush On"), systemImage: "paintbrush.fill")
                }.buttonStyle(.borderedProminent)
                Button(StudioText.localized("結束筆刷", "Finish Brush")) { localTool = .none }
                    .disabled(localTool != .brush)
                Button("−") { model.removeLastAdjustmentBrush() }
                    .disabled(model.adjustments.adjustmentBrushes.isEmpty)
                Button(StudioText.localized("清除", "Clear")) { model.clearAdjustmentBrushes() }
                    .disabled(model.adjustments.adjustmentBrushes.isEmpty)
            }
            if !model.adjustments.adjustmentBrushes.isEmpty {
                let index = model.adjustments.adjustmentBrushes.count - 1
                Text(StudioText.localized("目前編輯：筆刷 (index + 1)", "Editing brush (index + 1)"))
                    .font(.caption.weight(.semibold))
                StudioAdjustmentSlider(title: StudioText.localized("筆刷大小", "Brush Size"), value: scaledBrushBinding(
                    index, keyPath: \.radiusNorm, scale: 1000, fallback: 0.045
                ), range: 8...160,
                onChange: { model.scheduleRender(recordHistory: false) },
                onEditingChanged: { editing in
                    isBrushParameterEditing = editing
                    if editing { model.beginInteractiveAdjustment() }
                    else { model.finishInteractiveAdjustment() }
                })
                StudioAdjustmentSlider(title: StudioText.localized("羽化", "Feather"), value: scaledBrushBinding(
                    index, keyPath: \.feather, scale: 100, fallback: 0.65
                ), range: 0...100,
                onChange: { model.scheduleRender(recordHistory: false) },
                onEditingChanged: { editing in
                    isBrushParameterEditing = editing
                    if editing { model.beginInteractiveAdjustment() }
                    else { model.finishInteractiveAdjustment() }
                })
                slider(StudioText.localized("局部曝光", "Local Exposure"), brushBinding(index, keyPath: \.exposure), -2...2, isBrushParameter: true)
                slider(StudioText.localized("局部對比", "Local Contrast"), brushBinding(index, keyPath: \.contrast), StudioAdjustmentRange.contrast, isBrushParameter: true)
                slider(StudioText.localized("局部亮部", "Local Highlights"), brushBinding(index, keyPath: \.highlights), StudioAdjustmentRange.highlights, isBrushParameter: true)
                slider(StudioText.localized("局部暗部", "Local Shadows"), brushBinding(index, keyPath: \.shadows), StudioAdjustmentRange.shadows, isBrushParameter: true)
                slider(StudioText.localized("局部白色", "Local Whites"), brushBinding(index, keyPath: \.whites), StudioAdjustmentRange.whites, isBrushParameter: true)
                slider(StudioText.localized("局部黑色", "Local Blacks"), brushBinding(index, keyPath: \.blacks), StudioAdjustmentRange.blacks, isBrushParameter: true)
                slider(StudioText.localized("局部色溫", "Local Temperature"), brushBinding(index, keyPath: \.temperature, fallback: 5200), 2000...12000, isBrushParameter: true)
                slider(StudioText.localized("局部色調", "Local Tint"), brushBinding(index, keyPath: \.tint), StudioAdjustmentRange.tint, isBrushParameter: true)
                slider(StudioText.localized("局部鮮豔度", "Local Vibrance"), brushBinding(index, keyPath: \.vibrance), StudioAdjustmentRange.vibrance, isBrushParameter: true)
                slider(StudioText.localized("局部飽和度", "Local Saturation"), brushBinding(index, keyPath: \.saturation), StudioAdjustmentRange.saturation, isBrushParameter: true)
            }
        }
        StudioSection(title: StudioText.versions, systemImage: "square.on.square", isExpanded: $versionsOpen) {
            HStack { Text(StudioText.localized("虛擬副本 \(model.virtualCopyIndex + 1)/\(max(1, model.virtualCopyCount))", "Virtual Copy \(model.virtualCopyIndex + 1)/\(max(1, model.virtualCopyCount))")); Spacer(); Button("←") { model.switchVirtualCopy(by: -1) }; Button(StudioText.localized("新增", "New")) { model.createVirtualCopy() }; Button("→") { model.switchVirtualCopy(by: 1) } }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        isBrushParameter: Bool = false) -> some View {
        StudioAdjustmentSlider(title: title, value: value, range: range,
                               onChange: { model.scheduleRender(recordHistory: false) },
                               onEditingChanged: { editing in
                                   if isBrushParameter { isBrushParameterEditing = editing }
                                   if editing { model.beginInteractiveAdjustment() }
                                   else { model.finishInteractiveAdjustment() }
                               })
    }

    private func brushBinding(
        _ index: Int,
        keyPath: WritableKeyPath<AdjustmentBrush, Double>,
        fallback: Double = 0
    ) -> Binding<Double> {
        Binding(
            get: {
                guard model.adjustments.adjustmentBrushes.indices.contains(index) else { return fallback }
                return model.adjustments.adjustmentBrushes[index][keyPath: keyPath]
            },
            set: { value in
                guard model.adjustments.adjustmentBrushes.indices.contains(index) else { return }
                model.adjustments.adjustmentBrushes[index][keyPath: keyPath] = value
            }
        )
    }

    private func scaledBrushBinding(
        _ index: Int,
        keyPath: WritableKeyPath<AdjustmentBrush, Double>,
        scale: Double,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { brushBinding(index, keyPath: keyPath, fallback: fallback).wrappedValue * scale },
            set: { value in
                brushBinding(index, keyPath: keyPath, fallback: fallback).wrappedValue = value / scale
            }
        )
    }

    @ViewBuilder private var colorManagementTab: some View {
        StudioSection(title: StudioText.localized("參考照片匹配", "Reference Match"),
                      systemImage: "photo.on.rectangle.angled", isExpanded: $referenceMatchOpen) {
            Text(StudioText.localized(
                "選擇一張參考照片，分析曝光、白平衡與色彩分布後產生可復原的建議。",
                "Choose a reference photo to generate an undoable match for exposure, white balance, and color distribution."
            ))
            .font(.caption).foregroundStyle(StudioUI.secondary)
            Button(StudioText.localized("選擇參考照片…", "Choose Reference Photo…")) {
                model.matchReferencePhoto()
            }
            .buttonStyle(.borderedProminent)
            if !model.referencePhotoName.isEmpty {
                Text(StudioText.localized("參考：\(model.referencePhotoName)", "Reference: \(model.referencePhotoName)"))
                    .font(.caption2).foregroundStyle(StudioUI.secondary)
            }
            if let suggestion = model.naturalColorSuggestion {
                Text(StudioText.localized(
                    "建議曝光 \(String(format: "%+.2f", suggestion.exposureDelta)) EV、色溫 \(String(format: "%+.0f", suggestion.temperatureDelta)) K、對比 \(String(format: "%+.0f", suggestion.contrastDelta))",
                    "Suggested Exposure \(String(format: "%+.2f", suggestion.exposureDelta)) EV, Temp \(String(format: "%+.0f", suggestion.temperatureDelta)) K, Contrast \(String(format: "%+.0f", suggestion.contrastDelta))"
                ))
                .font(.caption2).foregroundStyle(StudioUI.secondary)
                HStack {
                    Button(StudioText.localized("套用匹配", "Apply Match")) {
                        model.applyNaturalColorSuggestion()
                    }
                    .disabled(!suggestion.hasChanges)
                    Button(StudioText.localized("清除", "Clear")) {
                        model.clearNaturalColorSuggestion()
                    }
                }
            }
        }
        StudioSection(title: StudioText.localized("ColorChecker 校正", "ColorChecker Calibration"),
                      systemImage: "square.grid.3x3", isExpanded: $colorCheckerOpen) {
            Text(StudioText.localized(
                "依序點擊 24 個色卡色塊，建立相機色彩矩陣；校正結果會保存到 sidecar。",
                "Click the 24 chart patches in order to build a camera color matrix saved in the sidecar."
            ))
            .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button(StudioText.localized("開始取樣", "Start Sampling")) {
                    model.startColorCheckerCalibration()
                    localTool = .colorChecker
                }.buttonStyle(.borderedProminent)
                Button(StudioText.localized("完成校正", "Finish Calibration")) {
                    model.finishColorCheckerCalibration()
                    localTool = .none
                }
                .disabled(model.colorCheckerSamples.count < 3)
            }
            Text(StudioText.localized(
                "已取樣 \(model.colorCheckerSamples.count)/24",
                "Samples \(model.colorCheckerSamples.count)/24"
            ))
            .font(.caption2).foregroundStyle(StudioUI.secondary)
            if let profile = model.colorCheckerProfile {
                Text(StudioText.localized(
                    "已套用 \(profile.sampleCount) 個色卡樣本",
                    "Applied profile from \(profile.sampleCount) chart samples"
                ))
                .font(.caption2).foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder private var presetTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StudioText.localized("內建預設", "Built-in Presets")).font(.headline)
            ForEach(BuiltInPreset.allCases) { preset in Button(preset.displayName) { model.applyPreset(preset) }.frame(maxWidth: .infinity, alignment: .leading) }
            Divider(); Text(StudioText.localized("自訂預設", "Custom Presets")).font(.headline)
            ForEach(CustomPresetStore.names, id: \.self) { name in Button(name) { model.applyCustomPreset(name) }.frame(maxWidth: .infinity, alignment: .leading) }
            Button(StudioText.localized("新增自訂預設…", "New Custom Preset…")) { model.beginNewCustomPreset() }
            Button(StudioText.localized("匯入／匯出預設…", "Import/Export Presets…")) { model.exportCustomPresets() }
        }.padding(14).buttonStyle(.plain)
    }

    @ViewBuilder private var exportTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(StudioText.localized("浮水印", "Watermark"), isOn: $model.watermark.enabled)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(StudioText.jpegQuality)
                    Spacer()
                    Text("\(Int((model.exportQuality * 100).rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudioUI.secondary)
                }
                Slider(value: Binding(get: { model.exportQuality * 100 },
                                      set: { model.exportQuality = ($0.rounded()) / 100 }),
                       in: 10...100, step: 1)
                    .tint(StudioUI.accent)
            }
            Picker(StudioText.localized("長邊上限", "Long Edge Limit"), selection: $model.exportMaxLongEdge) { Text(StudioText.localized("原尺寸", "Original Size")).tag(0); Text("1200 px").tag(1200); Text("2400 px").tag(2400); Text("4000 px").tag(4000); Text("6000 px").tag(6000) }
            Picker("DPI", selection: $model.exportDPI) { Text("72").tag(CGFloat(72)); Text("150").tag(CGFloat(150)); Text("300").tag(CGFloat(300)); Text("600").tag(CGFloat(600)) }
            Toggle(StudioText.localized("保留 EXIF", "Preserve EXIF"), isOn: $model.preserveMetadata)
            Picker(StudioText.localized("介面外觀", "Appearance"), selection: $model.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue == "System" ? StudioText.localized("系統", "System") : ($0.rawValue == "Dark" ? StudioText.localized("深色", "Dark") : StudioText.localized("淺色", "Light"))).tag($0) } }
            Picker(StudioText.language, selection: $model.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
        }.padding(14)
    }

    @ViewBuilder private var infoTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.sourceName).font(.headline)
            if let exif = model.adjustments.cachedExif {
                PhotoMetadataSummary(exif: exif)
            } else {
                Text(StudioText.localized("尚無照片資訊", "No photo information"))
            }
        }.font(.callout).foregroundStyle(StudioUI.secondary).padding(14)
    }
}

private struct PhotoMetadataSummary: View {
    let exif: ExifData

    private var camera: String {
        [exif.cameraMake, exif.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func localizedMetadataValue(_ value: String) -> String {
        switch value {
        case "自動": return StudioText.localized("自動", "Auto")
        case "手動": return StudioText.localized("手動", "Manual")
        case "平均": return StudioText.localized("平均", "Average")
        case "中央重點": return StudioText.localized("中央重點", "Center-weighted")
        case "點測光": return StudioText.localized("點測光", "Spot")
        case "多點測光": return StudioText.localized("多點測光", "Multi-segment")
        case "矩陣／多區": return StudioText.localized("矩陣／多區", "Matrix/Multi-area")
        case "局部": return StudioText.localized("局部", "Partial")
        case "其他": return StudioText.localized("其他", "Other")
        default: return value
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String, _ icon: String) -> some View {
        if !value.isEmpty {
            Label("\(title)：\(value)", systemImage: icon)
                .lineLimit(2)
                .help(value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(StudioText.localized("相機", "Camera"), camera, "camera")
            row(StudioText.localized("鏡頭", "Lens"), exif.lens, "camera.aperture")
            row(StudioText.localized("拍攝時間", "Date Taken"), PhotoMetadataReader.displayDate(exif.dateTaken), "calendar")
            row(StudioText.localized("焦距", "Focal Length"), exif.focalLength, "ruler")
            row(StudioText.localized("光圈", "Aperture"), exif.aperture, "circle.dotted")
            row(StudioText.localized("快門", "Shutter"), exif.shutter, "timer")
            row(StudioText.localized("感光度", "ISO"), exif.iso.isEmpty ? "" : "ISO \(exif.iso)", "sun.max")
            row(StudioText.localized("曝光補償", "Exposure Bias"), exif.exposureBias, "plusminus")
            row(StudioText.localized("對焦模式", "Focus Mode"), exif.focusMode, "scope")
            row(StudioText.localized("白平衡", "White Balance"), localizedMetadataValue(exif.whiteBalance), "thermometer.sun")
            row(StudioText.localized("測光模式", "Metering Mode"), localizedMetadataValue(exif.meteringMode), "camera.aperture")
            if exif.fileSize > 0 {
                row(StudioText.localized("檔案大小", "File Size"), String(format: "%.2f MB", Double(exif.fileSize) / 1_048_576), "doc")
            }
            if exif.width > 0 && exif.height > 0 {
                Label(StudioText.localized("尺寸：\(exif.width) × \(exif.height) px", "Dimensions: \(exif.width) × \(exif.height) px"), systemImage: "aspectratio")
            }
        }
    }
}

private struct LocalToolMarkers: View {
    @ObservedObject var model: EditorViewModel
    let localTool: LocalToolMode
    let pointerLocation: CGPoint?
    let pendingHealTarget: CGPoint?
    let hoveredSourceIndex: Int?
    let hoveredGradientIndex: Int?
    let zoomScale: CGFloat
    let panOffset: CGSize
    let isBrushParameterEditing: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Array(model.adjustments.healSpots.enumerated()), id: \.offset) { _, spot in
                    let target = CGPoint(x: spot.targetX * geometry.size.width,
                                          y: (1 - spot.targetY) * geometry.size.height)
                    let source = CGPoint(x: spot.sourceX * geometry.size.width,
                                          y: (1 - spot.sourceY) * geometry.size.height)
                    Path { path in
                        path.move(to: target)
                        path.addLine(to: source)
                    }.stroke(Color.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                ForEach(Array(model.adjustments.healSpots.enumerated()), id: \.offset) { index, spot in
                    let point = CGPoint(x: spot.targetX * geometry.size.width,
                                        y: (1 - spot.targetY) * geometry.size.height)
                    ZStack {
                        Circle().stroke(spot.useInpaint ? Color.orange : Color.cyan, lineWidth: 2)
                            .frame(width: max(22, spot.radiusNorm * min(geometry.size.width, geometry.size.height) * 2),
                                   height: max(22, spot.radiusNorm * min(geometry.size.width, geometry.size.height) * 2))
                        Text("\(index + 1)").font(.caption2.bold()).padding(4)
                            .background(.black.opacity(0.75), in: Circle())
                    }.position(point)
                    Text("S").font(.caption2.bold()).padding(hoveredSourceIndex == index ? 7 : 4)
                        .background(hoveredSourceIndex == index ? Color.white.opacity(0.9) : Color.black.opacity(0.8), in: Circle())
                        .foregroundStyle(hoveredSourceIndex == index ? .black : .cyan)
                        .position(CGPoint(x: spot.sourceX * geometry.size.width,
                                          y: (1 - spot.sourceY) * geometry.size.height))
                }
                ForEach(Array(model.adjustments.gradients.enumerated()), id: \.offset) { index, gradient in
                    GradientGuide(gradient: gradient, index: index,
                                  size: geometry.size,
                                  isActive: localTool == .gradient,
                                  isHovered: hoveredGradientIndex == index)
                }
                if localTool == .brush && !isBrushParameterEditing &&
                    !model.adjustments.adjustmentBrushes.isEmpty {
                    BrushMaskOverlay(brushes: model.adjustments.adjustmentBrushes,
                                     size: geometry.size)
                }
                if localTool == .heal, let pendingHealTarget {
                    let point = CGPoint(x: pendingHealTarget.x * geometry.size.width,
                                        y: (1 - pendingHealTarget.y) * geometry.size.height)
                    Circle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 32, height: 32)
                        .overlay(Text("T").font(.caption2.bold()).foregroundStyle(.yellow))
                        .position(point)
                }
                if localTool == .heal, model.healingBrushEnabled, let pointerLocation {
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let logicalPoint = CGPoint(
                        x: (pointerLocation.x - center.x - panOffset.width) / max(0.001, zoomScale) + center.x,
                        y: (pointerLocation.y - center.y - panOffset.height) / max(0.001, zoomScale) + center.y
                    )
                    Circle().stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: max(24, model.adjustments.healSize * 2) / max(0.001, zoomScale),
                               height: max(24, model.adjustments.healSize * 2) / max(0.001, zoomScale))
                        .position(logicalPoint)
                        .shadow(color: .black, radius: 2)
                }
                if localTool == .brush, !isBrushParameterEditing, let pointerLocation {
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let logicalPoint = CGPoint(
                        x: (pointerLocation.x - center.x - panOffset.width) / max(0.001, zoomScale) + center.x,
                        y: (pointerLocation.y - center.y - panOffset.height) / max(0.001, zoomScale) + center.y
                    )
                    let radiusNorm = model.adjustments.adjustmentBrushes.last?.radiusNorm ?? 0.045
                    let diameter = max(16, radiusNorm * max(geometry.size.width, geometry.size.height) * 2)
                    let radius = diameter / max(0.001, zoomScale) / 2
                    Circle()
                        .fill(RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.yellow.opacity(0.16), location: 0),
                                .init(color: Color.yellow.opacity(0.10), location: 0.45),
                                .init(color: .clear, location: 1)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        ))
                        .overlay(Circle().stroke(Color.white.opacity(0.85),
                                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                        .frame(width: diameter / max(0.001, zoomScale),
                               height: diameter / max(0.001, zoomScale))
                        .position(logicalPoint)
                        .shadow(color: .black, radius: 2)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

private struct BrushMaskOverlay: View {
    let brushes: [AdjustmentBrush]
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            // Draw the mist as a union mask. A normal source-over pass would
            // accumulate alpha every time a stroke crosses itself, making the
            // overlay look like it is painting over the photograph.
            context.drawLayer { fog in
                fog.blendMode = .lighten
                drawFog(for: brushes, in: &fog)
            }
            drawGuides(for: brushes, in: &context)
        }
        .allowsHitTesting(false)
    }

    private func drawFog(for brushes: [AdjustmentBrush], in context: inout GraphicsContext) {
        for (index, brush) in brushes.enumerated() {
            let isActive = index == brushes.count - 1
            let color = isActive ? Color.yellow : Color.white
            let opacity = isActive ? 0.12 : 0.045
            let radius = max(1, brush.radiusNorm * max(size.width, size.height))
            let feather = min(1, max(0, brush.feather))
            let solidEnd = max(0, min(1, 1 - feather))
            let points = sampledPoints(for: brush)
            guard !points.isEmpty else { continue }

            for point in points {
                let center = CGPoint(x: point.x * size.width,
                                     y: (1 - point.y) * size.height)
                let rect = CGRect(x: center.x - radius,
                                  y: center.y - radius,
                                  width: radius * 2,
                                  height: radius * 2)
                let gradient = Gradient(stops: [
                    .init(color: color.opacity(opacity), location: 0),
                    .init(color: color.opacity(opacity * 0.9), location: solidEnd),
                    .init(color: .clear, location: 1)
                ])
                context.fill(Path(ellipseIn: rect), with: .radialGradient(
                    gradient, center: center, startRadius: 0, endRadius: radius
                ))
            }
        }
    }

    private func drawGuides(for brushes: [AdjustmentBrush], in context: inout GraphicsContext) {
            for (index, brush) in brushes.enumerated() {
                let isActive = index == brushes.count - 1
                let color = isActive ? Color.yellow : Color.white
                let points = sampledPoints(for: brush)
                guard !points.isEmpty else { continue }
                if let first = points.first {
                    var path = Path()
                    path.move(to: CGPoint(x: first.x * size.width,
                                          y: (1 - first.y) * size.height))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x * size.width,
                                                 y: (1 - point.y) * size.height))
                    }
                    context.stroke(path, with: .color(color.opacity(isActive ? 0.62 : 0.2)),
                                   style: StrokeStyle(lineWidth: isActive ? 1.5 : 1,
                                                      dash: isActive ? [5, 4] : [3, 5]))
                }
            }
    }

    private func sampledPoints(for brush: AdjustmentBrush) -> [AdjustmentBrushPoint] {
        guard brush.points.count > 240 else { return brush.points }
        let strideSize = max(1, Int(ceil(Double(brush.points.count) / 240)))
        var result = brush.points.enumerated().compactMap { index, point in
            index % strideSize == 0 ? point : nil
        }
        if let last = brush.points.last, result.last != last { result.append(last) }
        return result
    }
}

private struct GradientGuide: View {
    let gradient: LinearGradient
    let index: Int
    let size: CGSize
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        let point = CGPoint(x: gradient.centerX * size.width,
                            y: (1 - gradient.centerY) * size.height)
        let radians = CGFloat(gradient.angle * .pi / 180)
        let distance = max(24, CGFloat(gradient.range) * max(size.width, size.height))
        let direction = CGPoint(x: sin(radians) * distance, y: -cos(radians) * distance)
        let start = CGPoint(x: point.x - direction.x, y: point.y - direction.y)
        let end = CGPoint(x: point.x + direction.x, y: point.y + direction.y)
        let unit = CGPoint(x: direction.x / distance, y: direction.y / distance)
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)
        let arrowLength = min(18, distance * 0.45)
        let arrowBase = CGPoint(x: end.x - unit.x * arrowLength,
                                y: end.y - unit.y * arrowLength)

        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
                path.move(to: end)
                path.addLine(to: CGPoint(x: arrowBase.x + perpendicular.x * arrowLength * 0.45,
                                         y: arrowBase.y + perpendicular.y * arrowLength * 0.45))
                path.move(to: end)
                path.addLine(to: CGPoint(x: arrowBase.x - perpendicular.x * arrowLength * 0.45,
                                         y: arrowBase.y - perpendicular.y * arrowLength * 0.45))
            }.stroke(isHovered ? Color.white : Color.purple,
                     style: StrokeStyle(lineWidth: isHovered ? 3 : 2, lineCap: .round, dash: [7, 5]))
            ZStack {
                Circle().stroke(isHovered ? Color.white : Color.purple, lineWidth: isHovered ? 3 : 2)
                    .frame(width: 28, height: 28)
                Text("G\(index + 1)").font(.caption2.bold()).padding(4)
                    .background(.black.opacity(0.75), in: Capsule())
            }.position(point)
        }
    }
}

private struct StudioFilmstrip: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 5) { Text(StudioText.filmstrip).font(.caption).foregroundStyle(StudioUI.secondary); Text(StudioText.photoCount(model.photos.count)).font(.caption2) }.frame(width: 60)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { LazyHStack(spacing: 8) { ForEach(Array(model.photos.enumerated()), id: \.element) { index, url in
                    VStack(spacing: 3) { Button { model.selectPhoto(at: index) } label: { StudioThumbnail(url: url, size: CGSize(width: 132, height: 80)) }.buttonStyle(.plain).accessibilityLabel(url.lastPathComponent).accessibilityValue(index == model.selectedIndex ? StudioText.localized("目前照片", "Current photo") : StudioText.localized("照片", "Photo")); Text(url.lastPathComponent).font(.caption2).lineLimit(1).frame(width: 132); Toggle(StudioText.selected, isOn: Binding(get: { model.selectedPhotoIndices.contains(index) }, set: { model.setPhotoSelection(at: index, selected: $0) })).toggleStyle(.checkbox).font(.caption2) }
                        .padding(5).background(index == model.selectedIndex ? StudioUI.accent.opacity(0.28) : StudioUI.raised).clipShape(RoundedRectangle(cornerRadius: 5))
                        .id(index)
                } } }.padding(.vertical, 8)
                    .onChange(of: model.selectedIndex) { index in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
            }
            if model.photos.count > 1 {
                Menu {
                    Section("\(StudioText.selected)（\(model.selectedPhotoIndices.count)）") {
                        Button(StudioText.selectAll) { model.selectAllPhotos() }
                        Button(StudioText.clearSelection) { model.clearPhotoSelection() }
                        Divider()
                        Button(StudioText.copy) { model.copyCurrentAdjustmentsToSelected() }
                            .disabled(model.selectedPhotoIndices.isEmpty)
                        ForEach(BuiltInPreset.allCases) { preset in
                            Button("\(preset.displayName) → \(StudioText.selected)") {
                                model.applyPresetToSelected(preset)
                            }
                            .disabled(model.selectedPhotoIndices.isEmpty)
                        }
                    }
                    Divider()
                    Section(StudioText.allPhotos.replacingOccurrences(of: "…", with: "")) {
                        Button(StudioText.copy) { model.copyCurrentAdjustmentsToAll() }
                        ForEach(BuiltInPreset.allCases) { preset in
                            Button("\(preset.displayName) → \(StudioText.allPhotos.replacingOccurrences(of: "…", with: ""))") {
                                model.applyPresetToAll(preset)
                            }
                        }
                    }
                } label: {
                    Label(StudioText.batch, systemImage: "square.stack.3d.up")
                }
                .disabled(model.isBatchAdjusting || model.isExporting || model.isSingleExporting)
            }
        }.padding(.horizontal, 12).background(StudioUI.panel)
    }
}
