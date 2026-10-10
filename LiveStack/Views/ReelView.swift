import SwiftUI
import AVFoundation
import LiveStackCore

/// Step 3: the reel preview, reel settings, and export.
struct ReelView: View {
    @EnvironmentObject var project: ProjectModel
    @State private var isPlaying = false
    @State private var time = 0.0
    @State private var scrubbing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    playerSection
                    settingsSection
                    exportSection
                }
                .padding(16)
            }
            .navigationTitle("Reel")
            .messageBanner($project.message)
        }
        .onReceive(project.player.publisher(for: \.rate)) { isPlaying = $0 > 0 }
    }

    private var duration: Double { project.reel?.duration ?? 0 }

    private var playerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let reel = project.reel, !project.clips.isEmpty {
                    ReelPlayerView(player: project.player, reel: reel, onTime: { t in if !scrubbing { time = t } })
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Your reel preview").foregroundStyle(.secondary)
                        Text("Pick Live Photos to see it play.").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }
            .aspectRatio(project.settings.frame.size.width / project.settings.frame.size.height, contentMode: .fit)
            .frame(maxHeight: 440)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                Button {
                    if isPlaying { project.player.pause() } else {
                        if time >= duration - 0.05 { project.player.seek(to: .zero) }
                        project.player.play()
                    }
                } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 28) }
                .buttonStyle(.bordered)
                .disabled(project.reel == nil || project.clips.isEmpty)
                Slider(value: Binding(get: { time }, set: { v in time = v; project.player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }),
                       in: 0...max(0.01, duration)) { editing in
                    scrubbing = editing
                    if editing { project.player.pause() }
                }
                .disabled(duration <= 0)
                Text(String(format: "%.1f / %.1f s", time, duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            }
            Text("What you see here is what gets exported. Loops play one after another with a transition between them.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("Frame") { Chips(options: ReelFrame.allCases.map { ($0, $0.rawValue) }, selection: $project.settings.frame) }
            labeled("Fill") { Chips(options: FitMode.allCases.map { ($0, $0.label) }, selection: $project.settings.fit) }
            labeled("Transition") { Chips(options: TransitionStyle.allCases.map { ($0, $0.label) }, selection: $project.settings.transition) }
            labeled("Transition length") {
                Chips(options: [(0.2, "Quick"), (0.35, "Medium"), (0.5, "Slow")], selection: $project.settings.transitionLength)
                    .disabled(project.settings.transition == .cut).opacity(project.settings.transition == .cut ? 0.45 : 1)
            }
            labeled("Title on the first loop") {
                HStack {
                    Toggle("", isOn: $project.settings.showTitle).labelsHidden()
                    TextField("e.g. Lisbon, June", text: $project.settings.title).textFieldStyle(.roundedBorder)
                        .onChange(of: project.settings.title) { _, v in if !v.isEmpty { project.settings.showTitle = true } }
                }
            }
            labeled("GIF size and rate") {
                HStack(spacing: 10) {
                    Chips(options: [(CGFloat(320), "320 px"), (CGFloat(480), "480 px"), (CGFloat(640), "640 px")], selection: $project.gifSize)
                    Chips(options: [(10.0, "10 fps"), (12.0, "12 fps"), (15.0, "15 fps")], selection: $project.gifFPS)
                }
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { Task { _ = await project.exportVideo() } } label: { Label("Export video", systemImage: "film") }
                    .buttonStyle(.borderedProminent)
                Button { Task { _ = await project.exportReelGIF() } } label: { Label("Export GIF", systemImage: "photo.stack") }
                    .buttonStyle(.bordered)
            }
            .disabled(project.isBusy || project.clips.isEmpty || project.reel == nil)
            if let url = project.lastExport {
                HStack(spacing: 10) {
                    Text(url.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered).controlSize(.small)
                    Button("Save to Photos") { Task { await project.saveLastExportToPhotos() } }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Text("Reels are exported silent at 1080 pixels wide. Add music in Instagram or TikTok when you post.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// The player layer plus a synchronized overlay layer carrying stickers, title and flashes.
struct ReelPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let reel: ComposedReel
    let onTime: (Double) -> Void

    func makeUIView(context: Context) -> ReelPlayerUIView {
        let view = ReelPlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in onTime(t.seconds) }
        return view
    }

    func updateUIView(_ view: ReelPlayerUIView, context: Context) {
        guard let item = player.currentItem else { view.setOverlay(nil, renderSize: reel.renderSize); return }
        if context.coordinator.item !== item {
            context.coordinator.item = item
            let sync = AVSynchronizedLayer(playerItem: item)
            sync.addSublayer(reel.makeOverlayLayer())
            view.setOverlay(sync, renderSize: reel.renderSize)
        }
    }

    static func dismantleUIView(_ view: ReelPlayerUIView, coordinator: Coordinator) {
        if let o = coordinator.observer { view.playerLayer.player?.removeTimeObserver(o) }
        view.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var item: AVPlayerItem?; var observer: Any? }
}

final class ReelPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var overlay: CALayer?
    private var renderSize = CGSize(width: 1080, height: 1920)

    func setOverlay(_ layer: CALayer?, renderSize: CGSize) {
        overlay?.removeFromSuperlayer()
        overlay = layer
        self.renderSize = renderSize
        if let layer { self.layer.addSublayer(layer) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let overlay else { return }
        // Scale the render-sized overlay onto the video rect the player layer actually draws.
        let rect = playerLayer.videoRect.isEmpty ? bounds : playerLayer.videoRect
        let s = rect.width / renderSize.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlay.bounds = CGRect(origin: .zero, size: renderSize)
        overlay.anchorPoint = .zero
        overlay.position = rect.origin
        overlay.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}
