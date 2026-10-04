import Foundation
import Vision
import CoreImage
import CoreGraphics
import UIKit
import QRGuardCore

/// 사진 속 QR 코드 전부 추출 (TASKS T-2.4) + 중첩·문자 QR 회피 탐지 (T-8.1, V 계열).
/// Vision `DetectBarcodesRequest`(.qr)를 원본·축소·확대·크롭 이미지에 반복 적용한다.
enum QRImageDecoder {
    enum DecodeError: Error { case invalidImage }

    struct Result {
        /// 서로 다른 페이로드(원본 이미지에서 먼저 찾은 순)
        var payloads: [String]
        var vision: VisionSignals
    }

    /// 서로 다른 페이로드만 순서대로 돌려준다(중복 제거). 단순 호출용.
    static func decode(imageData: Data) async throws -> [String] {
        try await decodeWithSignals(imageData: imageData).payloads
    }

    /// 다중 배율·크롭 디코딩으로 숨은 QR까지 찾고 V 계열 신호를 함께 계산한다.
    static func decodeWithSignals(imageData data: Data) async throws -> Result {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw DecodeError.invalidImage
        }
        return try await decodeWithSignals(cgImage: cgImage, orientation: image.imageOrientation.cgOrientation)
    }

    static func decodeWithSignals(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> Result {
        // 1. 원본
        var ordered: [String] = []
        var seen = Set<String>()
        func collect(_ payloads: [String]) {
            for p in payloads where seen.insert(p).inserted { ordered.append(p) }
        }
        collect(try await decodePayloads(cgImage, orientation: orientation))

        // 2. 배율·크롭 변형 — 바깥 코드가 안쪽 코드를 가리는 중첩 QR, 작은 조각을 찾는다 (S11).
        for variant in variants(of: cgImage) {
            if let payloads = try? await decodePayloads(variant, orientation: orientation) {
                collect(payloads)
            }
        }

        let sites = distinctSites(in: ordered)
        let vision = VisionSignals(
            nestedDistinctSites: sites.count >= 2 ? sites : [],
            decodedCodeCount: ordered.count
        )
        return Result(payloads: ordered, vision: vision)
    }

    /// 한 장씩은 디코딩되지 않는 분할 QR을 좌우·상하로 이어 붙여 다시 시도한다 (V01).
    static func decodeCombined(_ images: [CGImage]) async -> String? {
        guard images.count >= 2 else { return nil }
        for (a, b) in [(images[0], images[1]), (images[1], images[0])] {
            for horizontal in [true, false] {
                guard let combined = stitch(a, b, horizontal: horizontal),
                      let payloads = try? await decodePayloads(combined, orientation: .up),
                      let first = payloads.first else { continue }
                return first
            }
        }
        return nil
    }

    // MARK: - 문자로 그린 QR (ASCII QR, V03)

    /// 블록 문자(`█▀▄` 등)로 그린 QR이면 비트맵으로 렌더링해 디코딩한다. 아니면 nil.
    static func decodeTextArt(_ text: String) async -> String? {
        guard let bitmap = TextArtQR.render(text) else { return nil }
        return (try? await decodePayloads(bitmap, orientation: .up))?.first
    }

    // MARK: - 내부

    /// Vision 우선, 실패하거나 비어 있으면 Core Image `CIDetector`로 보완한다.
    /// (시뮬레이터에서는 Vision 바코드 요청이 추론 컨텍스트를 못 만들어 throw하는 경우가 있다.)
    private static func decodePayloads(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func collect(_ payloads: [String]) {
            for p in payloads where !p.isEmpty && seen.insert(p).inserted { result.append(p) }
        }
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            let observations = try await request.perform(on: cgImage, orientation: orientation)
            collect(observations.compactMap(\.payloadString))
        } catch {
            // 아래 CIDetector 폴백으로 넘어간다.
        }
        if result.isEmpty {
            collect(coreImagePayloads(cgImage, orientation: orientation))
        }
        return result
    }

    private static func coreImagePayloads(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        let image = CIImage(cgImage: cgImage).oriented(orientation)
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    /// 0.5배·2배(최대 2048px)·사분면·중앙 50% 크롭.
    private static func variants(of image: CGImage) -> [CGImage] {
        var out: [CGImage] = []
        let w = image.width, h = image.height
        if let half = resized(image, scale: 0.5) { out.append(half) }
        if max(w, h) * 2 <= 2048, let double = resized(image, scale: 2.0) { out.append(double) }
        let rects = [
            CGRect(x: 0, y: 0, width: w / 2, height: h / 2),
            CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2),
            CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2),
            CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2),
            CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2),
        ]
        for rect in rects where rect.width >= 64 && rect.height >= 64 {
            if let cropped = image.cropping(to: rect) { out.append(cropped) }
        }
        return out
    }

    private static func resized(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard w >= 64, h >= 64,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func stitch(_ a: CGImage, _ b: CGImage, horizontal: Bool) -> CGImage? {
        let w = horizontal ? a.width + b.width : max(a.width, b.width)
        let h = horizontal ? max(a.height, b.height) : a.height + b.height
        guard w <= 4096, h <= 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext 좌표는 아래가 원점: 세로 결합 시 a를 위에 두려면 b를 먼저(아래) 그린다.
        if horizontal {
            ctx.draw(a, in: CGRect(x: 0, y: h - a.height, width: a.width, height: a.height))
            ctx.draw(b, in: CGRect(x: a.width, y: h - b.height, width: b.width, height: b.height))
        } else {
            ctx.draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
            ctx.draw(a, in: CGRect(x: 0, y: b.height, width: a.width, height: a.height))
        }
        return ctx.makeImage()
    }

    /// URL 페이로드들의 서로 다른 eTLD+1.
    private static func distinctSites(in payloads: [String]) -> [String] {
        var sites: [String] = []
        for raw in payloads {
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let normalized = URLNormalizer.normalize(url),
                  let site = normalized.registrableDomain ?? (normalized.host.isEmpty ? nil : normalized.host),
                  !sites.contains(site) else { continue }
            sites.append(site)
        }
        return sites
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

/// 문자(█▀▄ 등)·공백으로 그린 QR을 비트맵으로 바꾼다.
enum TextArtQR {
    private static let fullBlocks: Set<Character> = ["█", "▓", "▒", "░", "■", "●", "◼", "⬛", "#", "@"]
    private static let topHalf: Character = "▀"
    private static let bottomHalf: Character = "▄"
    private static let whites: Set<Character> = [" ", "\u{3000}", "\u{00A0}", "□", "○", "◻", "⬜", ".", "-", "_"]

    /// 15줄 이상이고 각 줄의 90% 이상이 블록·공백 문자이면 문자 QR로 본다.
    static func looksLikeTextArt(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 15 else { return false }
        let qualifying = lines.filter { line in
            let chars = Array(line)
            let ok = chars.filter { fullBlocks.contains($0) || $0 == topHalf || $0 == bottomHalf || whites.contains($0) }.count
            return chars.count >= 15 && Double(ok) / Double(chars.count) >= 0.9 && chars.contains { fullBlocks.contains($0) || $0 == topHalf || $0 == bottomHalf }
        }
        return Double(qualifying.count) / Double(lines.count) >= 0.8
    }

    /// 한 글자 = 가로 1칸, 세로 2칸(반블록 지원). 조용한 영역(4칸)을 두른다.
    static func render(_ text: String, cell: Int = 6) -> CGImage? {
        guard looksLikeTextArt(text) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { Array($0) }.filter { !$0.allSatisfy(\.isWhitespace) }
        let cols = lines.map(\.count).max() ?? 0
        let rows = lines.count * 2
        let quiet = 4
        let w = (cols + quiet * 2) * cell, h = (rows + quiet * 2) * cell
        guard w > 0, h > 0, w <= 4096, h <= 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for (lineIndex, line) in lines.enumerated() {
            for (col, ch) in line.enumerated() {
                let x = (quiet + col) * cell
                // 위쪽 반 = 행 2*i, 아래쪽 반 = 행 2*i+1 (이미지 좌표는 아래가 0이므로 뒤집는다)
                let topRow = lineIndex * 2, bottomRow = lineIndex * 2 + 1
                func fill(_ row: Int) {
                    let y = h - (quiet + row + 1) * cell
                    ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
                if fullBlocks.contains(ch) { fill(topRow); fill(bottomRow) }
                else if ch == topHalf { fill(topRow) }
                else if ch == bottomHalf { fill(bottomRow) }
            }
        }
        return ctx.makeImage()
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
