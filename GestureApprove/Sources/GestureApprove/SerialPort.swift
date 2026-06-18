import Foundation
import Darwin

/// 极简串口封装（POSIX termios），复刻 bridge/esp32cam.py 的复位时序与抓帧协议。
final class SerialPort {
    private let path: String
    private let baud: Int
    private var fd: Int32 = -1

    // macOS ioctl 常量（部分宏在 Swift 不可见，手工定义）。
    // IOSSIOSPEED = _IOW('T', 2, speed_t)，macOS 上 speed_t 是 unsigned long(8字节) => 0x80085402。
    private let IOSSIOSPEED: UInt = 0x80085402
    private let TIOCMGET: UInt = 0x4004746a
    private let TIOCMSET: UInt = 0x8004746d
    private let TIOCM_DTR: Int32 = 0x0002
    private let TIOCM_RTS: Int32 = 0x0004
    private let VMIN_IDX = 16
    private let VTIME_IDX = 17

    private let magic: [UInt8] = [0xA5, 0x5A, 0xA5, 0x5A]

    init(path: String, baud: Int) {
        self.path = path
        self.baud = baud
    }

    func open() -> Bool {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, 0)  // 转回阻塞模式，靠 VTIME 控制超时

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else { close(); return false }
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(CRTSCTS)  // 关硬件流控
        // VMIN=0, VTIME=2 => read 最多阻塞 0.2s 后返回已有数据
        withUnsafeMutablePointer(to: &tty.c_cc) { p in
            p.withMemoryRebound(to: cc_t.self, capacity: 20) { cc in
                cc[VMIN_IDX] = 0
                cc[VTIME_IDX] = 2
            }
        }
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else { close(); return false }

        var speed = speed_t(baud)
        _ = withUnsafeMutablePointer(to: &speed) { ioctl(fd, IOSSIOSPEED, $0) }
        return true
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    // MARK: DTR/RTS 复位到运行模式（GPIO0 高=运行；脉冲 EN=复位）

    private func setModemBit(_ bit: Int32, _ on: Bool) {
        var bits: Int32 = 0
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, TIOCMGET, $0) }
        if on { bits |= bit } else { bits &= ~bit }
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, TIOCMSET, $0) }
    }

    func resetToRunMode() {
        setModemBit(TIOCM_DTR, false)  // 与 bridge 一致：清 DTR(GPIO0 高=运行)
        setModemBit(TIOCM_RTS, true)   // 置 RTS(EN 低=复位)
        usleep(100_000)
        setModemBit(TIOCM_RTS, false)  // 释放复位
        usleep(1_000_000)              // 等相机初始化 + 丢弃稳定帧
        tcflush(fd, TCIFLUSH)
    }

    // MARK: 读写

    private func writeLine(_ s: String) {
        var bytes = Array((s + "\n").utf8)
        _ = Darwin.write(fd, &bytes, bytes.count)
    }

    /// 读 1 字节，超时返回 nil。
    private func readByte(deadline: Date) -> UInt8? {
        var b: UInt8 = 0
        while Date() < deadline {
            let n = Darwin.read(fd, &b, 1)
            if n == 1 { return b }
            if n < 0 && errno != EAGAIN { return nil }
        }
        return nil
    }

    private func readExact(_ count: Int, deadline: Date) -> Data? {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            if Date() >= deadline { return nil }
            let n = Darwin.read(fd, &buf, count - out.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
            else if n < 0 && errno != EAGAIN { return nil }
        }
        return out
    }

    /// 发 CAP 并读回一帧 JPEG（扫描魔数跳过噪声），失败返回 nil。
    func captureFrame(timeout: TimeInterval) -> Data? {
        guard fd >= 0 else { return nil }
        tcflush(fd, TCIFLUSH)
        writeLine("CAP")
        let deadline = Date().addingTimeInterval(timeout)

        // 1) 滑动窗口找魔数
        var window: [UInt8] = []
        while true {
            guard let b = readByte(deadline: deadline) else { return nil }
            window.append(b)
            if window.count > 4 { window.removeFirst() }
            if window == magic { break }
        }
        // 2) 4 字节小端长度
        guard let lenData = readExact(4, deadline: deadline) else { return nil }
        let length = lenData.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard length > 0 && length < 2_000_000 else { return nil }
        // 3) JPEG 数据
        guard let data = readExact(Int(length), deadline: deadline) else { return nil }
        guard data.count >= 4,
              data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8,
              data[data.endIndex - 2] == 0xFF, data[data.endIndex - 1] == 0xD9 else { return nil }
        return data
    }
}
