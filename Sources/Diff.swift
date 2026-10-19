import Foundation

/// 润色前后按词对比，标出删掉和加上的部分。中日韩按字，拉丁语言按词。
enum Diff {
    enum Kind: Equatable { case same, deleted, inserted }

    struct Segment: Equatable {
        let text: String
        let kind: Kind
    }

    /// 改动的词超过新句子的一半时返回 nil：差不多整句重写了，逐处标出来反而难读。
    static func compare(_ old: String, _ new: String) -> [Segment]? {
        let a = tokens(old), b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else { return nil }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var segments: [Segment] = []
        var changed = 0
        func push(_ text: String, _ kind: Kind) {
            // 加上的空白不必高亮，只是排版。
            let kind = kind == .inserted && text.allSatisfy(\.isWhitespace) ? .same : kind
            if kind != .same, !text.allSatisfy(\.isWhitespace) { changed += 1 }
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1] = Segment(text: last.text + text, kind: kind)
            } else {
                segments.append(Segment(text: text, kind: kind))
            }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                push(a[i], .same)
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                push(a[i], .deleted)
                i += 1
            } else {
                push(b[j], .inserted)
                j += 1
            }
        }
        while i < a.count { push(a[i], .deleted); i += 1 }
        while j < b.count { push(b[j], .inserted); j += 1 }

        let words = b.filter { !$0.allSatisfy(\.isWhitespace) }.count
        return changed * 2 > max(words, 1) ? nil : segments
    }

    /// 连续的字母数字（含撇号）是一个词，连续空白是一段，中日韩字符和标点各自一个。
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace = false
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
        }
        for ch in text {
            if ch.isWhitespace {
                if !currentIsSpace { flush() }
                currentIsSpace = true
                current.append(ch)
            } else if !isCJK(ch), ch.isLetter || ch.isNumber || ch == "'" || ch == "’" {
                if currentIsSpace { flush() }
                currentIsSpace = false
                current.append(ch)
            } else {
                flush()
                currentIsSpace = false
                result.append(String(ch))
            }
        }
        flush()
        return result
    }

    private static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }
}
