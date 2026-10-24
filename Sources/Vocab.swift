import Foundation

/// 生词本：模型挑出的词按小写词形记一条。
///
/// 在用的过程中复习：一个词在浮窗里出现、整句写完时没点它朗读，就当作记得，隔 1、3、7、15、30 天再提示，
/// 隔完最后一轮自动算掌握；点了朗读说明还不熟，从头排。自己用在学的语言写出来的词直接算掌握。
/// 等级不高于「我的水平」的词不记、不提示。见过不满 3 次的带橙点。
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
        /// 第几轮间隔；nil 表示还没在浮窗里出现过（旧数据也是 nil）。
        var step: Int?
        /// 到这个时间前再遇到也不提示。
        var dueAt: Date?
    }

    static let newThreshold = 3
    /// 每轮隔几天再提示；隔完最后一轮算掌握。
    static let intervals: [Double] = [1, 3, 7, 15, 30]
    static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    private(set) var entries: [String: Entry] = [:]
    /// 生词本有变化（记词、标掌握、删除）时回调，生词本窗口据此刷新。
    var onChange: (() -> Void)?
    let learnerLevel: String
    private let url: URL
    /// 刚记过一次的那句里显示过的词：这句的「已发送」卡片上还要接着显示，不能记完就消失。
    private var justShown: Set<String> = []

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

    init(url: URL, learnerLevel: String = "B1") {
        self.url = url
        self.learnerLevel = learnerLevel
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    /// 等级不高于我的水平；判不出等级的不算。
    func isBelowLevel(_ level: String) -> Bool {
        guard let mine = Self.levels.firstIndex(of: learnerLevel),
              let theirs = Self.levels.firstIndex(of: level.uppercased()) else { return false }
        return theirs <= mine
    }

    /// 浮窗里要不要显示这个词：没掌握、高于我的水平、到了该再提示的时候（或这句刚显示过）。
    func shouldShow(_ word: LearnWord, now: Date = Date()) -> Bool {
        guard !isBelowLevel(word.level) else { return false }
        let key = word.word.lowercased()
        guard let entry = entries[key] else { return true }
        if entry.known { return false }
        return justShown.contains(key) || (entry.dueAt ?? .distantPast) <= now
    }

    /// 一句写完时记一次。written 是用户用在学的语言自己写的原句（润色模式），里面出现的词算掌握；
    /// 翻译模式传 nil：母语原句里碰巧有同形的词（中文和日文汉字）不能算。
    func record(_ words: [LearnWord], example: String, exampleZh: String, written: String?) {
        let now = Date()
        var shown: Set<String> = []
        for item in words where !isBelowLevel(item.level) {
            let key = item.word.lowercased()
            let due = shouldShow(item, now: now) && !justShown.contains(key)
            var entry = entries[key] ?? Entry(word: item.word, zh: item.gloss, level: item.level, seen: 0, used: 0, known: false,
                                              example: example, exampleZh: exampleZh, firstSeen: now, lastSeen: now)
            entry.seen += 1
            entry.lastSeen = now
            entry.example = example
            entry.exampleZh = exampleZh
            if let written, LLMClient.appears(item.word, in: written) {
                entry.known = true
            } else if due {
                shown.insert(key)
                let step = entry.step.map { $0 + 1 } ?? 0
                if step >= Self.intervals.count {
                    entry.known = true
                } else {
                    entry.step = step
                    entry.dueAt = now.addingTimeInterval(Self.intervals[step] * 86400)
                }
            }
            entries[key] = entry
        }
        justShown = shown
        save()
    }

    func markUsed(_ words: [LearnWord]) {
        for item in words { entries[item.word.lowercased()]?.used += 1 }
        save()
    }

    /// 点了朗读：还不熟，从头排，这句写完记的时候按第一轮算。
    func relearn(_ word: String) {
        let key = word.lowercased()
        guard entries[key]?.known == false else { return }
        entries[key]?.step = nil
        entries[key]?.dueAt = nil
        save()
    }

    func setKnown(_ word: String, _ known: Bool) {
        let key = word.lowercased()
        entries[key]?.known = known
        if !known {
            entries[key]?.step = nil
            entries[key]?.dueAt = nil
        }
        save()
    }

    func delete(_ words: [String]) {
        for word in words { entries[word.lowercased()] = nil }
        save()
    }

    /// 还在学的词：没掌握、也不低于我的水平。
    var learning: [Entry] { entries.values.filter { !$0.known && !isBelowLevel($0.level) } }

    func isNew(_ word: String) -> Bool {
        guard let entry = entries[word.lowercased()] else { return true }
        return !entry.known && entry.seen < Self.newThreshold
    }

    /// Anki 纯文本导入格式：正面词，背面释义 + 例句；只导还在学的。
    func exportAnki(to url: URL) throws -> Int {
        let rows = learning.sorted { $0.lastSeen > $1.lastSeen }
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
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
        onChange?()
    }
}
