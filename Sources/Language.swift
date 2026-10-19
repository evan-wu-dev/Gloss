import Foundation
import NaturalLanguage

/// 支持的语言。code 存进配置；englishName 写进提示词；displayName 是界面上显示的名字（随界面语言）。
struct Language: Equatable {
    let code: String
    let englishName: String
    let chineseName: String

    var displayName: String { tr(chineseName) }

    static let all: [Language] = [
        Language(code: "zh", englishName: "Simplified Chinese", chineseName: "中文"),
        Language(code: "en", englishName: "English", chineseName: "英语"),
        Language(code: "ja", englishName: "Japanese", chineseName: "日语"),
        Language(code: "ko", englishName: "Korean", chineseName: "韩语"),
        Language(code: "es", englishName: "Spanish", chineseName: "西班牙语"),
        Language(code: "fr", englishName: "French", chineseName: "法语"),
        Language(code: "de", englishName: "German", chineseName: "德语"),
    ]

    static func named(_ code: String) -> Language? {
        all.first { $0.code == code }
    }

    /// 旧配置里的 targetLanguage 写的是英文名（"English"），换成 code。
    static func code(forName name: String) -> String? {
        all.first { $0.englishName.lowercased() == name.lowercased() || $0.code == name.lowercased() }?.code
    }

    fileprivate var nlLanguages: [NLLanguage] {
        switch code {
        case "zh": return [.simplifiedChinese, .traditionalChinese]
        case "en": return [.english]
        case "ja": return [.japanese]
        case "ko": return [.korean]
        case "es": return [.spanish]
        case "fr": return [.french]
        case "de": return [.german]
        default: return []
        }
    }
}

enum LanguageDetector {
    /// 在给定的几种语言里判断这句是哪种；字母太少（「ok」「嗯」以外的零星字符）判不准就返回 nil。
    static func detect(_ text: String, among candidates: [Language]) -> Language? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        // 有汉字 / 假名 / 谚文时直接按文字判断，比统计模型对短句更稳。
        let hasKana = letters.contains { (0x3040...0x30FF).contains($0.value) }
        let hasHangul = letters.contains { (0xAC00...0xD7AF).contains($0.value) }
        let hasHan = letters.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        if hasKana, let ja = candidates.first(where: { $0.code == "ja" }) { return ja }
        if hasHangul, let ko = candidates.first(where: { $0.code == "ko" }) { return ko }
        if hasHan, let zh = candidates.first(where: { $0.code == "zh" }) { return zh }
        // 只有汉字、没有假名时多半是中文：日文句子几乎总带假名。只有统计模型也认定是日文才算日文。
        if hasHan, let ja = candidates.first(where: { $0.code == "ja" }) {
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.japanese, .simplifiedChinese, .traditionalChinese]
            recognizer.processString(text)
            return recognizer.dominantLanguage == .japanese ? ja : nil
        }
        if hasHan || hasKana || hasHangul { return nil }

        // 拉丁字母：至少两个词才判断，一个单词不翻。
        let words = text.split { !$0.isLetter && $0 != "'" }
        guard words.count >= 2 else { return nil }
        let latin = candidates.filter { !["zh", "ja", "ko"].contains($0.code) }
        guard !latin.isEmpty else { return nil }
        if latin.count == 1 { return latin[0] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = latin.flatMap(\.nlLanguages)
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return latin.first { $0.nlLanguages.contains(dominant) }
    }
}
