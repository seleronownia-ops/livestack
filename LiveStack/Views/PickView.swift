import SwiftUI
import Photos
import PhotosUI

/// Step 1: a grid of every Live Photo in the library, each one playing, tap to pick.
struct PickView: View {
    @EnvironmentObject var project: ProjectModel
    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selected: [String] = []
    @State private var visible: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized, .limited:
                    grid
                case .notDetermined:
                    permissionPrompt("Live Stack needs to read your Live Photos to show them here.", button: "Allow access") {
                        Task { status = await PhotoLibrary.requestReadAccess(); reload() }
                    }
                default:
                    permissionPrompt("Photos access is off. Turn it on in Settings to pick Live Photos.", button: "Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            .navigationTitle("Live Photos")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !selected.isEmpty { Button("Clear") { selected = [] } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selected.isEmpty ? "Add" : "Add \(selected.count)") {
                        let picked = selected.compactMap { id in assets.first { $0.localIdentifier == id } }
                        selected = []
                        Task { await project.importLivePhotos(picked) }
                    }
                    .disabled(selected.isEmpty || project.isBusy)
                    .fontWeight(.semibold)
                }
            }
            .messageBanner($project.message)
        }
        .task { if status == .authorized || status == .limited { reload() } }
    }

    private var grid: some View {
        ScrollView {
            if assets.isEmpty {
                ContentUnavailableView("No Live Photos", systemImage: "livephoto.slash", description: Text("Take a Live Photo with the Camera app and it will show up here, playing."))
                    .padding(.top, 80)
            } else {
                Text("Everything here is a Live Photo and plays as it will in the reel. Tap the ones you want, in the order you want them. Up to \(ProjectModel.maxClips) per reel.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        let index = selected.firstIndex(of: asset.localIdentifier)
                        LivePhotoCell(asset: asset, plays: visible.contains(asset.localIdentifier), selectionIndex: index)
                            .aspectRatio(1, contentMode: .fit)
                            .onAppear { visible.insert(asset.localIdentifier) }
                            .onDisappear { visible.remove(asset.localIdentifier) }
                            .onTapGesture { toggle(asset) }
                            .accessibilityLabel(index == nil ? "Live Photo" : "Live Photo, selected as number \(index! + 1)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 24)
            }
        }
    }

    private func permissionPrompt(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "livephoto").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
    }

    private func toggle(_ asset: PHAsset) {
        if let i = selected.firstIndex(of: asset.localIdentifier) {
            selected.remove(at: i)
        } else if selected.count + project.clips.count < ProjectModel.maxClips {
            selected.append(asset.localIdentifier)
        } else {
            project.message = "A reel holds up to \(ProjectModel.maxClips) loops. Remove one in Loops first."
        }
    }

    private func reload() {
        let result = PhotoLibrary.fetchLivePhotos()
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }
}

/// One Live Photo, playing its motion in a loop while on screen.
struct LivePhotoCell: View {
    let asset: PHAsset
    let plays: Bool
    let selectionIndex: Int?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LivePhotoPlayerView(asset: asset, plays: plays)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectionIndex == nil ? Color.clear : Color.accentColor, lineWidth: 3))
            if let n = selectionIndex {
                Text("\(n + 1)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
                    .padding(6)
            }
        }
    }
}

struct LivePhotoPlayerView: UIViewRepresentable {
    let asset: PHAsset
    let plays: Bool

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.delegate = context.coordinator
        view.isMuted = true
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        let coordinator = context.coordinator
        coordinator.wantsPlayback = plays
        if coordinator.assetID != asset.localIdentifier {
            coordinator.assetID = asset.localIdentifier
            view.livePhoto = nil
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = true
            let id = asset.localIdentifier
            coordinator.requestID = PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: options) { photo, _ in
                guard coordinator.assetID == id, let photo else { return }
                view.livePhoto = photo
                if coordinator.wantsPlayback { view.startPlayback(with: .full) }
            }
        } else if plays, view.livePhoto != nil, !coordinator.playing {
            view.startPlayback(with: .full)
        } else if !plays, coordinator.playing {
            view.stopPlayback()
        }
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        view.stopPlayback()
        if let id = coordinator.requestID { PHImageManager.default().cancelImageRequest(id) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var assetID: String?
        var requestID: PHImageRequestID?
        var wantsPlayback = false
        var playing = false

        func livePhotoView(_ livePhotoView: PHLivePhotoView, willBeginPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) { playing = true }
        func livePhotoView(_ livePhotoView: PHLivePhotoView, didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            playing = false
            guard wantsPlayback else { return }
            // Loop with a short breath so nine cells do not restart in lockstep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak livePhotoView] in
                guard let self, self.wantsPlayback, let v = livePhotoView, v.livePhoto != nil else { return }
                v.startPlayback(with: .full)
            }
        }
    }
}
