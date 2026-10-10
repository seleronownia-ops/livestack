import Foundation
import SwiftUI
import AVFoundation
import Photos
import LiveStackCore

/// The whole project: imported Live Photos, their loop specs, reel settings, the live preview and exports.
@MainActor
final class ProjectModel: ObservableObject {
    static let maxClips = 9

    @Published private(set) var clips: [LoopClip] = []
    @Published var settings = ReelSettings() { didSet { if settings != oldValue { scheduleRebuild() } } }
    @Published private(set) var reel: ComposedReel?
    @Published private(set) var isBusy = false
    @Published private(set) var busyTitle = ""
    @Published private(set) var busyProgress = 0.0
    @Published var message: String?
    @Published var lastExport: URL?
    @Published var gifSize: CGFloat = 480
    @Published var gifFPS: Double = 12

    let player = AVQueuePlayer()
    private var renderTasks: [UUID: Task<Void, Never>] = [:]
    private var renderGeneration: [UUID: Int] = [:]
    private var rebuildTask: Task<Void, Never>?
    private var cancelled = false

    var canAddMore: Bool { clips.count < Self.maxClips }

    // MARK: Import

    /// Imports Live Photos from the library: paired video, motion analysis, auto cut, first loop render.
    func importLivePhotos(_ assets: [PHAsset]) async {
        guard !assets.isEmpty else { return }
        begin("Reading Live Photos")
        defer { end() }
        var added = 0
        for (i, asset) in assets.enumerated() {
            if cancelled { message = "Stopped."; break }
            guard canAddMore else { message = "A reel holds up to \(Self.maxClips) loops. The rest were skipped."; break }
            busyProgress = Double(i) / Double(assets.count)
            do {
                let url = try await PhotoLibrary.exportPairedVideo(of: asset)
                try await addClip(from: url, name: nameFor(asset, index: clips.count), assetIdentifier: asset.localIdentifier)
                added += 1
            } catch {
                message = "Live Photo \(i + 1): \(error.localizedDescription)"
            }
        }
        if added > 0 { message = added == 1 ? "1 loop added. Tap it to shape it." : "\(added) loops added. Tap one to shape it." }
    }

    /// Imports any video file (for tests, Files app, or a Shortcut's output).
    func importVideoFile(_ url: URL, name: String? = nil) async {
        begin("Reading video")
        defer { end() }
        do {
            try await addClip(from: url, name: name ?? url.deletingPathExtension().lastPathComponent, assetIdentifier: nil)
            message = "Loop added."
        } catch { message = error.localizedDescription }
    }

    private func addClip(from url: URL, name: String, assetIdentifier: String?) async throws {
        let analysis = try await MotionAnalyzer.analyze(url: url)
        let spec = AutoCut.auto(energy: analysis.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: analysis.duration, index: clips.count)
        var clip = LoopClip(id: UUID(), name: name, assetIdentifier: assetIdentifier, sourceURL: url, sourceDuration: analysis.duration,
                            sourceFPS: analysis.sourceFPS, orientedSize: analysis.orientedSize, energy: analysis.energy,
                            filmstrip: analysis.filmstrip, spec: spec, stickers: [], loopAsset: nil, thumbnail: analysis.filmstrip.first)
        let asset = try await LoopRenderer.shared.render(sourceURL: url, spec: spec)
        clip.loopAsset = asset
        clips.append(clip)
        scheduleRebuild()
    }

    private func nameFor(_ asset: PHAsset, index: Int) -> String {
        if let date = asset.creationDate {
            let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
            return f.string(from: date)
        }
        return "Live Photo \(index + 1)"
    }

    // MARK: Editing

    func clip(_ id: UUID) -> LoopClip? { clips.first { $0.id == id } }

    func updateSpec(_ id: UUID, _ change: (inout LoopSpec) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var spec = clips[i].spec
        change(&spec)
        spec = spec.clamped(toSourceDuration: clips[i].sourceDuration)
        guard spec != clips[i].spec else { return }
        clips[i].spec = spec
        scheduleRender(for: id)
    }

