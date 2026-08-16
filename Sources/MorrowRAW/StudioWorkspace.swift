import AppKit
import SwiftUI

private enum LocalToolMode: Equatable {
    case none
    case heal
    case gradient
}

struct StudioWorkspace: View {
    @ObservedObject var model: EditorViewModel
    @State private var activeTab = 0
    @State private var basicOpen = true
    @State private var colorOpen = true
    @State private var detailOpen = false
    @State private var geometryOpen = false
    @State private var gradientOpen = false
    @State private var healOpen = false
    @State private var versionsOpen = false
    @State private var localTool: LocalToolMode = .none
    @State private var pendingHealTarget: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(model: model)
            HStack(spacing: 0) {
                StudioLibrary(model: model)
                    .frame(width: 224)
                Rectangle().fill(StudioUI.divider).frame(width: 1)
                StudioCanvas(model: model, localTool: $localTool, pendingHealTarget: $pendingHealTarget)
                Rectangle().fill(StudioUI.divider).frame(width: 1)
                StudioInspector(model: model, activeTab: $activeTab,
                                basicOpen: $basicOpen, colorOpen: $colorOpen,
                                detailOpen: $detailOpen, geometryOpen: $geometryOpen,
                                gradientOpen: $gradientOpen, healOpen: $healOpen,
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
            if model.isExporting {
                BatchExportProgressView(model: model)
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
            .disabled(model.preview == nil || model.isExporting)
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
    @State private var pointerLocation: CGPoint?
    @State private var draggingSourceIndex: Int?
    @State private var hoveredSourceIndex: Int?
    @State private var draggingGradientIndex: Int?
    @State private var hoveredGradientIndex: Int?
    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
            if model.beforeAfterEnabled,
               let preview = model.preview,
               let original = model.beforeAfterOriginalPreview {
                BeforeAfterPreview(edited: preview, original: original,
                                   position: Binding(get: { model.beforeAfterPosition },
                                                     set: { model.setBeforeAfterPosition($0) }),
                                   zoomScale: model.zoomScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
            } else if let preview = model.preview {
                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).scaleEffect(model.zoomScale).padding(28)
            } else { VStack(spacing: 10) { Image(systemName: "photo.on.rectangle").font(.system(size: 42)); Text(StudioText.openPhotoToEdit).font(.title3) }.foregroundStyle(StudioUI.secondary) }
            VStack {
                if model.isLoadingFolder {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(StudioText.loadingPhotos(model.folderLoadCount, model.folderTotalCount))
                        Button(StudioText.cancel) { model.cancelFolderLoading() }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(14)
                }
                if model.isLoadingPhoto {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(StudioText.decoding(model.sourceName))
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.horizontal, 14)
                }
                if localTool != .none {
                    HStack {
                        Label(localTool == .heal
                              ? (pendingHealTarget == nil ? "仿製修補：第 1 步，點擊要移除的電線" : "仿製修補：第 2 步，點擊乾淨天空作為來源")
                              : "漸層工具：紫色虛線是作用方向與範圍，請調整右側滑桿",
                              systemImage: localTool == .heal ? "paintbrush.pointed" : "line.diagonal")
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
                                 hoveredGradientIndex: hoveredGradientIndex)
            }
            Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(!model.beforeAfterEnabled)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    pointerLocation = location
                    let point = CGPoint(x: location.x / geometry.size.width,
                                        y: 1 - location.y / geometry.size.height)
                    hoveredSourceIndex = model.healSpotIndexNearSource(point)
                    hoveredGradientIndex = model.gradientIndexNearCenter(point)
                case .ended:
                    pointerLocation = nil
                    hoveredSourceIndex = nil
                    hoveredGradientIndex = nil
                }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard model.preview == nil else { return }
                model.openPhoto()
            })
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                pointerLocation = value.location
                let point = CGPoint(x: value.location.x / geometry.size.width,
                                    y: 1 - value.location.y / geometry.size.height)
                if localTool == .heal, model.healingBrushEnabled {
                    if let draggingSourceIndex {
                        model.moveHealSource(at: draggingSourceIndex, to: point)
                        return
                    }
                    if let sourceIndex = model.healSpotIndexNearSource(point) {
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
                        draggingGradientIndex = gradientIndex
                        hoveredGradientIndex = gradientIndex
                        return
                    }
                }
            }.onEnded { value in
                if draggingSourceIndex != nil {
                    draggingSourceIndex = nil
                    return
                }
                if draggingGradientIndex != nil {
                    draggingGradientIndex = nil
                    return
                }
                guard localTool == .heal, model.healingBrushEnabled else { return }
                // SwiftUI uses a top-left origin while Core Image uses a bottom-left origin.
                let point = CGPoint(x: value.location.x / geometry.size.width,
                                    y: 1 - value.location.y / geometry.size.height)
                if model.whiteBalancePickerEnabled { model.pickWhiteBalance(at: point) }
                else if let target = pendingHealTarget {
                    model.addHealSpot(target: target, source: point)
                    pendingHealTarget = nil
                } else {
                    pendingHealTarget = point
                }
            }).simultaneousGesture(MagnificationGesture().onChanged { value in
                guard !model.healingBrushEnabled else { return }; model.zoomScale = min(4, max(0.25, value))
            })
        }}
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Button("−") { model.zoomOut() }.help(StudioText.zoomOut)
                Button(StudioText.fit) { model.resetZoom() }
                Text("\(Int(model.zoomScale * 100))%")
                    .monospacedDigit().frame(width: 48)
                Button("+") { model.zoomIn() }.help(StudioText.zoomIn)
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
    }
}

