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

    /// 首选默认：优先**内置**摄像头（避开 OBS/Camo 等没推流就黑屏的虚拟相机），
    /// 其次第一个真实设备，最后 ESP32。
    static func preferredDefaultID() -> String {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        if let builtin = ds.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtin.uniqueID
        }
        return ds.devices.first?.uniqueID ?? esp32ID
    }

    /// 当前选择的输入 id；未设置或所选设备已不存在时回退到首选默认。
    static func currentID() -> String {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
            if saved == esp32ID || available().contains(where: { $0.id == saved }) {
                return saved
            }
        }
        return preferredDefaultID()
    }

    /// 实际要打开的设备 id：**坚持用户保存的选择**，即使此刻 `available()` 里看不到它
    /// （USB 采集卡刚从睡眠唤醒、还没重新枚举完是常态）。与 `currentID()` 的区别是**不回退**——
    /// 回退会在唤醒瞬间把选定的 AVerMedia 误判成"不存在"而换成内置摄像头。没保存过才用首选默认。
    /// 设备真的被永久移除时，配合下游"严格用选定设备、找不到就等"，宁可暂时黑屏也不偷偷用错摄像头。
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
