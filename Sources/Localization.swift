import Foundation

/// 界面语言。代码里直接写中文文案，用 tr() 包一层；其他语言按中文原文查表（英文表在下面，其余在 Localization+Tables.swift）。
/// 带参数的文案用 %@ 占位：tr("翻译失败：%@", message)。
enum L10n {
    /// 支持的界面语言，与可选的学习语言一致。
    static let languages = ["zh", "en", "ja", "ko", "es", "fr", "de"]
    /// 配置里的 uiLanguage："system" 跟随系统，或上面某个语言代码。
    static let choices = ["system"] + languages

    private(set) static var current = systemLanguage

    static func apply(_ setting: String) {
        current = languages.contains(setting) ? setting : systemLanguage
    }

    /// 设置里「界面语言」各选项的显示名：每种语言用它自己的写法，切错了也认得出来。
    static func choiceTitle(_ setting: String) -> String {
        switch setting {
        case "zh": return "简体中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "es": return "Español"
        case "fr": return "Français"
        case "de": return "Deutsch"
        default: return tr("跟随系统")
        }
    }

    /// 系统首选语言里第一个支持的；都不支持时用英文。
    private static var systemLanguage: String {
        for preferred in Locale.preferredLanguages {
            if let match = languages.first(where: { preferred.hasPrefix($0) }) { return match }
        }
        return "en"
    }

    private static let tables: [String: [String: String]] = [
        "en": english, "ja": japanese, "ko": korean, "es": spanish, "fr": french, "de": german,
    ]

    /// 中文直接用原文；其他语言查表，查不到退回英文，再退回中文。
    static func lookup(_ key: String) -> String {
        guard current != "zh" else { return key }
        return tables[current]?[key] ?? english[key] ?? key
    }

