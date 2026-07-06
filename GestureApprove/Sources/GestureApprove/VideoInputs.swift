import Foundation
import AVFoundation

/// 一个可选的视频输入源（系统相机，或 ESP32-CAM 串口源）。
struct VideoInput: Identifiable, Hashable {
    let id: String     // 系统相机的 uniqueID；ESP32 用 VideoInputs.esp32ID
    let name: String
    var isESP32: Bool { id == VideoInputs.esp32ID }
}

enum VideoInputs {
    static let esp32ID = "esp32-cam-serial"
    static let defaultsKey = "videoInputID"

    /// 枚举系统相机 + 追加 ESP32-CAM。
    static func available() -> [VideoInput] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        var list = ds.devices.map { VideoInput(id: $0.uniqueID, name: $0.localizedName) }
        list.append(VideoInput(id: esp32ID, name: L("video.esp32")))
        return list
    }

    /// 首选默认设备：优先**内置**摄像头（避开 OBS/Camo 等没推流就黑屏的虚拟相机），
    /// 其次第一个真实设备。审批的临时回退（选定设备被拔）也用它，保证两处口径一致。
    static func preferredDefaultDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return ds.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? ds.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    static func preferredDefaultID() -> String {
        preferredDefaultDevice()?.uniqueID ?? esp32ID
    }

    /// 实际要打开的设备 id：**坚持用户保存的选择**，即使此刻 `available()` 里看不到它
    /// （USB 采集卡刚从睡眠唤醒、还没重新枚举完是常态）——立即回退会在唤醒瞬间把选定的
    /// AVerMedia 误判成"不存在"而换成内置摄像头。没保存过才用首选默认。
    /// 设备被**永久拔掉**的情形不在这里处理：由 CameraFrameSource 在缺席超过宽限期后
    /// 临时回退到默认设备（不改写这里保存的选择，插回自动切回）。
    /// 注意别再引入"所选设备不在列表就回退"的读取函数——曾经的 currentID() 就是这么
    /// 造成设置 UI 与审批表里不一的（UI 显示回退结果、持久值还是死设备）。
    static func savedOrDefaultID() -> String {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
            return saved
        }
        return preferredDefaultID()
    }

    static func setCurrentID(_ id: String) {
        UserDefaults.standard.set(id, forKey: defaultsKey)
    }
}
