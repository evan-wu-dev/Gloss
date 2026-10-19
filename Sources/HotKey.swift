import AppKit
import Carbon

/// 全局快捷键（Carbon RegisterEventHotKey，不需要额外权限）。写法如 "ctrl+option+e"。
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    let display: String

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "space": 49, "return": 36,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50, "\\": 42,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
    ]

    /// 设置里录快捷键：把按下的组合转成配置里的写法（"ctrl+option+e"）；没带修饰键或键不支持时返回 nil。
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        let parts = [(NSEvent.ModifierFlags.control, "ctrl"), (.option, "option"), (.shift, "shift"), (.command, "cmd")]
            .filter { modifiers.contains($0.0) }.map(\.1)
        guard !parts.isEmpty else { return nil }
        return (parts + [key]).joined(separator: "+")
    }

    static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32, display: String)? {
        var modifiers: UInt32 = 0
        var symbols = ""
        var keyCode: UInt32?
        var keyName = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey); symbols += "⌃"
            case "option", "opt", "alt": modifiers |= UInt32(optionKey); symbols += "⌥"
            case "shift": modifiers |= UInt32(shiftKey); symbols += "⇧"
            case "cmd", "command": modifiers |= UInt32(cmdKey); symbols += "⌘"
            default:
                guard keyCode == nil, let code = keyCodes[part] else { return nil }
                keyCode = code
                keyName = part.count == 1 ? part.uppercased() : part.uppercased() == "SPACE" ? "Space" : part.capitalized
            }
        }
        guard let keyCode, modifiers != 0 else { return nil }
        let order = ["⌃", "⌥", "⇧", "⌘"].filter { symbols.contains($0) }.joined()
        return (keyCode, modifiers, order + keyName)
    }

    init?(spec: String, handler: @escaping () -> Void) {
        guard let parsed = Self.parse(spec) else { return nil }
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        display = parsed.display
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C565452), id: id)
        guard RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
