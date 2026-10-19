import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let client = LLMClient()
    private var vocab = VocabStore(url: VocabStore.url(for: Language.all[1]))

    private var config: AppConfig?
    private var configError: String?
    private var hotKey: HotKey?
    private var speakHotKey: HotKey?
    private let speaker = Speaker()
    private let settingsModel = SettingsModel()
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var lastSpoken: String?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true

    /// 句子 → 译文；同一句不重复请求。
    private var cache: [String: TranslationResult] = [:]
    /// 流式请求进行中、已经生成出来的那截译文。
    private var partials: [String: String] = [:]
    private var errors: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var requestedAt: [String: Date] = [:]
    private var pendingText: String?
    private var changedAt = Date()
    private var lastShown: (text: String, result: TranslationResult)?
    /// 按 Esc / 回车发送后收起的句子；内容变了才再出来。
    private var dismissedText: String?
    /// 按了替换键但译文还没回来的句子，回来后直接替换。
    private var replaceTarget: String?
    /// 最近翻好、还没记进生词本的句子。这句写完（换到别的句子、发出去清空、被替换）才记一次，
    /// 免得半句话每停顿一次就多算一次「见过」。
    private var uncommitted: (text: String, result: TranslationResult)?
    /// 按了朗读键但译文还没回来的句子。
    private var speakTarget: String?
    /// 回车发出去的那句：发送后留一张译文卡。下一句的译文出来、显示满 5 秒（鼠标停在上面时不算）、
    /// 切到别的应用或按 Esc 时收起。caret 是发送时光标的位置，输入框清空后卡片还留在原处。
    private var sent: (text: String, mode: TranslateMode, caret: CGRect, pid: pid_t, shownAt: Date?)?
    private var lastTarget: (mode: TranslateMode, caret: CGRect, pid: pid_t)?

    /// 调试：记下每次读到的输入框原文和光标，排查「只翻了半句」这类读取问题。
    /// `defaults write local.wufan.live-translate debugAX -bool YES` 打开，日志在配置目录的 debug-ax.log。
    private let debugAX = UserDefaults.standard.bool(forKey: "debugAX")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 首次启动放到最右侧（控制中心旁），菜单栏挤满时不至于被挤到刘海后面。
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position LiveTranslate": 0])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 沿用改名前的名字，菜单栏位置不丢。
        statusItem.autosaveName = "LiveTranslate"
        statusItem.button?.image = StatusIcon.image
        statusItem.button?.appearsDisabled = !enabled
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        overlay.onToggleKnown = { [weak self] word in self?.vocab.toggleKnown(word) }
        overlay.onSpeakWord = { [weak self] word in self?.speaker.speak(word) }
        overlay.onSpeak = { [weak self] in self?.speakCurrent() }
        overlay.onReplace = { [weak self] in self?.replaceCurrent() }
        settingsModel.write = { [weak self] changes in
            self?.updateConfig(changes)
            return self?.configError
        }
        settingsModel.writeProvider = { [weak self] id, changes in
            do {
                try ConfigStore.setProvider(id, changes)
            } catch {
                return error.localizedDescription
            }
            return self?.reloadAfterProviderChange()
        }
        settingsModel.removeProvider = { [weak self] id in
            do {
                try ConfigStore.removeProvider(id)
            } catch {
                return error.localizedDescription
            }
            return self?.reloadAfterProviderChange()
        }
        settingsModel.setEnabled = { [weak self] on in self?.setEnabled(on) }
        settingsModel.preview = { [weak self] text in self?.speaker.speak(text) }
        settingsModel.showOnboarding = { [weak self] in self?.showOnboarding() }
        reloadConfig()
        // 第一次打开走欢迎引导（里面会请求辅助功能权限）；之后只在没授权时弹系统提示。
        if UserDefaults.standard.bool(forKey: "onboardingDone") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else {
            showOnboarding()
        }

        // Esc 收起；回车（不带 ⇧ / ⌥，即发送）也收起。需要辅助功能权限才收得到别的应用的按键。
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let isSend = [36, 76].contains(event.keyCode) && event.modifierFlags.intersection([.shift, .option]).isEmpty
            if isEscape || isSend { self?.dismiss(sending: isSend) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - 欢迎引导

    private func showOnboarding() {
        let firstRun = !UserDefaults.standard.bool(forKey: "onboardingDone")
        if let onboarding, onboarding.window?.isVisible == true {
            onboarding.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = OnboardingModel()
        model.currentConfig = { [weak self] in self?.config }
        model.save = { [weak self] changes in self?.updateConfig(changes) }
        model.saveProvider = { [weak self] id, changes in
            try? ConfigStore.setProvider(id, changes)
            self?.updateConfig(["activeProvider": id])
        }
        model.setUILanguage = { [weak self] code in self?.updateConfig(["uiLanguage": code]) }
        model.finish = { [weak self] in self?.finishOnboarding() }
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboardingDone")
            self?.onboarding = nil
        }
        onboarding = controller
        controller.present(firstRun: firstRun)
    }

    /// 窗口飞进菜单栏图标，再在图标下面冒一句「我在这里」。
    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        guard let controller = onboarding else { return }
        let target = statusItem.button.flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        controller.flyAway(to: target) { [weak self] in
            controller.close()
            guard let self else { return }
            // 结束这一刻固定用极光炫彩，不跟设置里的配色（选了单色时整条就只剩蓝色）。
            if let button = self.statusItem.button { StatusIcon.celebrate(button, palette: .aurora) }
            self.pointAtStatusItem()
        }
    }

    private func pointAtStatusItem() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        StatusHint.show(below: anchor, title: tr("字里行间在这里 ↑"), detail: tr("在任何输入框里写字就会出现，点图标可以改设置。"))
    }

    /// 菜单栏图标被挤得看不到时，再打开一次 App（Spotlight / 双击）就打开设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: - 主循环

    /// 当前句子要做什么：写母语 → 翻译；写在学的语言 → 润色；别的语言或判不出来 → 不管。
    private func mode(for text: String) -> TranslateMode? {
        guard let config else { return nil }
        // 只看网址、邮箱、路径以外的文字；只剩网址（比如在浏览器地址栏里）就不翻。
        switch LanguageDetector.detect(Sentence.withoutLinks(text), among: [config.nativeLanguage, config.learningLanguage]) {
        case config.nativeLanguage: return .translate
        case config.learningLanguage: return config.checkLearning ? .polish : nil
        default: return nil
        }
    }

    private func currentTarget() -> (snap: FocusSnapshot, mode: TranslateMode)? {
        guard AXIsProcessTrusted(), let snap = AX.snapshot(),
              let mode = mode(for: snap.sentence.text) else { return nil }
        return (snap, mode)
    }

    private func tick() {
        guard enabled, let (snap, mode) = currentTarget(), let caret = AX.caretRect(snap) else {
            commitVocab()
            // 输入框清空了：「这句已发送」的记忆跟着清掉，不然以后再打同一句（「好的」「嗯」）就永远不弹了。
            dismissedText = nil
            if !showSentCard(typingNext: false) { overlay.hide() }
            return
        }
        lastTarget = (mode, caret, snap.pid)
        let text = snap.sentence.text
        if text != pendingText {
            pendingText = text
            changedAt = Date()
            if text != dismissedText { dismissedText = nil }
            if debugAX { logSnapshot(snap) }
            if let pending = uncommitted, !text.hasPrefix(pending.text), !pending.text.hasPrefix(text) { commitVocab() }
        }
        if usesPinyin, Sentence.isComposing(snap.text, cursor: snap.cursor) {
            changedAt = Date()
        }
        // 句子停着不动超过 autoHideSeconds 就收起：有些应用（Electron 终端等）清空输入后 AX 里还留着旧文本。
        // 鼠标停在浮窗上时不收，免得正要点生词或按钮时消失。
        let autoHide = config?.autoHideSeconds ?? 15
        let idle = autoHide > 0 && Date().timeIntervalSince(changedAt) > autoHide && !overlay.isHovering
        if text == dismissedText || idle {
            if !showSentCard(typingNext: false) { overlay.hide() }
            return
        }
        // 接着打下一句：它的译文出来前，先留着刚发出那句的译文（变淡），译文一到就换过去。
        if sent != nil, cache[text] == nil, partials[text] == nil, showSentCard(typingNext: true) {
            if Date().timeIntervalSince(changedAt) * 1000 >= Double(config?.debounceMs ?? 600) { request(text, mode: mode) }
            return
        }
        sent = nil

        if let message = configError {
            overlay.show(OverlayContent(phase: .message, translation: message), caret: caret)
            return
        }
        if let result = cache[text] {
            render(text, result, mode: mode, caret: caret, phase: .done)
            autoSpeak(text, result)
            return
        }
        if let message = errors[text] {
            overlay.show(OverlayContent(phase: .message, translation: message), caret: caret)
            return
        }
        if Date().timeIntervalSince(changedAt) * 1000 >= Double(config?.debounceMs ?? 600) {
            request(text, mode: mode)
        }
        let loading = inFlight.contains(text)
        if let partial = partials[text] {
            overlay.show(OverlayContent(phase: .streaming, translation: partial, badge: badge(mode)), caret: caret)
        } else if let last = lastShown, overlay.isVisible, text.prefix(2) == last.text.prefix(2) {
            // 还在打同一句时留着上一版译文：停顿前变淡，请求发出后扫光；换了一句就先不显示。
            render(last.text, last.result, mode: mode, caret: caret, phase: loading ? .refreshing : .stale)
        } else if loading {
            // 段落模式整段翻，等了 2 秒还没回来就说一声，免得以为卡住了。
            let slow = Sentence.scope == .paragraph && Date().timeIntervalSince(requestedAt[text] ?? Date()) > 2
            overlay.show(OverlayContent(phase: .waiting, hint: slow ? tr("整段翻译中，稍慢一些") : nil), caret: caret)
        } else {
            overlay.hide()
        }
    }

    private func logSnapshot(_ snap: FocusSnapshot) {
        let app = NSRunningApplication(processIdentifier: snap.pid)?.bundleIdentifier ?? "\(snap.pid)"
        let line = "\(Date()) app=\(app) len=\((snap.text as NSString).length) cursor=\(snap.cursor) "
            + "sentence=\(snap.sentence.text.debugDescription) tail=\(String(snap.text.suffix(160)).debugDescription)\n"
        let url = ConfigStore.directory.appendingPathComponent("debug-ax.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 母语或在学的语言是中文时才会有拼音组字。
    private var usesPinyin: Bool {
        guard let config else { return false }
        return config.nativeLanguage.code == "zh" || config.learningLanguage.code == "zh"
    }

    private func badge(_ mode: TranslateMode) -> String? {
        mode == .polish ? tr("润色") : nil
    }

    /// Esc：全部收起。回车发送：不收起，原地留一张这句的译文卡；译文还没回来就马上请求，不再等停顿。
    private func dismiss(sending: Bool = false) {
        guard enabled, overlay.isVisible || pendingText != nil else { return }
        let text = pendingText
        dismissedText = text
        commitVocab()
        guard sending, let text, text != sent?.text, let target = lastTarget else {
            sent = nil
            overlay.hide()
            return
        }
        sent = (text, target.mode, target.caret, target.pid, nil)
        if cache[text] == nil { request(text, mode: target.mode) }
        showSentCard(typingNext: false)
    }

    private func commitVocab() {
        guard let pending = uncommitted else { return }
        uncommitted = nil
        vocab.record(pending.result.words, example: pending.result.translation, exampleZh: pending.text)
    }

    /// 自动朗读：译文出来就念，同一句只念一次；接着改这句、出了新译文会再念新的。
    private func autoSpeak(_ text: String, _ result: TranslationResult) {
        guard config?.speakMode == "auto", text != lastSpoken else { return }
        lastSpoken = text
        speaker.speak(result.translation)
    }

    private func render(_ text: String, _ result: TranslationResult, mode: TranslateMode, caret: CGRect, phase: OverlayPhase) {
        lastShown = (text, result)
        overlay.show(content(text, result, mode: mode, phase: phase), caret: caret)
    }

    private func content(_ text: String, _ result: TranslationResult, mode: TranslateMode, phase: OverlayPhase) -> OverlayContent {
        var content = OverlayContent(phase: phase, translation: result.translation, badge: badge(mode), note: result.note)
        content.words = result.words
            .filter { !vocab.isKnown($0.word) }
            .map { OverlayWord(word: $0.word, gloss: $0.gloss, level: $0.level, isNew: vocab.isNew($0.word)) }
        if mode == .polish {
            if result.translation == text {
                content.note = content.note.isEmpty ? tr("✓ 没问题，很地道") : content.note
                content.noteIsOK = result.note.isEmpty
            } else {
                content.diff = Diff.compare(text, result.translation)
            }
        }
        return content
    }

    /// 显示「已发送」的译文卡；没有在显示的卡片时返回 false。
    @discardableResult
    private func showSentCard(typingNext: Bool) -> Bool {
        guard enabled, var card = sent else { return false }
        // 切到别的应用、或者显示满 5 秒（鼠标停在上面时不算）就收起。
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != card.pid {
            sent = nil
            return false
        }
        if overlay.isHovering, card.shownAt != nil { card.shownAt = Date() }
        if let shownAt = card.shownAt, Date().timeIntervalSince(shownAt) > 5 {
            sent = nil
            return false
        }
        var shown: OverlayContent
        if let result = cache[card.text] {
            shown = content(card.text, result, mode: card.mode, phase: typingNext ? .stale : .done)
            if card.shownAt == nil {
                card.shownAt = Date()
                speakSent(card.text, result)
            }
        } else if let partial = partials[card.text] {
            shown = OverlayContent(phase: .streaming, translation: partial, badge: badge(card.mode))
        } else if let message = errors[card.text] {
            shown = OverlayContent(phase: .message, translation: message)
        } else {
            shown = OverlayContent(phase: .waiting)
        }
        shown.tag = typingNext ? tr("上一句 · 已发送") : tr("已发送")
        sent = card
        overlay.show(shown, caret: card.caret)
        return true
    }

    /// 自动朗读模式下，发出去的那句念一遍（每句一次）。
    private func speakSent(_ text: String, _ result: TranslationResult) {
        guard config?.speakMode == "auto", text != lastSpoken else { return }
        lastSpoken = text
        speaker.speak(result.translation)
    }

    private func request(_ text: String, mode: TranslateMode) {
        guard let config, !inFlight.contains(text) else { return }
        inFlight.insert(text)
        requestedAt[text] = Date()
        client.translate(text, mode: mode, config: config, onPartial: { [weak self] partial in
            DispatchQueue.main.async {
                guard let self, self.inFlight.contains(text) else { return }
                self.partials[text] = partial
                self.tick()
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(text)
                self.partials[text] = nil
                switch result {
                case .success(let translated):
                    if self.cache.count > 300 { self.cache.removeAll() }
                    self.cache[text] = translated
                    self.uncommitted = (text, translated)
                    if self.replaceTarget == text {
                        self.replaceTarget = nil
                        self.replaceCurrent()
                    }
                    if self.speakTarget == text {
                        self.speakTarget = nil
                        self.lastSpoken = text
                        self.speaker.speak(translated.translation)
                    }
                case .failure(let error):
                    self.errors[text] = tr("翻译失败：%@", error.localizedDescription)
                    if self.replaceTarget == text { self.replaceTarget = nil }
                    if self.speakTarget == text { self.speakTarget = nil }
                }
                self.tick()
            }
        })
    }

    // MARK: - 替换与朗读

    private func replaceCurrent() {
        guard let (snap, mode) = currentTarget() else {
            NSSound.beep()
            return
        }
        let text = snap.sentence.text
        guard let result = cache[text] else {
            replaceTarget = text
            request(text, mode: mode)
            return
        }
        if AX.replace(snap, with: result.translation) {
            commitVocab()
            vocab.markUsed(result.words)
            overlay.hide()
        } else {
            NSSound.beep()
        }
    }

    private func speakCurrent() {
        guard let (snap, mode) = currentTarget() else {
            NSSound.beep()
            return
        }
        let text = snap.sentence.text
        guard let result = cache[text] else {
            speakTarget = text
            request(text, mode: mode)
            return
        }
        lastSpoken = text
        speaker.speak(result.translation)
    }

    // MARK: - 配置

    private func reloadConfig() {
        commitVocab()
        do {
            config = try ConfigStore.load()
            configError = nil
        } catch {
            config = nil
            configError = error.localizedDescription
        }
        cache.removeAll()
        partials.removeAll()
        errors.removeAll()
        lastShown = nil
        hotKey = nil
        speakHotKey = nil
        overlay.replaceShortcut = nil
        overlay.speakShortcut = nil
        guard let config else { return }
        applyLanguage(config.uiLanguage)
        Sentence.scope = config.scope
        overlay.palette = config.palette
        vocab = VocabStore(url: VocabStore.url(for: config.learningLanguage))
        hotKey = HotKey(spec: config.replaceHotkey) { [weak self] in self?.replaceCurrent() }
        if hotKey == nil { configError = tr("替换快捷键「%@」无法注册（写法不对或被占用）", config.replaceHotkey) }
        speaker.configure(language: config.learningLanguage, voiceID: config.speakVoice, rate: config.speakRate)
        if config.speakMode != "off" {
            speakHotKey = HotKey(spec: config.speakHotkey) { [weak self] in self?.speakCurrent() }
            if speakHotKey == nil { configError = tr("朗读快捷键「%@」无法注册（写法不对或被占用）", config.speakHotkey) }
        }
        overlay.replaceShortcut = hotKey?.display
        overlay.speakShortcut = speakHotKey?.display
    }

    /// 界面语言变了：设置窗口的标签页名字是建窗口时定的，关掉重建一个。
    private func applyLanguage(_ setting: String) {
        let previous = L10n.current
        L10n.apply(setting)
        statusItem?.button?.image?.accessibilityDescription = tr("字里行间")
        guard L10n.current != previous, let window = settingsWindow else { return }
        let reopen = window.window?.isVisible == true
        window.close()
        settingsWindow = nil
        if reopen { DispatchQueue.main.async { self.openSettings() } }
    }

    /// 增删改模型后重新加载，并把设置窗口里的模型列表刷新成配置里的样子。
    private func reloadAfterProviderChange() -> String? {
        reloadConfig()
        settingsModel.load(config, enabled: enabled)
        return configError
    }

    private func updateConfig(_ changes: [String: Any]) {
        do {
            for (key, value) in changes { try ConfigStore.set(key, value) }
        } catch {
            configError = error.localizedDescription
        }
        reloadConfig()
    }

    // MARK: - 菜单

    /// 菜单只放常用的：总开关、在学的语言、模型、朗读方式、导出生词；其余都在设置窗口里。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem()
        let summary = config.map { config in
            "\(config.nativeLanguage.displayName) → \(config.learningLanguage.displayName) · \(config.activeProvider?.name ?? "")"
        } ?? tr("配置有误")
        header.view = SwitchMenuView(title: tr("字里行间"), subtitle: summary, isOn: enabled) { [weak self] on in
            self?.setEnabled(on)
        }
        menu.addItem(header)
        if let configError { menu.addItem(disabledItem("⚠️ \(configError)")) }
        if !AXIsProcessTrusted() {
            menu.addItem(item(tr("⚠️ 未授予辅助功能权限，点此打开设置"), #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        menu.addItem(icon("globe", submenu(tr("在学的语言"), Language.all.map { language in
            choice(language.displayName, language.code, selected: language == config?.learningLanguage, #selector(selectLearning(_:)))
        })))
        menu.addItem(icon("cpu", submenu(tr("模型"), (config?.providers ?? []).map { provider in
            choice(provider.name, provider.id, selected: provider.id == config?.activeProvider?.id, #selector(selectProvider(_:)))
        })))
        menu.addItem(icon("text.alignleft", submenu(tr("翻译范围"), [(Sentence.Scope.sentence, tr("句子")), (.paragraph, tr("段落"))].map { scope, title in
            choice(title, scope.rawValue, selected: scope == config?.scope, #selector(selectScope(_:)))
        })))
        menu.addItem(icon("speaker.wave.2", submenu(tr("朗读"), [("off", tr("关闭")), ("hotkey", tr("按快捷键")), ("auto", tr("自动朗读"))].map { mode, title in
            choice(title, mode, selected: mode == config?.speakMode, #selector(selectSpeakMode(_:)))
        })))
        menu.addItem(.separator())

        let unknown = vocab.entries.values.filter { !$0.known }.count
        menu.addItem(icon("square.and.arrow.up", item(tr("导出生词到 Anki（%@）", "\(unknown)"), #selector(exportAnki))))
        let settings = icon("gearshape", item(tr("设置…"), #selector(openSettings)))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = icon("power", item(tr("退出"), #selector(quit)))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// 每项都带图标：系统会自动给「设置…」配齿轮，只有它有图标时其余项会被挤出一列空白。
    private func icon(_ symbol: String, _ entry: NSMenuItem) -> NSMenuItem {
        entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return entry
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func choice(_ title: String, _ value: String, selected: Bool, _ action: Selector) -> NSMenuItem {
        let entry = item(title, action)
        entry.representedObject = value
        entry.state = selected ? .on : .off
        return entry
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu()
        items.forEach(menu.addItem)
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = menu
        return entry
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(enabled, forKey: "enabled")
        // 关闭时图标变灰。
        statusItem.button?.appearsDisabled = !enabled
        if !enabled {
            // 关掉时把正在跟的这句也忘掉：不然回车发送时还会拿关之前那句弹出「已发送」卡片。
            sent = nil
            pendingText = nil
            lastTarget = nil
            lastShown = nil
            overlay.hide()
        }
        settingsModel.enabled = enabled
    }

    /// 选成和母语相同的语言时两边对调，免得「中文 → 中文」。
    @objc private func selectLearning(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let config else { return }
        var changes: [String: Any] = ["learningLanguage": code, "speakVoice": ""]
        if code == config.nativeLanguage.code { changes["nativeLanguage"] = config.learningLanguage.code }
        updateConfig(changes)
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        guard let scope = sender.representedObject as? String else { return }
        updateConfig(["translateScope": scope])
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        updateConfig(["activeProvider": id])
    }

    @objc private func selectSpeakMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        updateConfig(["speakMode": mode])
    }

    @objc private func openSettings() {
        settingsModel.load(config, enabled: enabled)
        settingsModel.message = configError
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: settingsModel) }
        settingsWindow?.present()
    }

    @objc private func exportAnki() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let code = config?.learningLanguage.code ?? "en"
        let url = downloads.appendingPathComponent("gloss-vocab-\(code)-\(formatter.string(from: Date())).txt")
        do {
            _ = try vocab.exportAnki(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        commitVocab()
        NSApp.terminate(nil)
    }
}

// MARK: - 自检

func runSelfTest() -> Bool {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }

    check(Sentence.current(in: "我今天很开心", cursor: 6)?.text == "我今天很开心", "整段一句")
    check(Sentence.current(in: "第一句。第二句", cursor: 7)?.text == "第二句", "光标在第二句")
    check(Sentence.current(in: "第一句。第二句", cursor: 4)?.text == "第一句。", "刚打完句号取上一句")
    check(Sentence.current(in: "第一句。第二句。", cursor: 2)?.text == "第一句。", "光标在第一句中间")
    check(Sentence.current(in: "版本 3.5 发布了", cursor: 10)?.text == "版本 3.5 发布了", "小数点不断句")
    check(Sentence.current(in: "Hello. 你好", cursor: 9)?.text == "你好", "英文句号后断句")
    check(Sentence.current(in: "上一行\n这一行", cursor: 7)?.text == "这一行", "换行断句")
    check(Sentence.current(in: "这一行\n", cursor: 4) == nil, "空行没有句子")
    check(Sentence.current(in: "你好。 ", cursor: 4)?.range == NSRange(location: 0, length: 3), "句号后空格")
    check(Sentence.current(in: "", cursor: 0) == nil, "空文本")
    check(Sentence.containsHan("abc 中") && !Sentence.containsHan("abc."), "汉字判断")

    check(HotKey.parse("ctrl+option+e")?.display == "⌃⌥E", "快捷键解析")
    check(HotKey.parse("e") == nil, "快捷键必须带修饰键")
    check(HotKey.parse("ctrl+?") == nil, "未知键")

    let parsed = LLMClient.parseResult("```json\n{\"translation\":\"I'm off today.\",\"words\":[{\"word\":\"off\",\"gloss\":\"休息\",\"level\":\"A2\"}]}\n```")
    check(parsed?.translation == "I'm off today." && parsed?.words.first?.gloss == "休息", "解析 JSON 结果")
    check(LLMClient.parseResult("{\"translation\":\"Let's go.\",\"words\":[{\"word\":\"go\",\"zh\":\"去\"}]}")?.words.first?.gloss == "去", "兼容旧字段 zh")
    check(LLMClient.parseResult("{\"translation\":\"I am fine.\",\"note\":\"去掉了多余的 the\"}")?.note == "去掉了多余的 the", "解析润色说明")
    check(LLMClient.parseResult("Just text.")?.translation == "Just text.", "非 JSON 当译文")
    check(LLMClient.parseResult("{broken") == nil, "坏 JSON")

    check(LLMClient.appears("deal with", in: "Let's deal with it."), "词在译文里")
    check(LLMClient.appears("get off work", in: "I'm getting off work late."), "词形变化")
    check(!LLMClient.appears("achieve", in: "Can it be done?"), "译文里没有的词")
    check(LLMClient.appears("開発 (かいはつ)", in: "新機能を開発する。") && !LLMClient.appears("会議", in: "新機能を開発する。"), "日文按子串")
    check(LLMClient.parseResult("{\"translation\":\"Can it be done?\",\"words\":[{\"word\":\"achieve\"}]}")?.words.isEmpty == true, "过滤不在译文里的词")

    check(LLMClient.partialTranslation("{\"translation\": \"I'm get") == "I'm get", "流式半截译文")
    check(LLMClient.partialTranslation("{\"translation\":\"Say \\\"hi\\\" \\u4f60") == "Say \"hi\" 你", "流式转义")
    check(LLMClient.partialTranslation("{\"translation\":\"ok\\") == "ok", "流式末尾半个转义")
    check(LLMClient.partialTranslation("{\"transl") == nil, "流式还没到译文")

    check(Sentence.isComposing("没有右边bian ju", cursor: 11) && Sentence.isComposing("陪过pei'guo", cursor: 10), "拼音组字中")
    check(!Sentence.isComposing("打开 app", cursor: 6) && !Sentence.isComposing("用API", cursor: 4) && !Sentence.isComposing("好的", cursor: 2), "不是组字")
    check(Sentence.isComplete("好的。") && !Sentence.isComplete("好的"), "句子是否写完")
    let onlyLinks = ["https://github.com/qingjian-team/qingjian", "github.com/foo/bar-baz", "www.example.com/a?b=1",
                     "someone@example.com", "~/Documents/notes/draft.md", "localhost:3000/api/v1"]
    check(onlyLinks.allSatisfy { Sentence.withoutLinks($0).trimmingCharacters(in: .whitespaces).allSatisfy { !$0.isLetter } },
          "只有网址、邮箱、路径时没有剩下文字")
    check(Sentence.withoutLinks("看看这个 https://github.com/foo 怎么样").contains("怎么样"), "中文里夹着网址，文字保留")

    let zh = Language.named("zh")!, en = Language.named("en")!, ja = Language.named("ja")!, es = Language.named("es")!
    check(LanguageDetector.detect("今天下班有点晚", among: [zh, en]) == zh, "识别中文")
    check(LanguageDetector.detect("I am going home now", among: [zh, en]) == en, "识别英文")
    check(LanguageDetector.detect("ok", among: [zh, en]) == nil, "单个英文词不判")
    check(LanguageDetector.detect("今日は遅くなります", among: [zh, ja]) == ja, "假名判日文")
    check(LanguageDetector.detect("今天很忙", among: [zh, ja]) == zh, "纯汉字归中文")
    check(LanguageDetector.detect("什么鬼", among: [en, ja]) == nil && LanguageDetector.detect("我们周四开会吧", among: [en, ja]) == nil,
          "母语不是中文时，中文不当成日文")
    check(LanguageDetector.detect("明日は会議です", among: [en, ja]) == ja, "带假名仍判日文")
    check(LanguageDetector.detect("Hoy llego tarde a casa", among: [en, es]) == es, "识别西班牙语")
    check(LanguageDetector.detect("I will be late today", among: [en, es]) == en, "两种拉丁语言里判英文")

    let config = try? ConfigStore.parse(Data(ConfigStore.defaultJSON.utf8))
    check(config?.activeProvider?.id == "deepseek" && config?.providers.count == 2, "默认配置")
    check((config?.activeProvider?.extraBody["reasoning_effort"] as? String) == "none", "extraBody 读取")
    check(config?.speakMode == "hotkey" && HotKey.parse(config?.speakHotkey ?? "") != nil, "朗读默认配置")
    check(config?.nativeLanguage == zh && config?.learningLanguage == en && config?.stream == true, "语言与流式默认")
    let legacy = try? ConfigStore.parse(Data("{\"providers\":[{\"id\":\"a\",\"baseURL\":\"x\",\"model\":\"m\"}],\"targetLanguage\":\"Japanese\"}".utf8))
    check(legacy?.learningLanguage == ja, "兼容旧配置 targetLanguage")
    check(config?.palette == .aurora && legacy?.palette == .aurora, "配色默认极光")
    check(config?.autoHideSeconds == 15 && legacy?.autoHideSeconds == 15, "自动收起默认 15 秒")
    check(config?.uiLanguage == "system", "界面语言默认跟随系统")
    check(config?.scope == .sentence, "翻译范围默认按句子")

    let long = "今天上午我们先开了一个很长的需求评审会，大家讨论了新版本的首页改版方案，产品同学提出要把推荐模块往上挪，设计同学觉得这样会挤压运营位的空间，开发同学则担心接口的改动量太大，最后决定先做一版原型给老板看看效果再说"
    check(Sentence.isLong(long) && !Sentence.isLong("今天下班有点晚，我们明天再聊吧"), "长句判断")
    let tail = (long as NSString).length
    check(Sentence.target(in: long, cursor: tail)?.text == "开发同学则担心接口的改动量太大，最后决定先做一版原型给老板看看效果再说", "长句只取最后一小句加前一小句")
    check(Sentence.target(in: "今天下班有点晚，我们明天再聊吧", cursor: 15)?.text == "今天下班有点晚，我们明天再聊吧", "短句整句")
    Sentence.scope = .paragraph
    check(Sentence.target(in: "第一句。第二句，还有。\n第二行", cursor: 3)?.text == "第一句。第二句，还有。\n第二行", "段落模式取整段")
    check(Sentence.target(in: "第一段。\n\n第二段，接着写", cursor: 10)?.text == "第二段，接着写", "空行分段")
    Sentence.scope = .sentence
    check(Sentence.target(in: "价格是 1,000 元, 时间 10:30", cursor: 20)?.text == "价格是 1,000 元, 时间 10:30", "数字里的逗号冒号不切")
    L10n.apply("en")
    check(tr("设置…") == "Settings…" && tr("翻译失败：%@", "timeout") == "Translation failed: timeout"
          && Language.named("ja")?.displayName == "Japanese" && Palette.aurora.title == "Aurora", "英文界面")
    L10n.apply("ja")
    check(tr("设置…") == "設定…" && tr("翻译失败：%@", "x") == "翻訳に失敗しました：x", "日文界面")
    L10n.apply("zh")
    check(tr("设置…") == "设置…" && Language.named("ja")?.displayName == "日语", "中文界面")

    let polished = Diff.compare("I am very interesting in this project and want join your team.",
                                "I am very interested in this project and want to join your team.")
    check(polished?.filter { $0.kind == .deleted }.map(\.text) == ["interesting"], "润色对比：删掉的词")
    check(polished?.filter { $0.kind == .inserted }.map(\.text) == ["interested", "to"], "润色对比：加上的词")
    check(Diff.compare("Thanks!", "Thanks!")?.allSatisfy { $0.kind == .same } == true, "润色对比：没改")
    check(Diff.compare("Me no like it", "I really don't enjoy this at all") == nil, "润色对比：整句重写不标")
    check(Diff.tokens("今天 don't") == ["今", "天", " ", "don't"], "润色分词")

    if failures.isEmpty {
        print("self-test OK")
        return true
    }
    print("self-test FAILED: \(failures.joined(separator: ", "))")
    return false
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest() ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--demo") {
    let args = CommandLine.arguments.dropFirst(index + 1)
    // 演示的界面语言：--lang en，默认跟随系统。要在建浮窗之前定，工具栏按钮的文字是建的时候取的。
    if let lang = CommandLine.arguments.firstIndex(of: "--lang").map({ CommandLine.arguments.dropFirst($0 + 1).first ?? "" }) {
        L10n.apply(lang)
    }
    let demo = DemoDelegate(phase: args.first ?? "done", palette: Palette(rawValue: args.dropFirst().first(where: { Palette(rawValue: $0) != nil }) ?? "") ?? .aurora)
    NSApplication.shared.delegate = demo
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
