import Foundation
import Photos
import UIKit

/// Everything that touches the Photos library.
enum PhotoLibrary {
    static func requestReadAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func requestAddAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Every Live Photo in the library, newest first.
    static func fetchLivePhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    /// Writes the motion half of a Live Photo to a temporary file and returns its URL.
    static func exportPairedVideo(of asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo }) ?? resources.first(where: { $0.type == .pairedVideo }) else {
            throw LiveStackError.noPairedVideo
        }
        let url = AppPaths.temporaryFile("live", ext: "mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        return url
    }

    static func saveVideo(at url: URL) async throws {
        guard await requestAddAccess() == .authorized else { throw LiveStackError.exportFailed("Photos access was not granted.") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    static func saveImageFile(at url: URL) async throws {
        guard await requestAddAccess() == .authorized else { throw LiveStackError.exportFailed("Photos access was not granted.") }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
