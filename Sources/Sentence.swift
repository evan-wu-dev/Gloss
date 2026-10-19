import Foundation

/// 输入框里光标所在的那句话：range 是 UTF-16 偏移（与 AX 的 CFRange 一致）。
struct SentenceSpan: Equatable {
    let range: NSRange
    let text: String
}

enum Sentence {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// 没写协议的网址、域名、邮箱、localhost / IP 和文件路径：NSDataDetector 认不全，补一道正则。
    private static let linkPattern = try? NSRegularExpression(
        pattern: #"(?:[\w.+-]+@)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?|\b(?:localhost|\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?(?:[/?#][^\s]*)?|(?:~|\.{1,2})?/[^\s]+"#)

    /// 去掉网址、邮箱、文件路径后剩下的文字。像 github.com/foo/bar 这种拆开是一串英文单词，
    /// 不先去掉会被当成在写英文；地址栏里只有网址时也就不该弹翻译。
    static func withoutLinks(_ text: String) -> String {
        let s = NSMutableString(string: text)
        for regex in [linkDetector as NSRegularExpression?, linkPattern].compactMap({ $0 }) {
            for match in regex.matches(in: s as String, range: NSRange(location: 0, length: s.length)).reversed() {
                s.replaceCharacters(in: match.range, with: " ")
            }
        }
        return s as String
    }

    private static let terminators: Set<unichar> = Set("。！？!?；;…\n\r".utf16)
    private static let newlines: Set<unichar> = Set("\n\r".utf16)

    /// 光标所在的那句话；光标紧跟在句末标点后时，取刚写完的那句。
    static func current(in text: String, cursor: Int) -> SentenceSpan? {
        let s = text as NSString
        guard s.length > 0 else { return nil }
        let pos = min(max(cursor, 0), s.length)

        var anchor = pos
        while anchor > 0, isInlineBlank(s, anchor - 1) { anchor -= 1 }

        var start: Int
        var end: Int
        if anchor > 0, isTerminator(s, anchor - 1), !newlines.contains(s.character(at: anchor - 1)) {
            end = anchor
            start = anchor - 1
        } else {
            start = anchor
            end = pos
            while end < s.length, !isTerminator(s, end) { end += 1 }
            if end < s.length, !newlines.contains(s.character(at: end)) { end += 1 }
        }
        while start > 0, !isTerminator(s, start - 1) { start -= 1 }

        while start < end, isBlank(s, start) { start += 1 }
        while end > start, isBlank(s, end - 1) { end -= 1 }
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        return SentenceSpan(range: range, text: s.substring(with: range))
    }

    /// 翻译范围：句子（默认）或光标所在的整段。
    enum Scope: String { case sentence, paragraph }

    /// 当前用哪种范围，读配置时设置。
    static var scope = Scope.sentence
    /// 段落模式一次最多翻这么多字，超过就退回句子模式，免得一次请求太大。
    static let paragraphLimit = 2000

    /// 要翻译的那一段。段落模式取光标所在的段（空行分隔；聊天框通常整框就是一段）；
    /// 句子模式短句整句翻，长句只取光标所在的小句和它前面一小句，免得每次停顿都整句重翻、越写越慢。
    static func target(in text: String, cursor: Int) -> SentenceSpan? {
        if scope == .paragraph, let block = paragraph(in: text, cursor: cursor), (block.text as NSString).length <= paragraphLimit {
            return block
        }
        guard let sentence = current(in: text, cursor: cursor) else { return nil }
        guard isLong(sentence.text) else { return sentence }
        return clauses(of: sentence, in: text as NSString, cursor: cursor) ?? sentence
    }

    /// 长句：汉字（含假名、谚文）超过 80 个，或超过 30 个词，或超过 500 字。
    static func isLong(_ text: String) -> Bool {
        let cjk = text.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }.count
        return cjk > 80 || text.split(whereSeparator: \.isWhitespace).count > 30 || (text as NSString).length > 500
    }

