import AVFoundation

/// 用系统语音朗读译文（离线、免费）。没指定声音时挑该语言里音质最好的那个。
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    func configure(language: Language, voiceID: String, rate: Double) {
        self.rate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        if !voiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceID) {
            voice = chosen
            return
        }
        let code = language.code
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let regional = ["en": "en-US", "zh": "zh-CN"][code]
        let preferred = candidates.filter { $0.language == regional }
        voice = (preferred.isEmpty ? candidates : preferred).max { Self.score($0) < Self.score($1) }
            ?? AVSpeechSynthesisVoice(language: code)
    }

    func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        synthesizer.speak(utterance)
    }

    var voiceName: String { voice?.name ?? tr("系统默认") }

    /// 音质优先；同档时避开 Zarvox 这类趣味音效声音（speech.synthesis.voice.*）和老的 Eloquence 声音。
    private static func score(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = voice.quality.rawValue * 10
        if voice.identifier.contains("speech.synthesis.voice") { score -= 100 }
        if voice.identifier.contains("eloquence") { score -= 5 }
        if voice.name == "Samantha" { score += 1 }
        return score
    }

}
