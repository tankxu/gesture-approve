import AppKit
import Carbon.HIToolbox

/// 全局热键（基于 Carbon RegisterEventHotKey）：免辅助功能权限、能在其它 app 聚焦时触发、并消费该按键。
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Carbon 修饰键掩码（供调用方使用，避免到处 import Carbon）。
    static let controlShift = Int(controlKey) | Int(shiftKey)
    static let keyY = 0x10   // kVK_ANSI_Y
    static let keyN = 0x2D   // kVK_ANSI_N

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// 注册一个全局热键。modifiers 用 Carbon 掩码（controlKey/shiftKey/...）。
    @discardableResult
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x47415050), id: id) // 'GAPP'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs[id] = ref }
        return id
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let id = hkID.id
                DispatchQueue.main.async { HotKeyManager.shared.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
    }
}
