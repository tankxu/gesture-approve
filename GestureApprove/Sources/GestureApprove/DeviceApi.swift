import Foundation
import Security

/// 远程审批设备（ESP32 等）API 的共享配置：开关、端口、token、本机 IP。
/// AppDelegate（装配服务）与设置窗（显示/开关）共用，避免两处各写一份。
enum DeviceApi {
    static let enabledKey = "deviceApiEnabled"
    static let tokenKey = "deviceApiToken"

    /// 是否开放设备口（默认关：不给不用的用户平白开一个网络端口）。
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 设备口端口。47601 已被 Gatekeeper LLM helper 占用，故用 47602。
    static var port: UInt16 {
        if let s = ProcessInfo.processInfo.environment["GESTURE_DEVICE_PORT"], let v = UInt16(s) { return v }
        return 47602
    }

    /// 设备口 token：首次访问时随机生成并持久化。ESP32 每个请求带 `Authorization: Bearer <token>`。
    static var token: String {
        if let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(t, forKey: tokenKey)
        return t
    }

    /// 本机非回环 IPv4 地址（en0/en1 等），供设备连接。
    static func localIPv4Addresses() -> [String] {
        var addrs: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return addrs }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty { addrs.append(ip) }
            }
        }
        return addrs
    }

    /// 供显示的连接基址列表，如 ["http://192.168.2.10:47602"]。
    static func baseURLs() -> [String] {
        localIPv4Addresses().map { "http://\($0):\(port)" }
    }
}
