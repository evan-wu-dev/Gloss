import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// 设置窗口的数据。每改一项就写进 config.json 并让 App 重新加载；write 返回重新加载后的错误（如快捷键注册失败）。
final class SettingsModel: ObservableObject {
    struct ProviderDraft: Identifiable, Equatable {
        let id: String
        var name: String
        var baseURL: String
        var model: String
        var apiKey: String
        /// 合并进请求体的私有参数（关思考等），JSON 对象文本；空表示没有。
        var extraBody: String
    }

    @Published var enabled = true
    @Published var native = "zh"
    @Published var learning = "en"
    @Published var level = "B1"
    @Published var checkLearning = true
    @Published var stream = true
    @Published var autoHide = 15.0
    @Published var debounceMs = 600
    @Published var providerID = ""
    @Published var providers: [ProviderDraft] = []
    @Published var speakMode = "hotkey"
    @Published var voiceID = ""
    @Published var rate = 1.0
    @Published var replaceHotkey = ""
    @Published var speakHotkey = ""
    @Published var palette = Palette.aurora
    @Published var launchAtLogin = false
    @Published var uiLanguage = "system"
    @Published var scope = "sentence"
    /// 最近一次保存后的问题（配置有误、快捷键被占用）。
    @Published var message: String?

    var write: ([String: Any]) -> String? = { _ in nil }
    var writeProvider: (String, [String: Any]) -> String? = { _, _ in nil }
    var removeProvider: (String) -> String? = { _ in nil }
    var setEnabled: (Bool) -> Void = { _ in }
    var preview: (String) -> Void = { _ in }
    var showOnboarding: () -> Void = {}

