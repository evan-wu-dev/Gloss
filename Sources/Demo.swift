import AppKit

/// 调样式、做 README 素材用，不读输入框、不请求模型。
///
/// `--demo <阶段> [配色] [--light]`：在屏幕左上固定位置单独摆一个浮窗，阶段是 waiting / streaming / refreshing / done / polish。
/// `--demo <场景> [配色] [--lang en]`：摆一个假的输入框当舞台，浮窗出现在它的光标下面。场景：
///   hero    打字 → 等待 → 逐字出译文 → ⌃⌥E 替换，循环播放（录 GIF 用）
///   toolbar 译文出来、鼠标停在上面时的工具栏
///   polish  写外语时的润色对比
///   sent    回车发送后留下的「已发送」卡片
/// `--demo settings <页序号>` / `--demo welcome <步骤序号>` / `--demo vocab`：用示例数据打开设置窗口、欢迎引导、生词本，
/// 不读也不写 config.json 和生词本。
/// 舞台启动后在标准输出打一行 `STAGE x y 宽 高 循环秒数`（主屏左上原点的点坐标），录屏脚本按它裁剪；hero 每轮开头再打一行 `LOOP 开机秒数`。
final class DemoDelegate: NSObject, NSApplicationDelegate {
    static let scenes = ["hero", "toolbar", "polish", "sent"]

    private let overlay = OverlayController()
    private let phase: String
    private var timer: Timer?
    private var backdrop: NSWindow?
    private var stage: DemoStage?
    private var window: NSWindowController?
    private let script = DemoScript.current

    init(phase: String, palette: Palette) {
        self.phase = phase
        super.init()
        overlay.palette = palette
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let detail = CommandLine.arguments.drop { $0 != phase }.dropFirst().first.flatMap { Int($0) } ?? 0
        if phase == "settings" { return showSettings(tab: detail) }
        if phase == "welcome" { return showWelcome(step: detail) }
        if phase == "vocab" { return showVocab() }
        if Self.scenes.contains(phase) {
            // 截图统一用浅色，跟系统外观无关。
            NSApp.appearance = NSAppearance(named: .aqua)
            let stage = DemoStage()
            self.stage = stage
            stage.window.orderFrontRegardless()
            let frame = stage.axFrame
            print("STAGE \(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height)) \(phase == "hero" ? heroDuration : 0)")
            fflush(stdout)
            playScene()
            return
        }
        showPhase()
    }

    // MARK: - 舞台场景

    private var heroDuration: Double {
        0.8 + Double(script.source.count) * script.typingInterval + 0.6 + 1.1 + Double(chunks.count) * 0.14 + 2.0 + 0.8 + 2.4
    }

    /// 模拟模型的流：每次到两三个词（中文按字数切）。
    private var chunks: [String] {
        let words = script.translation.split(separator: " ").map(String.init)
        return stride(from: 2, through: words.count + 1, by: 2).map { words.prefix(min($0, words.count)).joined(separator: " ") }
    }

    private func playScene() {
        guard let stage else { return }
        switch phase {
        case "hero":
            playHero()
        case "toolbar":
            stage.setText(script.source)
            overlay.show(OverlayContent(phase: .done, translation: script.translation, words: script.words), caret: stage.caretRect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.overlay.pinHover = true }
        case "polish":
            stage.setText(script.polishSource)
            overlay.show(OverlayContent(phase: .done, translation: script.polished,
                                        diff: Diff.compare(script.polishSource, script.polished), badge: tr("润色"),
                                        note: script.polishNote, words: script.polishWords), caret: stage.caretRect)
        default:
            // 发出去以后输入框清空了，卡片留在原来那句的位置。
            stage.setText(script.source)
            let caret = stage.caretRect
            stage.setText("")
            var content = OverlayContent(phase: .done, translation: script.translation, words: script.words)
            content.tag = tr("已发送")
            overlay.show(content, caret: caret)
        }
    }