    /// 光标所在的段：两段之间隔着空行。
    static func paragraph(in text: String, cursor: Int) -> SentenceSpan? {
        let s = text as NSString
        guard s.length > 0, let breaks = try? NSRegularExpression(pattern: "\\n[ \\t]*\\n") else { return nil }
        let pos = min(max(cursor, 0), s.length)
        var start = 0
        var end = s.length
        for match in breaks.matches(in: text, range: NSRange(location: 0, length: s.length)) {
            if NSMaxRange(match.range) <= pos { start = NSMaxRange(match.range) } else if match.range.location >= pos { end = match.range.location; break }
        }
        while start < end, isBlank(s, start) { start += 1 }
        while end > start, isBlank(s, end - 1) { end -= 1 }
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        return SentenceSpan(range: range, text: s.substring(with: range))
    }

    /// 小句之间的分隔：中文的逗号、顿号、冒号；英文逗号、冒号要后面跟空格才算（1,000、10:30、https: 不切）。
    private static func isClauseBreak(_ s: NSString, _ i: Int) -> Bool {
        let c = s.character(at: i)
        if [0xFF0C, 0x3001, 0xFF1A].contains(c) { return true }
        guard c == 0x2C || c == 0x3A else { return false }
        return i + 1 < s.length && isBlank(s, i + 1)
    }

    /// 长句里光标所在的小句，连同前面一小句作为上下文。光标紧跟在逗号后时，取刚写完的那一小句。
    private static func clauses(of sentence: SentenceSpan, in s: NSString, cursor: Int) -> SentenceSpan? {
        let lower = sentence.range.location
        let upper = NSMaxRange(sentence.range)
        var anchor = min(max(cursor, lower), upper)
        while anchor > lower, isInlineBlank(s, anchor - 1) { anchor -= 1 }

        var end: Int
        var start: Int
        if anchor > lower, isClauseBreak(s, anchor - 1) {
            end = anchor
            start = anchor - 1
        } else {
            end = anchor
            while end < upper, !isClauseBreak(s, end) { end += 1 }
            if end < upper { end += 1 }
            start = anchor
        }
        while start > lower, !isClauseBreak(s, start - 1) { start -= 1 }
        // 再往前带上一小句。
        if start > lower {
            start -= 1
            while start > lower, !isClauseBreak(s, start - 1) { start -= 1 }
        }
        while start < end, isBlank(s, start) { start += 1 }
        while end > start, isBlank(s, end - 1) { end -= 1 }
        guard end > start, NSRange(location: start, length: end - start) != sentence.range else { return nil }
        let range = NSRange(location: start, length: end - start)
        return SentenceSpan(range: range, text: s.substring(with: range))
    }

    /// 含汉字才需要翻译；已经是外文的句子不翻。
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// 光标前是紧贴汉字的小写拼音（「右边bian ju」），多半是输入法还没上屏的组字，先不翻。
    static func isComposing(_ text: String, cursor: Int) -> Bool {
        let s = text as NSString
        var i = min(max(cursor, 0), s.length)
        var sawLetter = false
        while i > 0 {
            let c = s.character(at: i - 1)
            if (0x61...0x7A).contains(c) { sawLetter = true } else if c != 0x20, c != 0x27 { break }
            i -= 1
        }
        // 汉字后先空一格再打的英文（「打开 app」）是正常混排，不算组字。
        guard sawLetter, i > 0, (0x61...0x7A).contains(s.character(at: i)) else { return false }
        return containsHan(s.substring(with: NSRange(location: i - 1, length: 1)))
    }

    /// 以句末标点结尾，即这句已经写完。
    static func isComplete(_ text: String) -> Bool {
        let s = text as NSString
        return s.length > 0 && isTerminator(s, s.length - 1)
    }

    /// `.` 只有后面是空白或文本结尾才算句号，`3.5`、`a.b` 不断句。
    private static func isTerminator(_ s: NSString, _ i: Int) -> Bool {
        let c = s.character(at: i)
        if terminators.contains(c) { return true }
        guard c == 0x2E else { return false }
        return i + 1 >= s.length || isBlank(s, i + 1)
    }

    private static func isBlank(_ s: NSString, _ i: Int) -> Bool {
        guard let scalar = Unicode.Scalar(s.character(at: i)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isInlineBlank(_ s: NSString, _ i: Int) -> Bool {
        isBlank(s, i) && !newlines.contains(s.character(at: i))
    }
}