    func load(_ config: AppConfig?, enabled: Bool) {
        self.enabled = enabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard let config else { return }
        native = config.nativeLanguage.code
        learning = config.learningLanguage.code
        level = config.learnerLevel
        checkLearning = config.checkLearning
        stream = config.stream
        autoHide = config.autoHideSeconds
        debounceMs = config.debounceMs
        providerID = config.activeProvider?.id ?? ""
        providers = config.providers.map { provider in
            let extra = provider.extraBody.isEmpty ? nil
                : try? JSONSerialization.data(withJSONObject: provider.extraBody, options: [.sortedKeys, .withoutEscapingSlashes])
            return ProviderDraft(id: provider.id, name: provider.name, baseURL: provider.baseURL, model: provider.model,
                                 apiKey: provider.apiKey, extraBody: extra.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        speakMode = config.speakMode
        voiceID = config.speakVoice
        rate = config.speakRate
        replaceHotkey = config.replaceHotkey
        speakHotkey = config.speakHotkey
        palette = config.palette
        uiLanguage = config.uiLanguage
        scope = config.scope.rawValue
    }

    func save(_ changes: [String: Any]) {
        message = write(changes)
    }

    /// 改了就存的开关、选项。
    func binding<Value: Equatable>(_ path: ReferenceWritableKeyPath<SettingsModel, Value>, key: String,
                                   encode: @escaping (Value) -> Any = { $0 }) -> Binding<Value> {
        Binding(get: { self[keyPath: path] }, set: { value in
            guard value != self[keyPath: path] else { return }
            self[keyPath: path] = value
            self.save([key: encode(value)])
        })
    }

    /// 母语和在学的语言选成一样时两边对调，免得「中文 → 中文」。
    func languageBinding(native isNative: Bool) -> Binding<String> {
        Binding(get: { isNative ? self.native : self.learning }, set: { code in
            let other = isNative ? self.learning : self.native
            let mine = isNative ? self.native : self.learning
            var changes: [String: Any] = [isNative ? "nativeLanguage" : "learningLanguage": code]
            if code == other { changes[isNative ? "learningLanguage" : "nativeLanguage"] = mine }
            if isNative {
                if code == other { self.learning = mine }
                self.native = code
            } else {
                if code == other { self.native = mine }
                self.learning = code
                self.voiceID = ""
                changes["speakVoice"] = ""
            }
            self.save(changes)
        })
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = tr("开机自启设置失败：%@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 窗口

final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // 不要切换动画：动画时窗口先按旧高度显示新页面（上下被裁），再跳到新高度。
        tabs.transitionOptions = [.allowUserInteraction]
        func add<Content: View>(_ title: String, _ symbol: String, height: CGFloat, _ view: Content) {
            let host = NSHostingController(rootView: view.environmentObject(model).frame(width: 520, height: height))
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(tr("通用"), "gearshape", height: 500, GeneralSettings())
        add(tr("语言"), "globe", height: 190, LanguageSettings())
        add(tr("模型"), "cpu", height: 270, ModelSettings())
        add(tr("朗读"), "speaker.wave.2", height: 205, SpeechSettings())
        add(tr("快捷键"), "keyboard", height: 215, ShortcutSettings())
        add(tr("外观"), "paintpalette", height: 160, AppearanceSettings())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 设置页底部的提示：保存后有问题时显示。
private struct MessageRow: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        if let message = model.message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 各页

private struct GeneralSettings: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(tr("界面语言"), selection: model.binding(\.uiLanguage, key: "uiLanguage")) {
                    ForEach(L10n.choices, id: \.self) { Text(L10n.choiceTitle($0)).tag($0) }
                }
                Toggle(tr("字里行间"), isOn: Binding(get: { model.enabled }, set: { model.enabled = $0; model.setEnabled($0) }))
                Toggle(tr("开机自动启动"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                LabeledContent(tr("欢迎引导")) {
                    Button(tr("重新打开…")) { model.showOnboarding() }
                }
            }
            Section {
                Picker(tr("翻译范围"), selection: model.binding(\.scope, key: "translateScope")) {
                    Text(tr("句子")).tag("sentence")
                    Text(tr("段落")).tag("paragraph")
                }
                Toggle(tr("写外语时纠错润色"), isOn: model.binding(\.checkLearning, key: "checkLearning"))
                Toggle(tr("流式输出"), isOn: model.binding(\.stream, key: "stream"))
                Picker(tr("停顿多久开始翻译"), selection: model.binding(\.debounceMs, key: "debounceMs")) {
                    ForEach([400, 600, 800, 1000, 1500], id: \.self) { ms in
                        Text(String(format: tr("%g 秒"), Double(ms) / 1000)).tag(ms)
                    }
                }
                Picker(tr("自动收起"), selection: model.binding(\.autoHide, key: "autoHideSeconds")) {
                    ForEach([8.0, 15, 30, 60], id: \.self) { seconds in
                        Text(tr("%@ 秒", "\(Int(seconds))")).tag(seconds)
                    }
                    Text(tr("不自动收起")).tag(0.0)
                }
            } footer: {
                Text(tr("翻译范围：句子模式只翻光标所在的一句，很长的句子只翻光标附近的两小段；段落模式整段一起翻，上下文更完整，但更慢、也更费 token。") + "\n" + tr("纠错润色：用在学的语言写东西时，给出更地道的写法并标出改动。\n自动收起：句子多久没变化就收起浮窗，鼠标停在浮窗上时不收。"))
                    .foregroundStyle(.secondary)
            }
            MessageRow()
        }
        .formStyle(.grouped)
    }
}

private struct LanguageSettings: View {
    @EnvironmentObject var model: SettingsModel

    private let levels = [("A1", tr("入门")), ("A2", tr("初级")), ("B1", tr("中级")), ("B2", tr("中高级")), ("C1", tr("高级")), ("C2", tr("精通"))]

    var body: some View {
        Form {
            Section {
                Picker(tr("母语"), selection: model.languageBinding(native: true)) {
                    ForEach(Language.all, id: \.code) { Text($0.displayName).tag($0.code) }
                }
                Picker(tr("在学的语言"), selection: model.languageBinding(native: false)) {
                    ForEach(Language.all, id: \.code) { Text($0.displayName).tag($0.code) }
                }
                Picker(tr("我的水平"), selection: model.binding(\.level, key: "learnerLevel")) {
                    ForEach(levels, id: \.0) { Text(tr("%@（%@）", $0.1, $0.0)).tag($0.0) }
                }
            } footer: {
                Text(tr("写母语时，翻译成在学的语言；写在学的语言时，纠错润色。\n我的水平：只标比你水平高、值得学的生词。"))
                    .foregroundStyle(.secondary)
            }
            MessageRow()
        }
        .formStyle(.grouped)
    }
}

/// 模型列表：右侧「使用」切换、「…」里编辑和删除；添加和编辑都在弹窗里做。
private struct ModelSettings: View {
    @EnvironmentObject var model: SettingsModel
    /// 弹窗里正在编辑的模型；isNew 表示新加的，保存后才写进配置。
    @State private var editing: (draft: SettingsModel.ProviderDraft, isNew: Bool)?
    @State private var deleting: SettingsModel.ProviderDraft?

    var body: some View {
        Form {
            Section {
                ForEach(model.providers) { provider in
                    row(provider)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button(tr("添加模型…")) {
                        let id = "custom-" + UUID().uuidString.prefix(6).lowercased()
                        editing = (SettingsModel.ProviderDraft(id: id, name: "", baseURL: "", model: "", apiKey: "", extraBody: ""), true)
                    }
                }
            }
            MessageRow()
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing {
                ProviderEditor(draft: editing.draft, isNew: editing.isNew) { self.editing = nil }
                    .environmentObject(model)
            }
        }
        .confirmationDialog(tr("删除「%@」？", deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("删除"), role: .destructive) {
                if let deleting { model.message = model.removeProvider(deleting.id) }
            }
        } message: {
            Text(tr("会从配置里移除这个模型和它的 API Key。"))
        }
    }

    private func row(_ provider: SettingsModel.ProviderDraft) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(provider.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if provider.id == model.providerID {
                Text(tr("使用中"))
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            } else {
                Button(tr("使用")) {
                    model.providerID = provider.id
                    model.save(["activeProvider": provider.id])
                }
            }
            Menu {
                Button(tr("编辑…")) { editing = (provider, false) }
                Button(tr("删除…"), role: .destructive) { deleting = provider }
                    .disabled(model.providers.count <= 1)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// 添加 / 编辑模型的弹窗。额外参数是各家私有的请求参数，放在「高级」里默认收起。
private struct ProviderEditor: View {
    @EnvironmentObject var model: SettingsModel
    @State var draft: SettingsModel.ProviderDraft
    let isNew: Bool
    let dismiss: () -> Void
    @State private var problem: String?
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(tr("名称"), text: $draft.name, prompt: Text(tr("显示在菜单里，比如 DeepSeek")))
                    TextField(tr("接口地址"), text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
                    TextField(tr("模型名"), text: $draft.model, prompt: Text(tr("比如 deepseek-flash")))
                    SecureField("API Key", text: $draft.apiKey, prompt: Text("sk-…"))
                } header: {
                    Text(isNew ? tr("添加模型") : tr("编辑「%@」", model.providers.first { $0.id == draft.id }?.name ?? draft.name))
                } footer: {
                    Text(tr("支持 OpenAI 兼容接口（DeepSeek、智谱、通义、Kimi、OpenAI 等），接口地址填到 /v1 这一级即可。"))
                        .foregroundStyle(.secondary)
                }
                Section {
                    // 整行可点，不只是箭头。
                    HStack {
                        Text(tr("高级"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showAdvanced.toggle() }
                    if showAdvanced {
                        TextField(tr("额外参数"), text: $draft.extraBody, prompt: Text(tr("可选")))
                    }
                } footer: {
                    if showAdvanced {
                        Text(tr("常用来关掉模型的「思考」，让翻译更快：") + "\nDeepSeek: {\"reasoning_effort\":\"none\"}\n" + tr("智谱") + ": {\"thinking\":{\"type\":\"disabled\"}}")
                            .foregroundStyle(.secondary)
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(tr("取消"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? tr("添加") : tr("保存"), action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        // 表单本身会滚动、没有理想高度，弹窗高度按有没有展开「高级」、有没有错误提示给定。
        .frame(width: 460, height: 365 + (showAdvanced ? 105 : 0) + (problem == nil ? 0 : 56))
    }

    private func save() {
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        draft.model = draft.model.trimmingCharacters(in: .whitespaces)
        draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.extraBody = draft.extraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { return problem = tr("名称不能为空") }
        guard draft.baseURL.hasPrefix("http") else { return problem = tr("接口地址要以 http:// 或 https:// 开头") }
        guard !draft.model.isEmpty else { return problem = tr("模型名不能为空") }
        var extra: [String: Any] = [:]
        if !draft.extraBody.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(draft.extraBody.utf8)) as? [String: Any] else {
                showAdvanced = true
                return problem = tr("额外参数要是 JSON 对象，或者留空")
            }
            extra = parsed
        }
        if let error = model.writeProvider(draft.id, [
            "name": draft.name, "baseURL": draft.baseURL, "model": draft.model, "apiKey": draft.apiKey, "extraBody": extra,
        ]) {
            return problem = error
        }
        dismiss()
    }
}

private struct SpeechSettings: View {
    @EnvironmentObject var model: SettingsModel
    @State private var rate = 1.0

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(model.learning) && !$0.identifier.contains("speech.synthesis.voice") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    var body: some View {
        Form {
            Section {
                Picker(tr("朗读"), selection: model.binding(\.speakMode, key: "speakMode")) {
                    Text(tr("关闭")).tag("off")
                    Text(tr("按快捷键朗读")).tag("hotkey")
                    Text(tr("译文出来后自动朗读")).tag("auto")
                }
                Picker(tr("声音"), selection: model.binding(\.voiceID, key: "speakVoice")) {
                    Text(tr("自动（音质最好的）")).tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(voice.quality == .default ? voice.name : tr("%@（%@）", voice.name, voice.quality == .premium ? tr("高级音质") : tr("增强")))
                            .tag(voice.identifier)
                    }
                }
                LabeledContent(tr("语速")) {
                    HStack {
                        Slider(value: $rate, in: 0.5...1.5, step: 0.1) { editing in
                            if !editing, rate != model.rate {
                                model.rate = rate
                                model.save(["speakRate": rate])
                            }
                        }
                        Text(String(format: "%.1f×", rate)).monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            } footer: {
                HStack {
                    Text(tr("用系统自带的语音，离线、免费。\n想要更自然的声音，可以在系统设置 → 辅助功能 → 朗读内容里下载「增强」或「高级」语音。"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("试听")) { model.preview(sample) }
                }
            }
            MessageRow()
        }
        .formStyle(.grouped)
        .onAppear { rate = model.rate }
    }

    private var sample: String {
        switch model.learning {
        case "zh": return "你好，很高兴认识你。"
        case "ja": return "こんにちは、よろしくお願いします。"
        case "ko": return "안녕하세요, 만나서 반가워요."
        case "es": return "Hola, encantado de conocerte."
        case "fr": return "Bonjour, ravi de vous rencontrer."
        case "de": return "Hallo, schön dich kennenzulernen."
        default: return "Hi, nice to meet you."
        }
    }
}

private struct ShortcutSettings: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("把这句换成译文")) {
                    ShortcutRecorder(spec: model.replaceHotkey) { spec in
                        guard spec != model.speakHotkey else { return model.message = tr("和朗读快捷键重复了") }
                        model.replaceHotkey = spec
                        model.save(["replaceHotkey": spec])
                    }
                }
                LabeledContent(tr("朗读译文")) {
                    ShortcutRecorder(spec: model.speakHotkey) { spec in
                        guard spec != model.replaceHotkey else { return model.message = tr("和替换快捷键重复了") }
                        model.speakHotkey = spec
                        model.save(["speakHotkey": spec])
                    }
                }
                LabeledContent(tr("收起浮窗")) { Text("Esc").foregroundStyle(.secondary) }
            } footer: {
                Text(tr("点一下按钮，再按下新的组合键（至少带一个 ⌃ ⌥ ⇧ ⌘），按 Esc 取消。\n朗读设为「关闭」时，朗读快捷键不生效。"))
                    .foregroundStyle(.secondary)
            }
            MessageRow()
        }
        .formStyle(.grouped)
    }
}

/// 点一下进入录制，按下带修饰键的组合就记下来。
private struct ShortcutRecorder: View {
    let spec: String
    let onChange: (String) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? tr("按下新快捷键…") : (HotKey.parse(spec)?.display ?? tr("未设置")))
                .monospaced()
                .frame(minWidth: 110)
        }
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func toggle() {
        if recording { return stop() }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let spec = HotKey.spec(keyCode: event.keyCode, modifiers: flags) else {
                NSSound.beep()
                return nil
            }
            stop()
            onChange(spec)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct AppearanceSettings: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(tr("流光配色"), selection: model.binding(\.palette, key: "palette", encode: { $0.rawValue })) {
                    ForEach(Palette.allCases, id: \.self) { palette in
                        Text(palette.title).tag(palette)
                    }
                }
                LabeledContent(tr("预览")) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.palette.colors.enumerated()), id: \.offset) { _, color in
                            Circle().fill(Color(nsColor: color)).frame(width: 14, height: 14)
                        }
                    }
                }
            } footer: {
                Text(tr("等待翻译时边框的流光、跳动小点和重新翻译时的扫光都用这组颜色。"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