    private func playHero() {
        guard let stage else { return }
        // 每轮开头报一次时间，录屏脚本按它切出完整的一轮（asyncAfter 一步步累积会有点漂，不能只靠算）。
        print("LOOP \(ProcessInfo.processInfo.systemUptime)")
        fflush(stdout)
        var steps: [(delay: Double, action: () -> Void)] = []
        steps.append((0.8, {}))
        let characters = Array(script.source)
        for index in characters.indices {
            steps.append((script.typingInterval, { stage.setText(String(characters[...index])) }))
        }
        // 停顿后开始翻译：先是等待的跳点，再一截一截地到。
        steps.append((0.6, { self.overlay.show(OverlayContent(phase: .waiting), caret: stage.caretRect) }))
        steps.append((1.1, {}))
        for chunk in chunks.dropLast() {
            steps.append((0.14, { self.overlay.show(OverlayContent(phase: .streaming, translation: chunk), caret: stage.caretRect) }))
        }
        steps.append((0.14, {
            self.overlay.show(OverlayContent(phase: .done, translation: self.script.translation, words: self.script.words), caret: stage.caretRect)
        }))
        steps.append((2.0, { stage.showKeys(true) }))
        steps.append((0.8, {
            stage.setText(self.script.translation)
            self.overlay.hide()
        }))
        steps.append((0.6, { stage.showKeys(false) }))
        steps.append((1.8, {
            stage.setText("")
        }))
        run(steps[...])
    }

    private func run(_ steps: ArraySlice<(delay: Double, action: () -> Void)>) {
        guard let step = steps.first else {
            playHero()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
            step.action()
            self.run(steps.dropFirst())
        }
    }

    // MARK: - 设置窗口、欢迎引导

