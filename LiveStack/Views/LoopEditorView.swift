import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import LiveStackCore

/// Shape one loop: move the bounce window over the motion bars, set pace, add stickers.
struct LoopEditorView: View {
    @EnvironmentObject var project: ProjectModel
    let clipID: UUID
    @State private var stickerItems: [PhotosPickerItem] = []
    @State private var liftSubjects = true
    @State private var showFileImporter = false
    @State private var selectedSticker: UUID?

    private var clip: LoopClip? { project.clip(clipID) }

    var body: some View {
        Group {
            if let clip {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        preview(clip)
                        windowSection(clip)
                        paceSection(clip)
                        stickerSection(clip)
                        Button {
                            Task { _ = await project.exportLoopGIF(clip.id) }
                        } label: { Label("Save this loop as GIF", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                        .disabled(project.isBusy || clip.loopAsset == nil)
                        if let url = project.lastExport, url.pathExtension == "gif" {
                            Button("Save GIF to Photos") { Task { await project.saveLastExportToPhotos() } }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                }
                .navigationTitle(clip.name)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Loop removed", systemImage: "xmark.circle")
            }
        }
        .messageBanner($project.message)
        .onChange(of: stickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addStickers(items); stickerItems = [] }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await addStickers(fileURLs: urls) }
        }
    }

    // MARK: Sections

    private func preview(_ clip: LoopClip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let asset = clip.loopAsset {
                    LoopPlayerView(url: asset.url)
                } else {
                    Color.black.overlay(ProgressView().tint(.white))
                }
                StickerCanvas(clip: clip, selected: $selectedSticker)
            }
            .aspectRatio(max(0.3, clip.orientedSize.width / max(1, clip.orientedSize.height)), contentMode: .fit)
            .frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            Text(clip.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func windowSection(_ clip: LoopClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bounce window").font(.headline)
            Text("Drag the window over the lively part. The bars show how much moves in each moment.")
                .font(.footnote).foregroundStyle(.secondary)
            FilmstripView(clip: clip) { start in
                project.updateSpec(clip.id) { $0.windowStart = start }
            }
            .frame(height: 72)
            HStack {
                Text(String(format: "%.2f – %.2f s", clip.spec.windowStart, clip.spec.windowStart + clip.spec.windowLength))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Earlier") { project.updateSpec(clip.id) { $0.windowStart -= 2 / clip.sourceFPS } }
                Button("Later") { project.updateSpec(clip.id) { $0.windowStart += 2 / clip.sourceFPS } }
            }
            .buttonStyle(.bordered).controlSize(.small)
            HStack {
                Text("Length").font(.subheadline)
                Slider(value: Binding(get: { clip.spec.windowLength }, set: { v in project.updateSpec(clip.id) { $0.windowLength = v } }),
                       in: LoopSpec.minimumWindow...min(LoopSpec.maximumWindow, clip.sourceDuration), step: 0.05)
                Text(String(format: "%.2f s", clip.spec.windowLength)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button("Auto") { project.autoCut(clip.id) }
                Button("Shuffle") { project.shuffle(clip.id) }
                Button("Full clip") { project.useFullClip(clip.id) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func paceSection(_ clip: LoopClip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Playback") {
                Chips(options: LoopMode.allCases.map { ($0, $0.label) }, selection: Binding(get: { clip.spec.mode }, set: { v in project.updateSpec(clip.id) { $0.mode = v } }))
            }
            labeled("Speed") {
                Chips(options: LoopSpec.speeds.map { ($0, $0 == $0.rounded() ? "\(Int($0))×" : "\($0)×") }, selection: Binding(get: { clip.spec.speed }, set: { v in project.updateSpec(clip.id) { $0.speed = v } }))
            }
            labeled("Repeat") {
                Chips(options: LoopSpec.repeatOptions.map { ($0, "\($0)×") }, selection: Binding(get: { clip.spec.repeats }, set: { v in project.updateSpec(clip.id) { $0.repeats = v } }))
            }
            labeled("Camera motion") {
                Chips(options: CameraMotion.allCases.map { ($0, $0.label) }, selection: Binding(get: { clip.spec.motion }, set: { v in project.updateSpec(clip.id) { $0.motion = v } }))
            }
        }
    }

    private func stickerSection(_ clip: LoopClip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stickers").font(.headline)
            Text("Pick any photo. The main person or object is lifted off its background, like touch and hold in Photos. Then drag, pinch and twist it on the preview above.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                PhotosPicker(selection: $stickerItems, maxSelectionCount: 4, matching: .images) {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: { Label("From Files", systemImage: "folder") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            Toggle("Lift the subject automatically", isOn: $liftSubjects).font(.subheadline)
            ForEach(clip.stickers) { sticker in
                StickerRow(sticker: sticker, isSelected: selectedSticker == sticker.id) { change in
                    project.updateStickers(clip.id) { list in if let i = list.firstIndex(where: { $0.id == sticker.id }) { change(&list[i].placement) } }
                } remove: {
                    project.updateStickers(clip.id) { $0.removeAll { $0.id == sticker.id } }
                }
                .onTapGesture { selectedSticker = sticker.id }
            }
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Stickers

    private func addStickers(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { images.append(img) }
        }
        await addStickers(images: images)
    }

    private func addStickers(fileURLs: [URL]) async {
        var images: [UIImage] = []
        for url in fileURLs {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { images.append(img) }
        }
        await addStickers(images: images)
    }

    private func addStickers(images: [UIImage]) async {
        guard let clip else { return }
        var added = 0
        for image in images {
            var final = image
            if liftSubjects, let lifted = try? await SubjectLifter.lift(image) { final = lifted }
            let n = clip.stickers.count + added
            let placement = StickerPlacement(x: 0.5 + Double(n % 3 - 1) * 0.18, y: 0.62 - Double(n / 3) * 0.2, size: 0.38, rotationDegrees: n % 2 == 0 ? -6 : 6, animation: .pop)
            project.updateStickers(clip.id) { $0.append(Sticker(image: final, placement: placement)) }
            added += 1
        }
        if added > 0 { project.message = added == 1 ? "Sticker added. Drag it into place." : "\(added) stickers added. Drag them into place." }
    }
}

/// The loop file, playing forever.
struct LoopPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.playerLayer.player = player
        player.play()
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL?; var looper: AVPlayerLooper? }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Thumbnails across the whole source with motion bars and the draggable bounce window.
struct FilmstripView: View {
    let clip: LoopClip
    let onMove: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let duration = max(0.01, clip.sourceDuration)
            let x0 = w * clip.spec.windowStart / duration
            let ww = w * clip.spec.windowLength / duration
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(clip.filmstrip.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFill().frame(width: w / CGFloat(max(1, clip.filmstrip.count)), height: h).clipped()
                    }
                }
                EnergyBars(energy: clip.energy).frame(width: w, height: h * 0.4).offset(y: h * 0.3)
                Color.black.opacity(0.5).frame(width: max(0, x0), height: h)
                Color.black.opacity(0.5).frame(width: max(0, w - x0 - ww), height: h).offset(x: x0 + ww)
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: max(12, ww), height: h)
                    .offset(x: x0)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if dragStart == nil { dragStart = clip.spec.windowStart }
                            onMove((dragStart ?? 0) + Double(g.translation.width / w) * duration)
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { location in
                onMove(Double(location.x / w) * duration - clip.spec.windowLength / 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bounce window")
        .accessibilityValue(String(format: "%.1f to %.1f seconds", clip.spec.windowStart, clip.spec.windowStart + clip.spec.windowLength))
        .accessibilityAdjustableAction { direction in
            onMove(clip.spec.windowStart + (direction == .increment ? 0.1 : -0.1))
        }
    }
}

struct EnergyBars: View {
    let energy: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxE = max(1, energy.max() ?? 1)
            let bw = geo.size.width / CGFloat(max(1, energy.count))
            Path { p in
                for (i, e) in energy.enumerated() {
                    let hgt = geo.size.height * CGFloat(e / maxE)
                    p.addRect(CGRect(x: CGFloat(i) * bw + 0.5, y: geo.size.height - hgt, width: max(1, bw - 1), height: hgt))
                }
            }
            .fill(Color.accentColor.opacity(0.85))
            .background(Color.black.opacity(0.35))
        }
    }
}

