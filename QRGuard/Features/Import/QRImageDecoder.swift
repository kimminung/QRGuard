import Foundation
import Vision
import CoreImage
import UIKit

/// 사진 속 QR 코드 전부 추출 (TASKS T-2.4). Vision `DetectBarcodesRequest`(.qr).
enum QRImageDecoder {
    enum DecodeError: Error { case invalidImage }

    /// 서로 다른 페이로드만 순서대로 돌려준다(중복 제거).
    static func decode(imageData: Data) async throws -> [String] {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw DecodeError.invalidImage
        }
        return try await decode(cgImage: cgImage, orientation: image.imageOrientation.cgOrientation)
    }

    static func decode(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        let observations = try await request.perform(on: cgImage, orientation: orientation)
        var seen = Set<String>()
        var result: [String] = []
        for observation in observations {
            guard let payload = observation.payloadString, !payload.isEmpty else { continue }
            if seen.insert(payload).inserted { result.append(payload) }
        }
        return result
    }

    /// 테스트·미리보기용: 문자열로 QR 이미지를 만든다 (Core Image `CIQRCodeGenerator`).
    static func makeQRImage(_ string: String, scale: CGFloat = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext()
        return context.createCGImage(output, from: output.extent)
    }
}

extension UIImage.Orientation {
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