    private func showSettings(tab: Int) {
        let model = SettingsModel()
        model.native = L10n.current == "zh" ? "zh" : "en"
        model.learning = L10n.current == "zh" ? "en" : "es"
        model.providers = [
            .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "", extraBody: ""),
            .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "kimi-k2", apiKey: "", extraBody: ""),
            .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini", apiKey: "", extraBody: ""),
        ]
        model.providerID = "deepseek"
        model.replaceHotkey = "ctrl+option+e"
        model.speakHotkey = "ctrl+option+s"
        let controller = SettingsWindowController(model: model)
        (controller.window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = tab
        window = controller
        controller.present()
    }

    private func showVocab() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-demo-vocab.json")
        try? FileManager.default.removeItem(at: url)
        let store = VocabStore(url: url, learnerLevel: "B1")
        let samples = [("requirements review", "需求评审", "B2", "Let's do the requirements review tomorrow.", "明天做需求评审吧。"),
                       ("attrition", "人员流失", "C1", "Attrition has been low this year.", "今年人员流失不高。"),
                       ("at a glance", "一眼看出", "B2", "You can see the status at a glance.", "一眼就能看到状态。")]
        for (word, gloss, level, example, source) in samples {
            store.record([LearnWord(word: word, gloss: gloss, level: level)], example: example, exampleZh: source, written: nil)
        }
        store.record([LearnWord(word: "download", gloss: "下载", level: "B1")], example: "", exampleZh: "", written: nil)
        store.relearn("attrition")
        let model = VocabListModel()
        model.load(store, language: Language.named("en") ?? Language.all[1])
        let controller = VocabWindowController(model: model)
        window = controller
        controller.present()
    }

    private func showWelcome(step: Int) {
        let model = OnboardingModel()
        let controller = OnboardingWindowController(model: model)
        window = controller
        controller.present(firstRun: false)
        model.step = OnboardingModel.Step(rawValue: step) ?? .intro
        // 毛玻璃要透出后面的东西：垫一块深色渐变，截图时连它一起截（不然会透出桌面上别的窗口）。
        guard let glass = controller.window else { return }
        glass.level = .floating
        let frame = glass.frame.insetBy(dx: -56, dy: -48)
        let backdrop = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.level = .floating
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.colors = [NSColor(srgbRed: 0.10, green: 0.16, blue: 0.32, alpha: 1).cgColor,
                           NSColor(srgbRed: 0.30, green: 0.18, blue: 0.40, alpha: 1).cgColor,
                           NSColor(srgbRed: 0.10, green: 0.30, blue: 0.36, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        root.layer?.addSublayer(gradient)
        backdrop.contentView = root
        backdrop.order(.below, relativeTo: glass.windowNumber)
        self.backdrop = backdrop
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        print("STAGE \(Int(frame.minX)) \(Int(primaryHeight - frame.maxY)) \(Int(frame.width)) \(Int(frame.height)) 0")
        fflush(stdout)
    }

    // MARK: - 单独的浮窗

    private func showPhase() {
        let caret = CGRect(x: 200, y: 200, width: 2, height: 18)
        if CommandLine.arguments.contains("--light") {
            // 垫一块白底，看浅色背景上的光晕。
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let backdrop = NSWindow(contentRect: NSRect(x: 120, y: primaryHeight - 420, width: 700, height: 300),
                                    styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.backgroundColor = .white
            backdrop.level = .floating
            backdrop.orderFrontRegardless()
            self.backdrop = backdrop
        }
        let text = script.translation
        let words = script.words
        switch phase {
        case "waiting":
            overlay.show(OverlayContent(phase: .waiting), caret: caret)
        case "refreshing":
            overlay.show(OverlayContent(phase: .refreshing, translation: text, words: words), caret: caret)
        case "streaming":
            // 模拟模型的流：等 0.8 秒，之后每 0.2 秒到一截（几个词），到齐后出生词，停 2.5 秒再来一遍。
            let parts = text.split(separator: " ").map(String.init)
            var tickCount = 0
            overlay.show(OverlayContent(phase: .waiting), caret: caret)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                tickCount = (tickCount + 1) % 26
                let arrived = min(max(tickCount - 4, 0) * 3, parts.count)
                if tickCount == 0 {
                    self.overlay.hide()
                } else if tickCount < 4 {
                    self.overlay.show(OverlayContent(phase: .waiting), caret: caret)
                } else if arrived < parts.count {
                    self.overlay.show(OverlayContent(phase: .streaming, translation: parts.prefix(arrived).joined(separator: " ")), caret: caret)
                } else {
                    self.overlay.show(OverlayContent(phase: .done, translation: text, words: words), caret: caret)
                }
            }
        case "polish":
            overlay.show(OverlayContent(phase: .done, translation: script.polished, diff: Diff.compare(script.polishSource, script.polished),
                                        badge: tr("润色"), note: script.polishNote, words: script.polishWords), caret: caret)
        default:
            overlay.show(OverlayContent(phase: .done, translation: text, words: words), caret: caret)
        }
    }
}

/// 演示用的例句。中文界面演示「中文 → 英语」；其他界面语言演示「英语 → 西班牙语」，顺便看出不只支持中英。
struct DemoScript {
    var source: String
    var translation: String
    var words: [OverlayWord]
    var polishSource: String
    var polished: String
    var polishNote: String
    var polishWords: [OverlayWord]
    var typingInterval: Double

    static var current: DemoScript { L10n.current == "zh" ? chinese : english }

    static let chinese = DemoScript(
        source: "这周的需求评审改到周四下午吧，大家提前看下文档。",
        translation: "Let's move this week's requirements review to Thursday afternoon. Please read through the doc beforehand.",
        words: [OverlayWord(word: "requirements review", gloss: "需求评审", level: "B2", isNew: true),
                OverlayWord(word: "read through", gloss: "通读", level: "B1", isNew: false)],
        polishSource: "I am very interesting in join your team.",
        polished: "I am very interested in joining your team.",
        polishNote: "表示「感兴趣」用 interested；介词 in 后面要用动名词 joining。",
        polishWords: [OverlayWord(word: "interested in", gloss: "对…感兴趣", level: "A2", isNew: true)],
        typingInterval: 0.09)

    static let english = DemoScript(
        source: "Can we push the review to Thursday afternoon?",
        translation: "¿Podemos pasar la revisión al jueves por la tarde?",
        words: [OverlayWord(word: "pasar … a", gloss: "move to", level: "B1", isNew: true),
                OverlayWord(word: "por la tarde", gloss: "in the afternoon", level: "A2", isNew: false)],
        polishSource: "Estoy muy interesado en unir a su equipo de diseño.",
        polished: "Estoy muy interesado en unirme a su equipo de diseño.",
        polishNote: "“Unirse” is reflexive here: say “unirme a”, not “unir a”.",
        polishWords: [OverlayWord(word: "unirse a", gloss: "to join", level: "B1", isNew: true)],
        typingInterval: 0.06)
}

/// 假的聊天输入框：浅色渐变底上一张白卡片，左上三个窗口按钮，里面是正在打的字和一根光标。
final class DemoStage {
    let window: NSWindow
    private let textView = NSTextView()
    private let caret = NSView()
    private let keys = NSView()
    private var blink: Timer?
    private var typedAt = Date.distantPast

    private static let size = NSSize(width: 960, height: 290)
    private static let topLeft = NSPoint(x: 60, y: 90)

    init() {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: Self.topLeft.x, y: primaryHeight - Self.topLeft.y - Self.size.height,
                           width: Self.size.width, height: Self.size.height)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isOpaque = true

        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        let background = CAGradientLayer()
        background.frame = root.bounds
        background.colors = [NSColor(srgbRed: 0.91, green: 0.93, blue: 0.97, alpha: 1).cgColor,
                             NSColor(srgbRed: 0.96, green: 0.93, blue: 0.95, alpha: 1).cgColor]
        background.startPoint = CGPoint(x: 0, y: 1)
        background.endPoint = CGPoint(x: 1, y: 0)
        root.layer?.addSublayer(background)
        window.contentView = root

        let card = NSView(frame: NSRect(x: 40, y: Self.size.height - 40 - 128, width: Self.size.width - 80, height: 128))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor(white: 0, alpha: 0.08).cgColor
        card.shadow = NSShadow()
        card.layer?.shadowColor = NSColor(white: 0, alpha: 1).cgColor
        card.layer?.shadowOpacity = 0.08
        card.layer?.shadowRadius = 16
        card.layer?.shadowOffset = CGSize(width: 0, height: -4)
        root.addSubview(card)

        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let dot = NSView(frame: NSRect(x: 16 + CGFloat(index) * 20, y: card.frame.height - 24, width: 12, height: 12))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
            dot.layer?.cornerRadius = 6
            card.addSubview(dot)
        }

        textView.frame = NSRect(x: 18, y: 14, width: card.frame.width - 36, height: card.frame.height - 52)
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 17)
        textView.textColor = NSColor(white: 0.12, alpha: 1)
        textView.textContainerInset = .zero
        card.addSubview(textView)

        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        caret.layer?.cornerRadius = 1
        card.addSubview(caret)

        let label = NSTextField(labelWithString: "⌃ ⌥ E   " + tr("替换原句"))
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        keys.frame = NSRect(x: Self.size.width - 40 - label.frame.width - 32, y: 32,
                            width: label.frame.width + 32, height: label.frame.height + 16)
        label.frame.origin = NSPoint(x: 16, y: 8)
        keys.addSubview(label)
        keys.wantsLayer = true
        keys.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.82).cgColor
        keys.layer?.cornerRadius = keys.frame.height / 2
        keys.alphaValue = 0
        root.addSubview(keys)

        setText("")
        // 打字时光标常亮，停下来才闪。
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caret.isHidden = Date().timeIntervalSince(self.typedAt) > 0.6 ? !self.caret.isHidden : false
        }
    }

    /// 舞台在屏幕上的位置，主屏左上原点。
    var axFrame: CGRect { CGRect(origin: Self.topLeft, size: Self.size) }

    func setText(_ text: String) {
        textView.string = text
        typedAt = Date()
        caret.isHidden = false
        let local = caretLocalRect
        caret.frame = NSRect(x: local.minX, y: local.minY, width: 2, height: local.height)
    }

    /// 光标在屏幕上的位置（AX 坐标，主屏左上原点），浮窗按它摆。
    var caretRect: CGRect {
        let local = caretLocalRect
        guard let card = caret.superview else { return .zero }
        let screen = window.convertToScreen(card.convert(local, to: nil))
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: screen.minX, y: primaryHeight - screen.maxY, width: 2, height: screen.height)
    }

    func showKeys(_ show: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            keys.animator().alphaValue = show ? 1 : 0
        }
    }

    /// 最后一个字后面的位置，在卡片坐标系里。
    private var caretLocalRect: NSRect {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 17))
        var rect: NSRect
        if textView.string.isEmpty {
            rect = NSRect(x: 0, y: 0, width: 0, height: lineHeight)
        } else {
            let glyphs = layout.glyphRange(for: container)
            let last = NSRange(location: glyphs.upperBound - 1, length: 1)
            let glyph = layout.boundingRect(forGlyphRange: last, in: container)
            let line = layout.lineFragmentRect(forGlyphAt: last.location, effectiveRange: nil)
            rect = NSRect(x: glyph.maxX + 1, y: line.minY, width: 0, height: line.height)
        }
        // NSTextView 是翻转坐标系，换到卡片里。
        let inCard = textView.convert(rect, to: textView.superview)
        return NSRect(x: inCard.minX, y: inCard.minY + 2, width: 2, height: inCard.height - 4)
    }
}
