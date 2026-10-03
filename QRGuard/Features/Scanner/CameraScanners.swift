import SwiftUI
import AVFoundation
import Vision
import VisionKit

#if !targetEnvironment(simulator)

// MARK: - VisionKit DataScanner (지원 기기)

/// `DataScannerViewController` 래핑. 여러 코드를 동시에 인식하고 하이라이트한다.
struct DataScannerRepresentable: UIViewControllerRepresentable {
    var paused: Bool
    var onCodes: ([String]) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCodes: onCodes) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        scanner.view.backgroundColor = .black
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                onUnavailable(String(localized: "카메라 스캐너를 시작하지 못했어요. 사진 불러오기나 주소 직접 입력을 이용해 주세요."))
            }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCodes = onCodes
        if paused, scanner.isScanning {
            scanner.stopScanning()
        } else if !paused, !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCodes: ([String]) -> Void

        init(onCodes: @escaping ([String]) -> Void) {
            self.onCodes = onCodes
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            // 상위 뷰가 권한 상태를 다시 읽는다.
        }

        private func report(_ items: [RecognizedItem]) {
            let payloads: [String] = items.compactMap {
                if case .barcode(let barcode) = $0 { return barcode.payloadStringValue }
                return nil
            }
            onCodes(payloads)
        }
    }
}

// MARK: - AVFoundation 폴백 (DataScanner 미지원 기기)

/// `AVCaptureMetadataOutput` 기반 폴백 스캐너.
struct AVMetadataScannerView: UIViewRepresentable {
    var paused: Bool
    var onCodes: ([String]) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCodes: onCodes) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        context.coordinator.configure(previewView: view, onUnavailable: onUnavailable)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCodes = onCodes
        context.coordinator.setPaused(paused)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCodes: ([String]) -> Void
        private let session = AVCaptureSession()
        private var configured = false

        init(onCodes: @escaping ([String]) -> Void) {
            self.onCodes = onCodes
        }

        func configure(previewView: PreviewView, onUnavailable: @escaping (String) -> Void) {
            guard !configured else { return }
            configured = true
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onUnavailable(String(localized: "카메라를 열지 못했어요. 사진 불러오기나 주소 직접 입력을 이용해 주세요."))
                return
            }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                onUnavailable(String(localized: "이 기기에서는 QR 인식을 지원하지 않아요."))
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
            session.commitConfiguration()
            previewView.previewLayer.session = session
            previewView.previewLayer.videoGravity = .resizeAspectFill
            startRunning()
        }

        func setPaused(_ paused: Bool) {
            if paused, session.isRunning {
                // AVCaptureSession은 Sendable이 아니지만 start/stopRunning은 스레드 안전한 블로킹 호출이다.
                nonisolated(unsafe) let session = self.session
                DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
            } else if !paused, !session.isRunning, configured {
                startRunning()
            }
        }

        private func startRunning() {
            nonisolated(unsafe) let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let payloads = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard !payloads.isEmpty else { return }
            Task { @MainActor in self.onCodes(payloads) }
        }
    }
}

#endif
