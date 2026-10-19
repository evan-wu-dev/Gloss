import AppKit
import ApplicationServices

/// 当前聚焦输入框的一次快照。
struct FocusSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let text: String
    let cursor: Int
    let sentence: SentenceSpan
}

enum AX {
    private static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]
    private static var preparedPIDs: Set<pid_t> = []

    static func snapshot() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        prepare(app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = element(appElement, kAXFocusedUIElementAttribute) else { return nil }
        if string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return nil }
        guard let text = string(element, kAXValueAttribute), (text as NSString).length <= 20000,
              let selection = range(element, kAXSelectedTextRangeAttribute) else { return nil }
        let cursor = selection.location + selection.length
        guard let sentence = Sentence.target(in: text, cursor: cursor) else { return nil }
        return FocusSnapshot(element: element, pid: app.processIdentifier, text: text, cursor: cursor, sentence: sentence)
    }

    /// 光标处的屏幕矩形（AX 坐标：主屏左上为原点）；取不到时退回输入框本身的矩形。
    static func caretRect(_ snap: FocusSnapshot) -> CGRect? {
        let length = (snap.text as NSString).length
        var candidates: [CFRange] = []
        if snap.cursor > 0 { candidates.append(CFRange(location: snap.cursor - 1, length: 1)) }
        if snap.cursor < length { candidates.append(CFRange(location: snap.cursor, length: 1)) }
        candidates.append(CFRange(location: snap.cursor, length: 0))
        for var candidate in candidates {
            guard let param = AXValueCreate(.cfRange, &candidate) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(snap.element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let rect = rectValue(out), rect.width >= 0, rect.height > 0, rect.origin != .zero else { continue }
            return rect
        }
        guard let origin = pointValue(copy(snap.element, kAXPositionAttribute)),
              let size = sizeValue(copy(snap.element, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 把整句换成译文。先用 AX 选中这句并改写；有些应用（Electron / Chromium 系）设选区报成功却没真选中，
    /// 这时写入会变成在光标处插入，所以选区要读回来确认，确认不了就用键盘 ⇧← 选中再粘贴。
    static func replace(_ snap: FocusSnapshot, with replacement: String) -> Bool {
        let range = snap.sentence.range
        var target = CFRange(location: range.location, length: range.length)
        if let rangeValue = AXValueCreate(.cfRange, &target),
           AXUIElementSetAttributeValue(snap.element, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
           let selected = self.range(snap.element, kAXSelectedTextRangeAttribute),
           selected.location == target.location, selected.length == target.length {
            if AXUIElementSetAttributeValue(snap.element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success,
               string(snap.element, kAXValueAttribute) != snap.text {
                return true
            }
            // 选中了但写不进去：⌘V 会替换掉选中的这句。
            paste(replacement)
            return true
        }
        guard selectWithKeyboard(snap) else { return false }
        paste(replacement, after: 0.05)
        return true
    }

    /// 用方向键把光标挪到句尾，再按句子的字数 ⇧← 选中整句。
    private static func selectWithKeyboard(_ snap: FocusSnapshot) -> Bool {
        let text = snap.text as NSString
        let range = snap.sentence.range
        let end = NSMaxRange(range)
        guard snap.cursor <= end, snap.cursor >= range.location, end <= text.length else { return false }
        // 按字形（emoji、组合字符算一个）数，与方向键一次走一格一致。
        let ahead = text.substring(with: NSRange(location: snap.cursor, length: end - snap.cursor)).count
        let count = snap.sentence.text.count
        let source = CGEventSource(stateID: .hidSystemState)
        func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        let left: CGKeyCode = 123, right: CGKeyCode = 124
        for _ in 0..<ahead { press(right, []) }
        for _ in 0..<count { press(left, .maskShift) }
        return true
    }

    private static func paste(_ text: String, after delay: TimeInterval = 0) {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        board.clearContents()
        board.setString(text, forType: .string)

        // 前面刚发了一串方向键时稍等一下，让应用先把选区处理完。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyV: CGKeyCode = 9
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.5) {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    /// Electron 与 Chromium 系默认不暴露网页里的文本，要显式打开辅助功能树。
    private static func prepare(_ app: NSRunningApplication) {
        guard !preparedPIDs.contains(app.processIdentifier) else { return }
        preparedPIDs.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let bundle = app.bundleIdentifier, chromiumBundles.contains(bundle) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        copy(element, name) as? String
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = copy(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let value = axValue(copy(element, name)) else { return nil }
        var result = CFRange()
        return AXValueGetValue(value, .cfRange, &result) ? result : nil
    }

    private static func rectValue(_ ref: CFTypeRef?) -> CGRect? {
        guard let value = axValue(ref) else { return nil }
        var result = CGRect.zero
        return AXValueGetValue(value, .cgRect, &result) ? result : nil
    }

    private static func pointValue(_ ref: CFTypeRef?) -> CGPoint? {
        guard let value = axValue(ref) else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    private static func sizeValue(_ ref: CFTypeRef?) -> CGSize? {
        guard let value = axValue(ref) else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }

    private static func axValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
}
