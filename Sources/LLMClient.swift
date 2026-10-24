import Foundation

struct LearnWord {
    let word: String
    /// 用母语写的简短释义（非拉丁文字的词带读音）。
    let gloss: String
    let level: String
}

struct TranslationResult {
    /// 翻译模式是译文；润色模式是改好的句子。都是在学的语言。
    let translation: String
    /// 润色模式下用母语说明改了什么；翻译模式为空。
    let note: String
    let words: [LearnWord]
}

/// 写母语 → 翻成在学的语言；写在学的语言 → 纠错润色。
enum TranslateMode {
    case translate
    case polish
}

enum LLMError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let name): return tr("%@ 未配置 API Key（设置 → 模型）", name)
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(120))"
        case .badResponse: return tr("模型返回内容无法解析")
        }
    }
}

/// OpenAI 兼容的 /chat/completions。一次请求同时拿译文和值得学的词；流式时边生成边回调译文。
final class LLMClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// onPartial 在后台线程回调，参数是目前生成出来的那截译文。
    func translate(_ sentence: String, mode: TranslateMode, config: AppConfig,
                   onPartial: @escaping (String) -> Void,
                   completion: @escaping (Result<TranslationResult, Error>) -> Void) {
        guard let provider = config.activeProvider else { return completion(.failure(LLMError.badResponse)) }
        guard !provider.apiKey.isEmpty else { return completion(.failure(LLMError.missingKey(provider.name))) }
        let prompt = Self.systemPrompt(mode: mode, config: config)
        send(sentence, prompt: prompt, config: config, provider: provider, strict: true, onPartial: onPartial, completion: completion)
    }

    /// strict 请求带 response_format、extraBody（流式也只在 strict 下开）；接口不认（4xx）时退回最朴素的请求再试一次。
    private func send(_ sentence: String, prompt: String, config: AppConfig, provider: Provider, strict: Bool,
                      onPartial: @escaping (String) -> Void,
                      completion: @escaping (Result<TranslationResult, Error>) -> Void) {
        var body: [String: Any] = [
            "model": provider.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": sentence],
            ],
        ]
        let streaming = strict && config.stream
        if strict {
            body["response_format"] = ["type": "json_object"]
            body.merge(provider.extraBody) { _, extra in extra }
        }
        if streaming { body["stream"] = true }

        let base = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let url = URL(string: base + "/chat/completions"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return completion(.failure(LLMError.badResponse))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        let finish = { (status: Int, data: Data, content: String?, error: Error?) in
            if let error { return completion(.failure(error)) }
            if strict, (400..<500).contains(status), status != 401, status != 429 {
                return self.send(sentence, prompt: prompt, config: config, provider: provider, strict: false,
                                 onPartial: onPartial, completion: completion)
            }
            guard status == 200 else {
                return completion(.failure(LLMError.http(status, String(decoding: data, as: UTF8.self))))
            }
            guard let text = content ?? Self.messageContent(data), let result = Self.parseResult(text) else {
                return completion(.failure(LLMError.badResponse))
            }
            completion(.success(result))
        }

        if streaming {
            let handler = StreamHandler(onPartial: onPartial) { status, raw, content, error in
                finish(status, raw, status == 200 ? content : nil, error)
            }
            let streamSession = URLSession(configuration: session.configuration, delegate: handler, delegateQueue: nil)
            streamSession.dataTask(with: request).resume()
        } else {
            session.dataTask(with: request) { data, response, error in
                finish((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), nil, error)
            }.resume()
        }
    }

    private static func messageContent(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    static func systemPrompt(mode: TranslateMode, config: AppConfig) -> String {
        let native = config.nativeLanguage.englishName
        let learning = config.learningLanguage.englishName
        let level = config.learnerLevel
        let reading = ["zh", "ja", "ko"].contains(config.learningLanguage.code)
            ? " Because \(learning) is not written in Latin letters, start each gloss with the reading (pinyin / kana / romanization)."
            : ""
        let wordRule = """
        Pick words or short phrases that literally appear in your sentence and are worth learning for a CEFR \(level) learner: \
        words strictly above \(level) (never \(level) or below), or useful collocations above that level. Skip basic and everyday words. \
        Rate each word's CEFR level honestly; it is used to filter. Never suggest a word that is not in your sentence. \
        For short or simple sentences, return an empty list. Use the dictionary form. Each gloss is a short meaning in \(native).\(reading)
        """
        switch mode {
        case .translate:
            return """
            You are a language-learning assistant built into a typing tool. The user is a native \(native) speaker learning \(learning) (CEFR \(level)). \
            They are typing \(native) in a chat, email or document.
            Translate the text (a sentence, part of a long sentence, or a whole paragraph) into natural, idiomatic \(learning), \
            the way a native speaker would write it in the same context. If it is only part of a sentence, translate just that part. \
            Keep it concise. Keep names, code, URLs, numbers, emoji and words already in other languages unchanged. Use punctuation that fits \(learning).
            Then pick 0 to 3 words. \(wordRule)
            Reply with JSON only, "translation" first:
            {"translation": "...", "words": [{"word": "...", "gloss": "...", "level": "B2"}]}
            """
        case .polish:
            return """
            You are a language-learning assistant built into a typing tool. The user is a native \(native) speaker learning \(learning) (CEFR \(level)). \
            They are writing \(learning) in a chat, email or document.
            Rewrite the text (a sentence, part of one, or a paragraph) so it is correct and natural \(learning), keeping their meaning and tone. Change as little as needed; \
            if it is already correct and natural, return it unchanged.
            "note": one short sentence in \(native) explaining the most important fix, or "" if unchanged.
            Then pick 0 to 2 words from your version that the user could learn. \(wordRule)
            Reply with JSON only, "translation" first:
            {"translation": "...", "note": "...", "words": [{"word": "...", "gloss": "...", "level": "B2"}]}
            """
        }
    }

    /// 流式时 JSON 还没写完，从 `"translation": "...` 里抠出已经生成的那截。
    static func partialTranslation(_ json: String) -> String? {
        guard let key = json.range(of: "\"translation\"") else { return nil }
        var index = key.upperBound
        while index < json.endIndex, json[index] != "\"" {
            guard json[index] == ":" || json[index].isWhitespace else { return nil }
            index = json.index(after: index)
        }
        guard index < json.endIndex else { return nil }
        index = json.index(after: index)
        var value = ""
        while index < json.endIndex {
            let char = json[index]
            if char == "\"" { break }
            if char == "\\" {
                let next = json.index(after: index)
                guard next < json.endIndex else { break }
                switch json[next] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "u":
                    let hexStart = json.index(after: next)
                    guard let hexEnd = json.index(hexStart, offsetBy: 4, limitedBy: json.endIndex),
                          let code = UInt32(json[hexStart..<hexEnd], radix: 16), let scalar = Unicode.Scalar(code) else {
                        return value
                    }
                    value.unicodeScalars.append(scalar)
                    // 下面统一前进两格，正好落到 \uXXXX 之后。
                    index = json.index(hexEnd, offsetBy: -2)
                default: value.append(json[next])
                }
                index = json.index(after: index)
                index = json.index(after: index)
                continue
            }
            value.append(char)
            index = json.index(after: index)
        }
        return value
    }

    /// 模型偶尔会推荐句子里没有的词（「Can it be done?」给出 achieve），这里只留真出现在句子里的。
    /// 拉丁文字按词干前缀放宽（get off work 能匹配 getting off work）；中日韩直接按子串找，读音部分不算。
    static func appears(_ phrase: String, in translation: String) -> Bool {
        let core = phrase.components(separatedBy: CharacterSet(charactersIn: "(（")).first?
            .trimmingCharacters(in: .whitespaces) ?? phrase
        guard !core.isEmpty else { return false }
        if core.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
            return translation.contains(core)
        }
        let tokens = translation.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        let parts = core.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            let stem = String(part.prefix(max(3, part.count - 2)))
            return tokens.contains { $0 == part || $0.hasPrefix(stem) }
        }
    }

    /// 取第一个 { 到最后一个 } 之间的 JSON；模型没按格式回时把整段当译文。
    static func parseResult(_ content: String) -> TranslationResult? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close,
           let root = try? JSONSerialization.jsonObject(with: Data(trimmed[open...close].utf8)) as? [String: Any],
           let translation = root["translation"] as? String {
            let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = (root["words"] as? [[String: Any]] ?? []).compactMap { item -> LearnWord? in
                guard let word = item["word"] as? String, !word.isEmpty else { return nil }
                let gloss = item["gloss"] as? String ?? item["zh"] as? String ?? ""
                return LearnWord(word: word, gloss: gloss, level: item["level"] as? String ?? "")
            }
            let note = (root["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return TranslationResult(translation: text, note: note, words: words.filter { appears($0.word, in: text) })
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{") else { return nil }
        return TranslationResult(translation: trimmed, note: "", words: [])
    }
}

/// 读 SSE：逐行取 `data: {...}` 里的 delta.content 拼起来，每多一截译文就回调一次。
private final class StreamHandler: NSObject, URLSessionDataDelegate {
    private let onPartial: (String) -> Void
    private let onDone: (Int, Data, String, Error?) -> Void
    private var status = 0
    private var raw = Data()
    private var pending = Data()
    private var content = ""
    private var lastPartial = ""

    init(onPartial: @escaping (String) -> Void, onDone: @escaping (Int, Data, String, Error?) -> Void) {
        self.onPartial = onPartial
        self.onDone = onDone
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else {
            raw.append(data)
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            consume(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self)) }
        onDone(status, raw, content, error)
        session.finishTasksAndInvalidate()
    }

    private func consume(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]",
              let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let piece = delta["content"] as? String, !piece.isEmpty else { return }
        content += piece
        if let partial = LLMClient.partialTranslation(content), partial != lastPartial, !partial.isEmpty {
            lastPartial = partial
            onPartial(partial)
        }
    }
}
