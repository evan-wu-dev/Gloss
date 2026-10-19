import Foundation

/// 生词本：模型挑出的词按小写词形记一条。见过不满 3 次且没标「认识了」的算生词。
final class VocabStore {
    /// zh / exampleZh 沿用首版字段名：实际存的是母语释义和原句（母语可以不是中文）。
    struct Entry: Codable {
        var word: String
        var zh: String
        var level: String
        var seen: Int
        var used: Int
        var known: Bool
        var example: String
        var exampleZh: String
        var firstSeen: Date
        var lastSeen: Date
    }

    static let newThreshold = 3

    private(set) var entries: [String: Entry] = [:]
    private let url: URL

    /// 每门在学的语言一个文件。首版只有英语、存在 vocab.json，第一次打开英语时改名接上。
    static func url(for language: Language) -> URL {
        let url = ConfigStore.directory.appendingPathComponent("vocab-\(language.code).json")
        let legacy = ConfigStore.directory.appendingPathComponent("vocab.json")
        let fm = FileManager.default
        if language.code == "en", !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: url)
        }
        return url
    }

    init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    func record(_ words: [LearnWord], example: String, exampleZh: String) {
        let now = Date()
        for item in words {
            let key = item.word.lowercased()
            if var entry = entries[key] {
                entry.seen += 1
                entry.lastSeen = now
                entry.example = example
                entry.exampleZh = exampleZh
                entries[key] = entry
            } else {
                entries[key] = Entry(word: item.word, zh: item.gloss, level: item.level, seen: 1, used: 0, known: false,
                                     example: example, exampleZh: exampleZh, firstSeen: now, lastSeen: now)
            }
        }
        save()
    }

    func markUsed(_ words: [LearnWord]) {
        for item in words { entries[item.word.lowercased()]?.used += 1 }
        save()
    }

    func toggleKnown(_ word: String) {
        entries[word.lowercased()]?.known.toggle()
        save()
    }

    func isKnown(_ word: String) -> Bool { entries[word.lowercased()]?.known ?? false }

    func isNew(_ word: String) -> Bool {
        guard let entry = entries[word.lowercased()] else { return true }
        return !entry.known && entry.seen < Self.newThreshold
    }

    /// Anki 纯文本导入格式：正面词，背面释义 + 例句；只导没标认识了的。
    func exportAnki(to url: URL) throws -> Int {
        let rows = entries.values.filter { !$0.known }.sorted { $0.lastSeen > $1.lastSeen }
        let clean = { (text: String) in text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["#separator:tab", "#html:true"]
        for entry in rows {
            let back = "\(clean(entry.zh))<br><br>\(clean(entry.example))<br>\(clean(entry.exampleZh))"
            lines.append("\(clean(entry.word))\t\(back)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return rows.count
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