    func updateStickers(_ id: UUID, _ change: (inout [Sticker]) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[i].stickers)
        scheduleRebuild()
    }

    func move(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        scheduleRebuild()
    }

    func remove(_ id: UUID) {
        renderTasks[id]?.cancel()
        clips.removeAll { $0.id == id }
        scheduleRebuild()
    }

    func removeAll() {
        renderTasks.values.forEach { $0.cancel() }
        renderTasks = [:]
        clips = []
        reel = nil
        player.removeAllItems()
        scheduleRebuild()
    }

    func autoCutAll() {
        for (i, c) in clips.enumerated() {
            updateSpec(c.id) { $0 = AutoCut.auto(energy: c.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: c.sourceDuration, index: i) }
        }
        message = "Each loop bounces its liveliest half second three times at 1.5×."
    }

    func shuffle(seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        var rng = SeededRNG(seed: seed)
        let order = AutoCut.shuffleOrder(count: clips.count, rng: &rng)
        clips = order.map { clips[$0] }
        for c in clips {
            updateSpec(c.id) { $0 = AutoCut.shuffle(energy: c.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: c.sourceDuration, rng: &rng) }
        }
        let (style, length) = AutoCut.shuffleTransition(rng: &rng)
        settings.transition = style
        settings.transitionLength = length
        message = "New order, new windows, new pace, \(style.label.lowercased()) transitions."
    }

    func resetAll() {
        for c in clips { updateSpec(c.id) { $0 = AutoCut.full(duration: c.sourceDuration) } }
        message = "Full clips, one bounce each at normal speed."
    }

    func autoCut(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips[i]
        updateSpec(id) { $0 = AutoCut.auto(energy: c.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: c.sourceDuration, index: i) }
    }

    func shuffle(_ id: UUID) {
        guard let c = clip(id) else { return }
        var rng = SeededRNG(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        updateSpec(id) { $0 = AutoCut.shuffle(energy: c.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: c.sourceDuration, rng: &rng) }
    }

    func useFullClip(_ id: UUID) {
        guard let c = clip(id) else { return }
        updateSpec(id) { $0 = AutoCut.full(duration: c.sourceDuration) }
    }

    // MARK: Rendering

    /// Re-renders a loop after a short pause so dragging the window does not queue dozens of renders.
    private func scheduleRender(for id: UUID) {
        renderTasks[id]?.cancel()
        let generation = (renderGeneration[id] ?? 0) + 1
        renderGeneration[id] = generation
        renderTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let clip = self.clip(id) else { return }
            do {
                let asset = try await LoopRenderer.shared.render(sourceURL: clip.sourceURL, spec: clip.spec)
                guard !Task.isCancelled, self.renderGeneration[id] == generation, let i = self.clips.firstIndex(where: { $0.id == id }) else { return }
                if let old = self.clips[i].loopAsset?.url { try? FileManager.default.removeItem(at: old) }
                self.clips[i].loopAsset = asset
                self.scheduleRebuild()
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.rebuildReel()
        }
    }

    func rebuildReel() async {
        let inputs = clips.compactMap { c -> ReelComposer.Input? in
            guard let asset = c.loopAsset else { return nil }
            return ReelComposer.Input(asset: asset, stickers: c.stickers)
        }
        do {
            let composed = try await ReelComposer.compose(inputs: inputs, settings: settings)
            reel = composed
            let wasPlaying = player.rate > 0
            let current = player.currentTime()
            let position = (current.isValid && current.isNumeric) ? current : .zero
            player.removeAllItems()
            if !inputs.isEmpty {
                let item = composed.makePlayerItem()
                player.insert(item, after: nil)
                player.actionAtItemEnd = .pause
                let target = CMTimeClampToRange(position, range: CMTimeRange(start: .zero, duration: CMTime(seconds: max(0.01, composed.duration - 0.01), preferredTimescale: 600)))
                _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Export

    func exportVideo() async -> URL? {
        guard let reel, !clips.isEmpty, clips.allSatisfy({ $0.loopAsset != nil }) else { message = LiveStackError.nothingToExport.localizedDescription; return nil }
        begin("Rendering reel")
        defer { end() }
        do {
            let url = try await ReelExporter.exportVideo(reel) { [weak self] p in Task { @MainActor in self?.busyProgress = p } }
            lastExport = url
            message = "Reel ready. Tap Save to Photos."
            return url
        } catch { message = error.localizedDescription; return nil }
    }

    func exportReelGIF() async -> URL? {
        guard let video = await exportVideo() else { return nil }
        begin("Making GIF")
        defer { end() }
        do {
            let gif = try await ReelExporter.makeGIF(from: video, fps: gifFPS, maxSide: gifSize) { [weak self] p in Task { @MainActor in self?.busyProgress = p } }
            lastExport = gif
            message = "GIF ready. Tap Save to Photos."
            return gif
        } catch { message = error.localizedDescription; return nil }
    }

    func exportLoopGIF(_ id: UUID) async -> URL? {
        guard let clip = clip(id), let asset = clip.loopAsset else { return nil }
        begin("Making GIF")
        defer { end() }
        do {
            let gif = try await ReelExporter.makeGIF(from: asset.url, fps: gifFPS, maxSide: gifSize) { [weak self] p in Task { @MainActor in self?.busyProgress = p } }
            lastExport = gif
            message = "GIF of \(clip.name) ready. Tap Save to Photos."
            return gif
        } catch { message = error.localizedDescription; return nil }
    }

    func saveLastExportToPhotos() async {
        guard let url = lastExport else { return }
        do {
            if url.pathExtension.lowercased() == "gif" { try await PhotoLibrary.saveImageFile(at: url) } else { try await PhotoLibrary.saveVideo(at: url) }
            message = "Saved to Photos."
        } catch { message = error.localizedDescription }
    }

    func cancelBusy() { cancelled = true }

    private func begin(_ title: String) { isBusy = true; busyTitle = title; busyProgress = 0; cancelled = false }
    private func end() { isBusy = false; busyProgress = 0 }
}