    static let english: [String: String] = [
        "字里行间": "Gloss",
        "跟随系统": "System",
        "界面语言": "Language",

        // 菜单
        "配置有误": "Configuration error",
        "⚠️ 未授予辅助功能权限，点此打开设置": "⚠️ Accessibility access needed — click to open Settings",
        "在学的语言": "Learning",
        "模型": "Model",
        "朗读": "Read aloud",
        "关闭": "Off",
        "按快捷键": "With shortcut",
        "自动朗读": "Automatically",
        "设置…": "Settings…",
        "退出": "Quit",

        // 浮窗
        "润色": "Polished",
        "✓ 没问题，很地道": "✓ Looks natural",
        "替换原句": "Replace sentence",
        "复制": "Copy",
        "复制译文": "Copy translation",

        // 错误
        "翻译失败：%@": "Translation failed: %@",
        "%@ 未配置 API Key（设置 → 模型）": "%@ has no API key (Settings → Model)",
        "模型返回内容无法解析": "Couldn't read the model's response",
        "配置文件有误：%@": "Invalid configuration: %@",
        "顶层必须是对象": "the top level must be an object",
        "providers 不能为空": "providers must not be empty",
        "每个 provider 都要有 id / baseURL / model": "every provider needs id / baseURL / model",
        "替换快捷键「%@」无法注册（写法不对或被占用）": "Couldn't register the replace shortcut \"%@\" (invalid or already in use)",
        "朗读快捷键「%@」无法注册（写法不对或被占用）": "Couldn't register the read-aloud shortcut \"%@\" (invalid or already in use)",
        "开机自启设置失败：%@": "Couldn't change Open at Login: %@",
        "系统默认": "System default",

        // 设置：标签页
        "通用": "General",
        "语言": "Languages",
        "快捷键": "Shortcuts",
        "外观": "Appearance",

        // 设置：通用
        "开机自动启动": "Open at Login",
        "写外语时纠错润色": "Polish what I write in the language I'm learning",
        "流式输出": "Stream translations",
        "停顿多久开始翻译": "Translate after a pause of",
        "%g 秒": "%g s",
        "%@ 秒": "%@ s",
        "自动收起": "Hide automatically after",
        "不自动收起": "Never",
        "纠错润色：用在学的语言写东西时，给出更地道的写法并标出改动。\n自动收起：句子多久没变化就收起浮窗，鼠标停在浮窗上时不收。":
            "Polish: when you write in the language you're learning, suggests a more natural version and marks the changes.\nHide automatically: hides the bubble once the sentence stops changing; it stays while the pointer is over it.",

        // 设置：语言
        "母语": "Native language",
        "我的水平": "My level",
        "%@（%@）": "%@ (%@)",
        "入门": "Beginner",
        "初级": "Elementary",
        "中级": "Intermediate",
        "中高级": "Upper intermediate",
        "高级": "Advanced",
        "精通": "Proficient",
        "写母语时，翻译成在学的语言；写在学的语言时，纠错润色。\n我的水平：只标比你水平高、值得学的生词。":
            "Write in your native language to get a translation; write in the language you're learning to get it polished.\nMy level: only words above your level are highlighted.",
        "中文": "Chinese",
        "英语": "English",
        "日语": "Japanese",
        "韩语": "Korean",
        "西班牙语": "Spanish",
        "法语": "French",
        "德语": "German",

        // 设置：模型
        "使用": "Use",
        "使用中": "In use",
        "添加模型…": "Add Model…",
        "编辑…": "Edit…",
        "删除…": "Delete…",
        "删除": "Delete",
        "删除「%@」？": "Delete \"%@\"?",
        "会从配置里移除这个模型和它的 API Key。": "This removes the model and its API key from the configuration.",
        "添加模型": "Add Model",
        "编辑「%@」": "Edit \"%@\"",
        "名称": "Name",
        "显示在菜单里，比如 DeepSeek": "Shown in the menu, e.g. DeepSeek",
        "接口地址": "Base URL",
        "模型名": "Model",
        "比如 deepseek-flash": "e.g. deepseek-flash",
        "支持 OpenAI 兼容接口（DeepSeek、智谱、通义、Kimi、OpenAI 等），接口地址填到 /v1 这一级即可。":
            "Works with any OpenAI-compatible API (DeepSeek, Zhipu, Qwen, Kimi, OpenAI…). Enter the base URL up to /v1.",
        "额外参数": "Extra parameters",
        "可选": "Optional",
        "常用来关掉模型的「思考」，让翻译更快：": "Mostly used to turn off the model's \"thinking\" for faster translations:",
        "智谱": "Zhipu",
        "取消": "Cancel",
        "添加": "Add",
        "保存": "Save",
        "名称不能为空": "Name can't be empty",
        "接口地址要以 http:// 或 https:// 开头": "The base URL must start with http:// or https://",
        "模型名不能为空": "Model can't be empty",
        "额外参数要是 JSON 对象，或者留空": "Extra parameters must be a JSON object, or left empty",

        // 设置：朗读
        "按快捷键朗读": "With shortcut",
        "译文出来后自动朗读": "When the translation appears",
        "声音": "Voice",
        "自动（音质最好的）": "Automatic (best quality)",
        "增强": "Enhanced",
        "高级音质": "Premium",
        "语速": "Speed",
        "试听": "Preview",
        "用系统自带的语音，离线、免费。\n想要更自然的声音，可以在系统设置 → 辅助功能 → 朗读内容里下载「增强」或「高级」语音。":
            "Uses the voices built into macOS — offline and free.\nFor more natural voices, download Enhanced or Premium voices in System Settings → Accessibility → Spoken Content.",

        // 设置：快捷键
        "把这句换成译文": "Replace sentence with translation",
        "朗读译文": "Read translation aloud",
        "收起浮窗": "Hide bubble",
        "按下新快捷键…": "Press shortcut…",
        "未设置": "Not set",
        "和朗读快捷键重复了": "Already used for Read aloud",
        "和替换快捷键重复了": "Already used for Replace",
        "点一下按钮，再按下新的组合键（至少带一个 ⌃ ⌥ ⇧ ⌘），按 Esc 取消。\n朗读设为「关闭」时，朗读快捷键不生效。":
            "Click a button, then press the new combination (with at least one of ⌃ ⌥ ⇧ ⌘). Press Esc to cancel.\nThe read-aloud shortcut does nothing while Read aloud is off.",

        // 设置：外观
        "流光配色": "Glow colors",
        "预览": "Preview",
        "极光": "Aurora",
        "冷蓝": "Ocean",
        "日落": "Sunset",
        "单色": "Mono",
        "等待翻译时边框的流光、跳动小点和重新翻译时的扫光都用这组颜色。":
            "Used for the glowing border and dots while translating, and the shimmer when re-translating.",

        // 欢迎引导
        "你好": "Hello",
        "配置好模型后，这里会出现真实的译文。": "Connect a model and real translations will appear here.",
        "授权": "Access",
        "试一下": "Try it",
        "写在行与行之间的翻译": "Translations between the lines",
        "开始设置": "Get Started",
        "以后再说": "Not now",
        "允许读取输入框": "Let Gloss read what you type",
        "字里行间要看到你正在写的那句话，才能翻译；按快捷键替换时，也要能改写它。这需要 macOS 的辅助功能权限。密码框永远不会读取。": "Gloss needs to see the sentence you are writing to translate it, and to rewrite it when you press the replace shortcut. macOS calls this Accessibility access. Password fields are never read.",
        "1. 点下面的按钮，打开系统设置": "1. Click the button below to open System Settings",
        "2. 在列表里找到「字里行间」": "2. Find Gloss in the list",
        "3. 打开右边的开关": "3. Turn on the switch next to it",
        "上一步": "Back",
        "继续": "Continue",
        "打开系统设置": "Open System Settings",
        "已授权，可以继续了": "Access granted — you’re all set",
        "正在等待你打开开关…": "Waiting for you to turn it on…",
        "还没有授权": "Not allowed yet",
        "隐私与安全性 › 辅助功能": "Privacy & Security › Accessibility",
        "终端": "Terminal",
        "接上一个模型": "Connect a model",
        "翻译由你自己的模型服务完成，句子只发给它。用 DeepSeek 只要粘贴 API Key；别家选「自定义」。": "Translations come from your own model service, and your sentences only go there. For DeepSeek, just paste an API key; for anything else, choose Custom.",
        "快、便宜，只需 API Key": "Fast and cheap — only needs a key",
        "自定义": "Custom",
        "任意 OpenAI 兼容接口": "Any OpenAI-compatible API",
        "名称，显示在菜单里": "Name, shown in the menu",
        "接口地址，如 https://api.example.com/v1": "Base URL, e.g. https://api.example.com/v1",
        "粘贴 API Key": "Paste your API key",
        "测试中": "Testing",
        "测试连接": "Test",
        "跳过，稍后在设置里配置": "Skip — set it up later in Settings",
        "连接正常 · 一句话大约 %@ 秒": "Connected · about %@ s per sentence",
        "你在学哪门语言？": "Which language are you learning?",
        "写母语时翻译成它；直接用它写时，帮你改得更地道。": "Write in your own language to see it translated; write in the one you’re learning to get it polished.",
        "我平时写": "I write in",
        "我在学": "I’m learning",
        "只会标出比这个水平高、值得学的词。": "Only words above this level are highlighted.",
        "写一句试试": "Give it a try",
        "停顿一下，译文就会出现在光标下面。点一句示例看看效果。": "Pause for a moment and the translation appears right below your cursor. Pick an example to see it in action.",
        "在这里写点什么…": "Write something here…",
        "开始使用": "Start Using Gloss",
        "按 ⌃⌥E 可以把这句换成译文": "Press ⌃⌥E to replace your sentence",
        "停顿 0.6 秒后开始翻译": "Translates after a 0.6 s pause",
        "欢迎引导": "Welcome guide",
        "重新打开…": "Show Again…",
        "字里行间在这里 ↑": "Gloss lives up here ↑",
        "在任何输入框里写字就会出现，点图标可以改设置。": "It appears whenever you type. Click the icon for settings.",
        // 翻译范围
        "翻译范围": "Translate",
        "句子": "Sentence",
        "段落": "Paragraph",
        "整段翻译中，稍慢一些": "Translating the whole paragraph — this takes a bit longer",
        "翻译范围：句子模式只翻光标所在的一句，很长的句子只翻光标附近的两小段；段落模式整段一起翻，上下文更完整，但更慢、也更费 token。": "Translate: Sentence mode translates only the sentence at your cursor (for very long sentences, just the two clauses near it). Paragraph mode translates the whole paragraph — more context, but slower and uses more tokens.",
        // 发送后的译文卡
        "已发送": "Sent",
        "上一句 · 已发送": "Previous · Sent",
        // 生词本
        "生词本（%@）…": "Vocabulary (%@)…",
        "生词 · 点击朗读 · 点 ✓ 标为已掌握": "New word · Click to hear · Click ✓ to mark as learned",
        "点击朗读 · 点 ✓ 标为已掌握": "Click to hear · Click ✓ to mark as learned",
        "标为已掌握": "Mark as learned",
        "移回学习中": "Move back to Learning",
        "生词本": "Vocabulary",
        "生词本 · %@": "Vocabulary · %@",
        "学习中（%@）": "Learning (%@)",
        "已掌握（%@）": "Learned (%@)",
        "搜索": "Search",
        "导出到 Anki…": "Export to Anki…",
        "还没有掌握的词": "No learned words yet",
        "还没有生词": "No words yet",
        "没有匹配的词": "No matching words",
        "已掌握的词不再在浮窗里出现。用外语自己写出来的词会自动算掌握。": "Learned words no longer appear in the popup. Words you write yourself in the language you're learning count as learned automatically.",
        "生词在浮窗里出现、没点它朗读，就算记得一次，隔 1、3、7、15、30 天再提示，隔完自动算掌握；点了朗读会从头再来。": "Each time a word shows up in the popup and you don't click to hear it, it counts as remembered and comes back after 1, 3, 7, 15 and 30 days, then counts as learned. Clicking to hear it starts it over.",
        "另有 %@ 个词不高于你的水平（%@），不再提示。": "%@ more words are at or below your level (%@) and are no longer shown.",
        "见过 %@ 次": "Seen %@×",
        "下次遇到就提示": "Shown next time it comes up",
        "%@ 天后再提示": "Shown again in %@ days",
    ]
}

func tr(_ key: String) -> String {
    L10n.lookup(key)
}

func tr(_ key: String, _ args: String...) -> String {
    String(format: L10n.lookup(key), arguments: args.map { $0 as CVarArg })
}
