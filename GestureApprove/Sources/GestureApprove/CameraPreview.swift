import SwiftUI
import AVFoundation

/// 设置窗口里所选系统相机的实时预览（ESP32 串口源不预览，由上层显示占位）。
struct CameraPreview: NSViewRepresentable {
    let deviceUniqueID: String?   // nil 表示停止预览
    var rotation: Int = 0         // 画面旋转角度，与识别引擎用同一个 frameRotation 设置

    func makeNSView(context: Context) -> PreviewNSView {
        PreviewNSView()
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.configure(deviceUniqueID: deviceUniqueID)
        nsView.applyRotation(rotation)
    }

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        nsView.teardown()
    }
}

final class PreviewNSView: NSView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentID: String?
    private var currentRotation: Int = 0
    private let sessionQueue = DispatchQueue(label: "xyz.anome.gestureapprove.preview")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspect
        pl.frame = bounds
        layer?.addSublayer(pl)
        previewLayer = pl
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }

    func configure(deviceUniqueID: String?) {
        guard deviceUniqueID != currentID else { return }
        currentID = deviceUniqueID
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            if let id = deviceUniqueID, let device = AVCaptureDevice(uniqueID: id),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.session.commitConfiguration()
                self.setRotation(self.currentRotation)   // 换源后连接重建，重新应用旋转
                if !self.session.isRunning { self.session.startRunning() }
            } else {
                self.session.commitConfiguration()
                if self.session.isRunning { self.session.stopRunning() }
            }
        }
    }

    /// 应用画面旋转（用预览连接的 videoRotationAngle，保持比例不变形）。
    func applyRotation(_ degrees: Int) {
        guard degrees != currentRotation else { return }
        currentRotation = degrees
        sessionQueue.async { [weak self] in self?.setRotation(degrees) }
    }

    private func setRotation(_ degrees: Int) {
        guard let conn = previewLayer?.connection else { return }
        let angle = CGFloat(degrees)
        if conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }
        // 预览水平镜像（自拍视角，更直观）
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
    }

    func teardown() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}
