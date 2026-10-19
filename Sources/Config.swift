import Foundation

/// 一个 OpenAI 兼容的模型服务。extraBody 原样合并进请求体（关思考等各家私有参数放这里）。
struct Provider {
    let id: String
    let name: String
    let baseURL: String
    let apiKey: String
    let model: String
    let extraBody: [String: Any]
}

struct AppConfig {
    var providers: [Provider]
    var activeProviderID: String
    /// 母语与在学的语言（Language.code）。写母语 → 翻成在学的语言；写在学的语言 → 纠错润色。
    var nativeLanguage: Language
    var learningLanguage: Language
    /// 写在学的语言时是否给纠错润色。
    var checkLearning: Bool
    /// 流式输出：译文边生成边显示。
    var stream: Bool
    var learnerLevel: String
    var debounceMs: Int
    var replaceHotkey: String
    /// 朗读：off 关闭 / hotkey 按键朗读 / auto 打完一句（句末标点）自动朗读。
    var speakMode: String
    var speakHotkey: String
    /// 系统语音 identifier，空则自动挑音质最好的。
    var speakVoice: String
    /// 语速倍数，1 为系统默认。
    var speakRate: Double
    /// 等待时边框流光等效果的配色。
    var palette: Palette
    /// 句子停着不动多少秒后收起浮窗；0 表示不自动收起。
    var autoHideSeconds: Double
    /// 界面语言：system 跟随系统 / zh / en。
    var uiLanguage: String
    /// 翻译范围：句子 / 段落。
    var scope: Sentence.Scope

    var activeProvider: Provider? {
        providers.first { $0.id == activeProviderID } ?? providers.first
    }
}

enum ConfigError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return tr("配置文件有误：%@", message)
        }
    }
}

enum ConfigStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveTranslate", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static let defaultJSON = """
    {
      "activeProvider": "deepseek",
      "providers": [
        {
          "id": "deepseek",
          "name": "DeepSeek",
          "baseURL": "https://api.deepseek.com",
          "apiKey": "",
          "model": "deepseek-flash",
          "extraBody": { "reasoning_effort": "none" }
        },
        {
          "id": "glm",
          "name": "智谱 GLM",
          "baseURL": "https://open.bigmodel.cn/api/paas/v4",
          "apiKey": "",
          "model": "glm-5.3-flash",
          "extraBody": { "thinking": { "type": "disabled" } }
        }
      ],
      "nativeLanguage": "zh",
      "learningLanguage": "en",
      "checkLearning": true,
      "stream": true,
      "learnerLevel": "B1",
      "debounceMs": 600,
      "replaceHotkey": "ctrl+option+e",
      "speakMode": "hotkey",
      "speakHotkey": "ctrl+option+s",
      "speakVoice": "",
      "speakRate": 1.0,
      "palette": "aurora",
      "autoHideSeconds": 15,
      "uiLanguage": "system",
      "translateScope": "sentence"
    }
    """

    /// 没有配置文件时写一份默认的（权限 600，里面放 API Key）。
    static func load() throws -> AppConfig {
        try ensureFile()
        let data = try Data(contentsOf: fileURL)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> AppConfig {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid(tr("顶层必须是对象"))
        }
        guard let list = root["providers"] as? [[String: Any]], !list.isEmpty else {
            throw ConfigError.invalid(tr("providers 不能为空"))
        }
        let providers = try list.map { item -> Provider in
            guard let id = item["id"] as? String, let baseURL = item["baseURL"] as? String,
                  let model = item["model"] as? String else {
                throw ConfigError.invalid(tr("每个 provider 都要有 id / baseURL / model"))
            }
            return Provider(
                id: id,
                name: item["name"] as? String ?? id,
                baseURL: baseURL,
                apiKey: item["apiKey"] as? String ?? "",
                model: model,
                extraBody: item["extraBody"] as? [String: Any] ?? [:]
            )
        }
        return AppConfig(
            providers: providers,
            activeProviderID: root["activeProvider"] as? String ?? providers[0].id,
            nativeLanguage: Language.named(root["nativeLanguage"] as? String ?? "zh") ?? Language.all[0],
            learningLanguage: Language.named(root["learningLanguage"] as? String
                ?? Language.code(forName: root["targetLanguage"] as? String ?? "") ?? "en") ?? Language.all[1],
            checkLearning: root["checkLearning"] as? Bool ?? true,
            stream: root["stream"] as? Bool ?? true,
            learnerLevel: root["learnerLevel"] as? String ?? "B1",
            debounceMs: root["debounceMs"] as? Int ?? 600,
            replaceHotkey: root["replaceHotkey"] as? String ?? "ctrl+option+e",
            speakMode: root["speakMode"] as? String ?? "hotkey",
            speakHotkey: root["speakHotkey"] as? String ?? "ctrl+option+s",
            speakVoice: root["speakVoice"] as? String ?? "",
            speakRate: root["speakRate"] as? Double ?? 1.0,
            palette: Palette(rawValue: root["palette"] as? String ?? "") ?? .aurora,
            autoHideSeconds: max(root["autoHideSeconds"] as? Double ?? 15, 0),
            uiLanguage: root["uiLanguage"] as? String ?? "system",
            scope: Sentence.Scope(rawValue: root["translateScope"] as? String ?? "") ?? .sentence
        )
    }

    /// 只改一个顶层字段，其余原样保留。
    static func set(_ key: String, _ value: Any) throws {
        let data = try Data(contentsOf: fileURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid(tr("顶层必须是对象"))
        }
        root[key] = value
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try output.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 改某个模型服务的字段（name / baseURL / model / apiKey / extraBody）；没有这个 id 就新加一项。
    static func setProvider(_ id: String, _ changes: [String: Any]) throws {
        try editProviders { list in
            if let index = list.firstIndex(where: { $0["id"] as? String == id }) {
                list[index].merge(changes) { _, new in new }
            } else {
                list.append(changes.merging(["id": id]) { _, new in new })
            }
        }
    }

    /// 删掉一个模型服务；删的是正在用的就换成剩下的第一个。至少留一个。
    static func removeProvider(_ id: String) throws {
        var removedActive = false
        try editProviders { list in
            guard list.count > 1 else { return }
            list.removeAll { $0["id"] as? String == id }
            removedActive = true
        } root: { root in
            guard removedActive, root["activeProvider"] as? String == id,
                  let first = (root["providers"] as? [[String: Any]])?.first?["id"] as? String else { return }
            root["activeProvider"] = first
        }
    }

    private static func editProviders(_ edit: (inout [[String: Any]]) -> Void,
                                      root finish: (inout [String: Any]) -> Void = { _ in }) throws {
        let data = try Data(contentsOf: fileURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var list = root["providers"] as? [[String: Any]] else {
            throw ConfigError.invalid(tr("providers 不能为空"))
        }
        edit(&list)
        root["providers"] = list
        finish(&root)
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try output.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func ensureFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try Data(defaultJSON.utf8).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
