import Foundation

/// MediaPipe 可选组件的安装检测与安装脚本定位。
enum MediaPipeInstaller {
    static let engineKey = "recognitionEngine"   // "vision" | "mediapipe"

    private static var root: String { HookInstaller.repoRoot() }
    static var venvPython: String { (root as NSString).appendingPathComponent("bridge/.venv/bin/python") }
    static var daemonScript: String { (root as NSString).appendingPathComponent("bridge/gesture_daemon.py") }
    static var modelFile: String { (root as NSString).appendingPathComponent("bridge/models/gesture_recognizer.task") }
    static var setupScript: String { (root as NSString).appendingPathComponent("setup.sh") }

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