private struct BeforeAfterPreview: NSViewRepresentable {
    let edited: NSImage
    let original: NSImage
    @Binding var position: CGFloat
    let zoomScale: CGFloat

    func makeNSView(context: Context) -> ComparisonView {
        let view = ComparisonView()
        view.update(edited: edited, original: original, position: position,
                    zoomScale: zoomScale, onPositionChanged: context.coordinator.onPositionChanged)
        return view
    }

    func updateNSView(_ nsView: ComparisonView, context: Context) {
        nsView.update(edited: edited, original: original, position: position,
                      zoomScale: zoomScale, onPositionChanged: context.coordinator.onPositionChanged)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator { value in position = value }
    }

    final class Coordinator {
        let onPositionChanged: (CGFloat) -> Void
        init(onPositionChanged: @escaping (CGFloat) -> Void) {
            self.onPositionChanged = onPositionChanged
        }
    }

    final class ComparisonView: NSView {
        private var editedImage: NSImage?
        private var originalImage: NSImage?
        private var position: CGFloat = 0.5
        private var zoomScale: CGFloat = 1
        var onPositionChanged: ((CGFloat) -> Void)?

        override var isOpaque: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        func update(edited: NSImage, original: NSImage, position: CGFloat,
                    zoomScale: CGFloat, onPositionChanged: @escaping (CGFloat) -> Void) {
            editedImage = edited
            originalImage = original
            self.position = min(1, max(0, position))
            self.zoomScale = zoomScale
            self.onPositionChanged = onPositionChanged
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            updatePosition(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            updatePosition(with: event)
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
            let imageRect = NSRect(x: bounds.midX - drawSize.width / 2,
                                   y: bounds.midY - drawSize.height / 2,
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
    }
}

private struct StudioInspector: View {
    @ObservedObject var model: EditorViewModel
    @Binding var activeTab: Int
    @Binding var basicOpen: Bool
    @Binding var colorOpen: Bool
    @Binding var detailOpen: Bool
    @Binding var geometryOpen: Bool
    @Binding var gradientOpen: Bool
    @Binding var healOpen: Bool
    @Binding var versionsOpen: Bool
    @Binding var localTool: LocalToolMode
    @Binding var pendingHealTarget: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $activeTab) { Text(StudioText.adjustments).tag(0); Text(StudioText.presets).tag(1); Text(StudioText.export).tag(2); Text(StudioText.info).tag(3) }.pickerStyle(.segmented).padding(12)
            ScrollView {
                if activeTab == 0 { adjustmentTab }
                else if activeTab == 1 { presetTab }
                else if activeTab == 2 { exportTab }
                else { infoTab }
            }
        }.background(StudioUI.panel)
    }

