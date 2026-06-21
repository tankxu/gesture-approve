import Foundation

/// MediaPipe 可选组件的安装检测与安装脚本定位。
enum MediaPipeInstaller {
    static let engineKey = "recognitionEngine"   // "vision" | "mediapipe"

    // 只读脚本 → bundle（回退仓库）；可写产物(venv/模型) → Application Support。
    static var daemonScript: String { AppPaths.resource("bridge/gesture_daemon.py") }
    static var bridgeDir: String { AppPaths.resource("bridge") }
    static var setupScript: String { AppPaths.resource("bridge/setup_mediapipe.sh") }
    static var venvDir: String { AppPaths.supportPath("mediapipe/.venv") }
    static var venvPython: String { (venvDir as NSString).appendingPathComponent("bin/python") }
    static var modelDir: String { AppPaths.supportPath("mediapipe/models") }
    static var modelFile: String { (modelDir as NSString).appendingPathComponent("gesture_recognizer.task") }

    /// 已安装 = venv 解释器 + daemon 脚本 + 模型文件都在。
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: venvPython)
            && fm.fileExists(atPath: daemonScript)
            && fm.fileExists(atPath: modelFile)
    }

    /// 当前选择是否为 MediaPipe（且已安装才算数）。
    static func usingMediaPipe() -> Bool {
        let sel = UserDefaults.standard.string(forKey: engineKey) ?? "vision"
        return sel == "mediapipe" && isInstalled()
    }
}