/// Stickers over the loop preview with drag, pinch and rotate.
struct StickerCanvas: View {
    @EnvironmentObject var project: ProjectModel
    let clip: LoopClip
    @Binding var selected: UUID?

    var body: some View {
        GeometryReader { geo in
            ForEach(clip.stickers) { sticker in
                StickerHandle(sticker: sticker, canvas: geo.size, isSelected: selected == sticker.id) { change in
                    project.updateStickers(clip.id) { list in if let i = list.firstIndex(where: { $0.id == sticker.id }) { change(&list[i].placement) } }
                } select: { selected = sticker.id }
            }
        }
    }
}

struct StickerHandle: View {
    let sticker: Sticker
    let canvas: CGSize
    let isSelected: Bool
    let update: ((inout StickerPlacement) -> Void) -> Void
    let select: () -> Void
    @State private var startPlacement: StickerPlacement?

    var body: some View {
        let p = sticker.placement
        let w = canvas.width * p.size
        let h = w / max(0.05, sticker.aspect)
        Image(uiImage: sticker.image)
            .resizable().scaledToFit()
            .frame(width: w, height: h)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .rotationEffect(.degrees(p.rotationDegrees))
            .position(x: canvas.width * p.x, y: canvas.height * p.y)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if startPlacement == nil { startPlacement = p; select() }
                    guard let s = startPlacement else { return }
                    update { pl in
                        pl.x = min(max(s.x + Double(g.translation.width / canvas.width), 0.02), 0.98)
                        pl.y = min(max(s.y + Double(g.translation.height / canvas.height), 0.02), 0.98)
                    }
                }
                .onEnded { _ in startPlacement = nil })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { scale in
                    if startPlacement == nil { startPlacement = p; select() }
                    guard let s = startPlacement else { return }
                    update { $0.size = min(max(s.size * Double(scale), 0.08), 0.9) }
                }
                .onEnded { _ in startPlacement = nil })
            .simultaneousGesture(RotationGesture()
                .onChanged { angle in
                    if startPlacement == nil { startPlacement = p; select() }
                    guard let s = startPlacement else { return }
                    update { $0.rotationDegrees = s.rotationDegrees + angle.degrees }
                }
                .onEnded { _ in startPlacement = nil })
            .onTapGesture { select() }
    }
}

struct StickerRow: View {
    let sticker: Sticker
    let isSelected: Bool
    let update: ((inout StickerPlacement) -> Void) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(uiImage: sticker.image).resizable().scaledToFit().frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Chips(options: StickerAnimation.allCases.map { ($0, $0.label) }, selection: Binding(get: { sticker.placement.animation }, set: { v in update { $0.animation = v } }))
                HStack {
                    Text("Size").font(.caption)
                    Slider(value: Binding(get: { sticker.placement.size }, set: { v in update { $0.size = v } }), in: 0.08...0.9)
                }
            }
            Button(role: .destructive, action: remove) { Image(systemName: "xmark") }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : Color(.separator)))
    }
}