    @ViewBuilder private var adjustmentTab: some View {
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
            Picker("比例", selection: $model.adjustments.cropAspectRatio) { Text("原始").tag("Original"); Text("3:2").tag("3:2"); Text("4:3").tag("4:3"); Text("16:9").tag("16:9"); Text("1:1").tag("1:1") }.onChange(of: model.adjustments.cropAspectRatio) { _ in model.scheduleRender() }
            HStack { TextField("自訂比例", text: $model.customCropRatio); Button("套用") { model.applyCustomCropRatio() } }
            slider("水平位置", $model.adjustments.cropX, 0...0.9); slider("垂直位置", $model.adjustments.cropY, 0...0.9); slider("寬度", $model.adjustments.cropWidth, 0.1...1); slider("高度", $model.adjustments.cropHeight, 0.1...1); slider("角度", $model.adjustments.cropAngle, -45...45)
            HStack { Button("左轉") { model.rotateLeft() }; Button("右轉") { model.rotateRight() }; Button("重設裁切") { model.resetCrop() } }
        }
        StudioSection(title: "漸層工具", systemImage: "line.diagonal", isExpanded: $gradientOpen) {
            Text("漸層是獨立的局部調整工具，沿紫色方向逐步影響照片。")
                .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button("新增漸層") {
                    if model.healingBrushEnabled { model.toggleHealingBrush() }
                    pendingHealTarget = nil
                    model.addGradient()
                    localTool = .gradient
                }.buttonStyle(.borderedProminent)
                Button("結束漸層") { localTool = .none }
                    .disabled(localTool != .gradient)
                Button("−") { model.removeLastGradient() }
                    .disabled(model.adjustments.gradients.isEmpty)
            }
            Text("拖曳照片上的 G1 中心可移動範圍；紫色半透明區是羽化遮罩，顏色越深代表影響越強。")
                .font(.caption2).foregroundStyle(StudioUI.secondary)
            if !model.adjustments.gradients.isEmpty {
                let index = model.adjustments.gradients.count - 1
                Text("目前編輯：G\(index + 1)").font(.caption.weight(.semibold))
                slider("漸層曝光", $model.adjustments.gradients[index].exposure, -2...2)
                slider("漸層對比", $model.adjustments.gradients[index].contrast, -100...100)
                slider("漸層亮部", $model.adjustments.gradients[index].highlights, -100...100)
                slider("漸層暗部", $model.adjustments.gradients[index].shadows, -100...100)
                slider("漸層飽和度", $model.adjustments.gradients[index].saturation, -100...100)
                slider("漸層角度", $model.adjustments.gradients[index].angle, -180...180)
                slider("漸層羽化寬度", $model.adjustments.gradients[index].range, 0.02...0.4)
            }
        }
        StudioSection(title: "修補工具", systemImage: "paintbrush.pointed", isExpanded: $healOpen) {
            Text("修補需要兩次點擊：先點要修復的目標（T），再點乾淨來源（S）。")
                .font(.caption).foregroundStyle(StudioUI.secondary)
            HStack {
                Button {
                    if model.healingBrushEnabled { model.toggleHealingBrush(); localTool = .none; pendingHealTarget = nil }
                    else { localTool = .heal; model.toggleHealingBrush() }
                } label: {
                    Label(model.healingBrushEnabled ? "結束修補" : "自動修補", systemImage: "paintbrush.pointed")
                }.buttonStyle(.borderedProminent)
                Button("取消工具") { if model.healingBrushEnabled { model.toggleHealingBrush() }; localTool = .none; pendingHealTarget = nil }
                    .disabled(localTool == .none)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("使用方式").font(.caption.weight(.semibold))
                Text("• 白色虛線圓圈：目前筆刷大小，只是游標。")
                Text("• 第一次點電線：設定目標位置（T）。")
                Text("• 第二次點乾淨天空：設定來源位置（S），才會建立修補點。")
                Text("• T 與 S 的連線：表示天空會複製到電線。")
            }.font(.caption2).foregroundStyle(StudioUI.secondary)
            StudioAdjustmentSlider(title: "筆刷大小", value: $model.adjustments.healSize,
                                   range: 4...80, onChange: model.scheduleRender)
            HStack {
                Label("修補點 \(model.adjustments.healSpots.count)", systemImage: "circle.dotted")
                Spacer()
                Button("新增仿製點") { model.addHealSpot(inpaint: false); localTool = .heal; pendingHealTarget = nil }
                Button("移除最後") { model.removeLastHealSpot() }.disabled(model.adjustments.healSpots.isEmpty)
                Button("清除全部") { model.clearHealSpots() }.disabled(model.adjustments.healSpots.isEmpty)
            }
            if !model.adjustments.healSpots.isEmpty {
                let index = model.adjustments.healSpots.count - 1
                StudioAdjustmentSlider(title: "目前修補強度", value: Binding(
                    get: { model.adjustments.healSpots[index].strength * 100 },
                    set: { model.adjustments.healSpots[index].strength = min(1, max(0, $0 / 100)) }
                ), range: 0...100, onChange: model.scheduleRender)
                Text("100% 完全套用來源；降低百分比可讓修補與原照片自然混合。")
                    .font(.caption2).foregroundStyle(StudioUI.secondary)
            }
        }
        StudioSection(title: StudioText.versions, systemImage: "square.on.square", isExpanded: $versionsOpen) {
            HStack { Text("虛擬副本 \(model.virtualCopyIndex + 1)/\(max(1, model.virtualCopyCount))"); Spacer(); Button("←") { model.switchVirtualCopy(by: -1) }; Button("新增") { model.createVirtualCopy() }; Button("→") { model.switchVirtualCopy(by: 1) } }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View { StudioAdjustmentSlider(title: title, value: value, range: range, onChange: model.scheduleRender) }

    @ViewBuilder private var presetTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("內建預設").font(.headline)
            ForEach(BuiltInPreset.allCases) { preset in Button(preset.rawValue) { model.applyPreset(preset) }.frame(maxWidth: .infinity, alignment: .leading) }
            Divider(); Text("自訂預設").font(.headline)
            ForEach(CustomPresetStore.names, id: \.self) { name in Button(name) { model.applyCustomPreset(name) }.frame(maxWidth: .infinity, alignment: .leading) }
            Button("新增自訂預設…") { model.beginNewCustomPreset() }
            Button("匯入／匯出預設…") { model.exportCustomPresets() }
        }.padding(14).buttonStyle(.plain)
    }

    @ViewBuilder private var exportTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("浮水印", isOn: $model.watermark.enabled)
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
            Picker("長邊上限", selection: $model.exportMaxLongEdge) { Text("原尺寸").tag(0); Text("1200 px").tag(1200); Text("2400 px").tag(2400); Text("4000 px").tag(4000); Text("6000 px").tag(6000) }
            Picker("DPI", selection: $model.exportDPI) { Text("72").tag(CGFloat(72)); Text("150").tag(CGFloat(150)); Text("300").tag(CGFloat(300)); Text("600").tag(CGFloat(600)) }
            Toggle("保留 EXIF", isOn: $model.preserveMetadata)
            Picker("介面外觀", selection: $model.appearance) { ForEach(AppAppearance.allCases) { Text($0.rawValue == "System" ? "系統" : ($0.rawValue == "Dark" ? "深色" : "淺色")).tag($0) } }
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
                Text("尚無照片資訊")
            }
        }.font(.callout).foregroundStyle(StudioUI.secondary).padding(14)
    }
}

