import Foundation
import UIKit
import Vision
import CoreImage

/// Lifts the main subject out of a photo, the way Photos does when you touch and hold a person.
enum SubjectLifter {
    static func lift(_ image: UIImage) async throws -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            let context = CIContext()
            guard let out = context.createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        }.value
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