private struct PhotoMetadataSummary: View {
    let exif: ExifData

    private var camera: String {
        [exif.cameraMake, exif.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
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
            row("相機", camera, "camera")
            row("鏡頭", exif.lens, "camera.aperture")
            row("拍攝時間", PhotoMetadataReader.displayDate(exif.dateTaken), "calendar")
            row("焦距", exif.focalLength, "ruler")
            row("光圈", exif.aperture, "circle.dotted")
            row("快門", exif.shutter, "timer")
            row("感光度", exif.iso.isEmpty ? "" : "ISO \(exif.iso)", "sun.max")
            row("曝光補償", exif.exposureBias, "plusminus")
            row("對焦模式", exif.focusMode, "scope")
            row("白平衡", exif.whiteBalance, "thermometer.sun")
            row("測光模式", exif.meteringMode, "camera.aperture")
            if exif.fileSize > 0 {
                row("檔案大小", String(format: "%.2f MB", Double(exif.fileSize) / 1_048_576), "doc")
            }
            if exif.width > 0 && exif.height > 0 {
                Label("尺寸：\(exif.width) × \(exif.height) px", systemImage: "aspectratio")
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
                if localTool == .heal, let pendingHealTarget {
                    let point = CGPoint(x: pendingHealTarget.x * geometry.size.width,
                                        y: (1 - pendingHealTarget.y) * geometry.size.height)
                    Circle().stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 32, height: 32)
                        .overlay(Text("T").font(.caption2.bold()).foregroundStyle(.yellow))
                        .position(point)
                }
                if localTool == .heal, model.healingBrushEnabled, let pointerLocation {
                    Circle().stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: max(24, model.adjustments.healSize * 2), height: max(24, model.adjustments.healSize * 2))
                        .position(pointerLocation)
                        .shadow(color: .black, radius: 2)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
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
            ScrollView(.horizontal) { LazyHStack(spacing: 8) { ForEach(Array(model.photos.enumerated()), id: \.element) { index, url in
                VStack(spacing: 3) { Button { model.selectPhoto(at: index) } label: { StudioThumbnail(url: url, size: CGSize(width: 132, height: 80)) }.buttonStyle(.plain); Text(url.lastPathComponent).font(.caption2).lineLimit(1).frame(width: 132); Toggle(StudioText.selected, isOn: Binding(get: { model.selectedPhotoIndices.contains(index) }, set: { model.setPhotoSelection(at: index, selected: $0) })).toggleStyle(.checkbox).font(.caption2) }
                    .padding(5).background(index == model.selectedIndex ? StudioUI.accent.opacity(0.28) : StudioUI.raised).clipShape(RoundedRectangle(cornerRadius: 5))
            } }.padding(.vertical, 8) }
            if model.photos.count > 1 { Menu(StudioText.batch) { Button(StudioText.copy + "（" + StudioText.selected + "）") { model.copyCurrentAdjustmentsToSelected() }; Button(StudioText.copy + "（" + StudioText.allPhotos.replacingOccurrences(of: "…", with: "") + "）") { model.copyCurrentAdjustmentsToAll() }; Divider(); ForEach(BuiltInPreset.allCases) { p in Button("\(p.rawValue) → " + StudioText.allPhotos.replacingOccurrences(of: "…", with: "")) { model.applyPresetToAll(p) } } } }
        }.padding(.horizontal, 12).background(StudioUI.panel)
    }
}
