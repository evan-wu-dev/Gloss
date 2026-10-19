import AppKit
import ApplicationServices
import SwiftUI

/// 第一次打开时的欢迎引导：授权 → 模型 → 语言 → 试一下。每一步都能跳过，以后在设置里能再打开。
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case intro, access, model, languages, tryIt }
    enum TestState: Equatable { case idle, testing, ok(Double), failed(String) }
    enum Bubble: Equatable { case none, waiting, streaming(String), done(String, LearnWordDisplay?), noModel }
    struct LearnWordDisplay: Equatable { let word: String; let gloss: String }

    @Published var step = Step.intro
    /// 界面语言代码；换了以后整个引导用 tr() 重新渲染。
    @Published var ui = L10n.current
    @Published var axGranted = AXIsProcessTrusted()
    @Published var axWaiting = false

    @Published var useCustom = false
    @Published var name = ""
    @Published var baseURL = ""
    @Published var modelName = ""
    @Published var apiKey = ""
    @Published var testState = TestState.idle

    @Published var native = "zh"
    @Published var learning = "en"
    @Published var level = "B1"

    @Published var text = ""
    @Published var bubble = Bubble.none

    /// 由 AppDelegate 注入：读当前配置、写配置、换界面语言、结束引导。
    var currentConfig: () -> AppConfig? = { nil }
    var save: ([String: Any]) -> Void = { _ in }
    var saveProvider: (String, [String: Any]) -> Void = { _, _ in }
    var setUILanguage: (String) -> Void = { _ in }
    var finish: () -> Void = {}

    private let client = LLMClient()
    private var axTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var typing: Timer?
    private var requestID = 0
    private(set) var hasModel = false

    /// 第一次使用（之前没走完过引导）：语言还是出厂默认，按界面语言给出母语和学习语言。
    /// 已经用过的人重开引导时，语言设置原样保留。
    private(set) var firstRun = false
    /// 在「语言」那一步自己选过，就不再跟着界面语言自动改。
    private var languagesTouched = false

    func start(firstRun: Bool) {
        self.firstRun = firstRun
        languagesTouched = false
        let config = currentConfig()
        ui = L10n.current
        if firstRun {
            native = L10n.current
            learning = Self.defaultLearning(for: native)
            save(["nativeLanguage": native, "learningLanguage": learning])
        } else {
            native = config?.nativeLanguage.code ?? L10n.current
            learning = config?.learningLanguage.code ?? Self.defaultLearning(for: native)
        }
        if learning == native { learning = Self.defaultLearning(for: native) }
        level = config?.learnerLevel ?? "B1"
        if let provider = config?.activeProvider, !provider.apiKey.isEmpty {
            useCustom = provider.id != "deepseek"
            name = provider.name
            baseURL = provider.baseURL
            modelName = provider.model
            apiKey = provider.apiKey
            hasModel = true
        }
        watchAccessibility()
    }

    /// 母语不是英语就学英语；母语是英语，默认学西班牙语。
    static func defaultLearning(for native: String) -> String {
        native == "en" ? "es" : "en"
    }

    func go(_ next: Step) {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = next }
    }

    /// 换界面语言只换界面。只有第一次使用、还没在「语言」那步自己选过时，才顺带把母语换成这种语言。
    func chooseUI(_ code: String) {
        setUILanguage(code)
        ui = L10n.current
        guard firstRun, !languagesTouched else { return }
        native = L10n.current
        learning = Self.defaultLearning(for: native)
        save(["nativeLanguage": native, "learningLanguage": learning])
    }

    // MARK: 授权

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        axWaiting = true
    }

    /// 每半秒看一次有没有授权，打开开关后自动进入下一步，不用回来点。
    private func watchAccessibility() {
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let granted = AXIsProcessTrusted()
            guard granted != self.axGranted else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { self.axGranted = granted }
            if granted, self.step == .access {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.step == .access { self.go(.model) } }
            }
        }
    }

    // MARK: 模型

    private var draft: Provider {
        if useCustom {
            return Provider(id: "custom-onboarding", name: name.trimmingCharacters(in: .whitespaces),
                            baseURL: baseURL.trimmingCharacters(in: .whitespaces), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: modelName.trimmingCharacters(in: .whitespaces), extraBody: [:])
        }
        return Provider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com",
                        apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), model: "deepseek-flash",
                        extraBody: ["reasoning_effort": "none"])
    }

    var canTest: Bool {
        let provider = draft
        guard !provider.apiKey.isEmpty, testState != .testing else { return false }
        return !useCustom || (!provider.name.isEmpty && provider.baseURL.hasPrefix("http") && !provider.model.isEmpty)
    }

    private func config(with provider: Provider) -> AppConfig? {
        guard var config = currentConfig() ?? (try? ConfigStore.parse(Data(ConfigStore.defaultJSON.utf8))) else { return nil }
        config.providers = [provider]
        config.activeProviderID = provider.id
        config.nativeLanguage = Language.named(native) ?? config.nativeLanguage
        config.learningLanguage = Language.named(learning) ?? config.learningLanguage
        config.stream = true
        return config
    }

    /// 真的翻一句短句，量一下耗时。
    func test() {
        guard let config = config(with: draft) else { return }
        testState = .testing
        let started = Date()
        client.translate(tr("你好"), mode: .translate, config: config, onPartial: { _ in }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    switch result {
                    case .success: self.testState = .ok(Date().timeIntervalSince(started))
                    case .failure(let error): self.testState = .failed(error.localizedDescription)
                    }
                }
            }
        })
    }

    func commitModel() {
        let provider = draft
        saveProvider(provider.id == "deepseek" ? "deepseek" : "custom-" + UUID().uuidString.prefix(6).lowercased(), [
            "name": provider.name, "baseURL": provider.baseURL, "model": provider.model,
            "apiKey": provider.apiKey, "extraBody": provider.extraBody,
        ])
        hasModel = true
        go(.languages)
    }

    // MARK: 语言

    func pickNative(_ code: String) {
        languagesTouched = true
        if code == learning { learning = native }
        native = code
        save(["nativeLanguage": native, "learningLanguage": learning])
    }

    func pickLearning(_ code: String) {
        languagesTouched = true
        guard code != native else { return }
        learning = code
        save(["learningLanguage": learning, "speakVoice": ""])
    }

    func pickLevel(_ code: String) {
        level = code
        save(["learnerLevel": code])
    }

    // MARK: 试一下

    var samples: [String] {
        switch native {
        case "zh": return ["周末要不要一起去爬山？", "这个需求下周三之前能上线吗？", "谢谢你，今天真是帮了大忙"]
        case "ja": return ["週末、一緒に山登りに行かない？", "この件、水曜までに間に合いますか？"]
        case "ko": return ["주말에 같이 등산 갈래?", "이 기능 수요일까지 출시할 수 있을까요?"]
        case "es": return ["¿Vamos de excursión este fin de semana?", "¿Podemos mover la reunión al viernes?"]
        case "fr": return ["On fait une randonnée ce week-end ?", "On peut décaler la réunion à vendredi ?"]
        case "de": return ["Wollen wir am Wochenende wandern gehen?", "Können wir das Meeting auf Freitag verschieben?"]
        default: return ["Want to grab lunch tomorrow?", "Can we push the meeting to Friday?", "Thanks, that really helped a lot."]
        }
    }

    func playSample(_ sample: String) {
        typing?.invalidate()
        text = ""
        bubble = .none
        let chars = Array(sample)
        var index = 0
        typing = Timer.scheduledTimer(withTimeInterval: chars.count > 20 ? 0.045 : 0.085, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            index += 1
            self.text = String(chars.prefix(index))
            if index >= chars.count { timer.invalidate() }
        }
    }

    /// 停顿 0.6 秒后翻译，和真正用的时候一样。
    func textChanged() {
        debounce?.cancel()
        requestID += 1
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return withAnimation { bubble = .none } }
        let id = requestID
        let work = DispatchWorkItem { [weak self] in self?.translate(sentence, id: id) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func translate(_ sentence: String, id: Int) {
        guard hasModel, let base = currentConfig(), let provider = base.activeProvider, !provider.apiKey.isEmpty,
              let config = config(with: provider) else {
            return withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { bubble = .noModel }
        }
        let mode: TranslateMode = LanguageDetector.detect(sentence, among: [config.nativeLanguage, config.learningLanguage])
            == config.learningLanguage ? .polish : .translate
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { bubble = .waiting }
        client.translate(sentence, mode: mode, config: config, onPartial: { [weak self] partial in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.bubble = .streaming(partial)
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                switch result {
                case .success(let translated):
                    let word = translated.words.first.map { LearnWordDisplay(word: $0.word, gloss: $0.gloss) }
                    withAnimation(.easeOut(duration: 0.25)) { self.bubble = .done(translated.translation, word) }
                case .failure(let error):
                    self.bubble = .done(tr("翻译失败：%@", error.localizedDescription), nil)
                }
            }
        })
    }

    func stop() {
        axTimer?.invalidate()
        typing?.invalidate()
        debounce?.cancel()
    }
}

// MARK: - 窗口

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    var onClose: (() -> Void)?

    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        // 系统毛玻璃垫底：透出用户的桌面壁纸并模糊，SwiftUI 内容画在上面。
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        let host = NSHostingView(rootView: OnboardingView().environmentObject(model))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor), host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor), host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func present(firstRun: Bool) {
        model.start(firstRun: firstRun)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.alphaValue = 0
        window?.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            window?.animator().alphaValue = 1
        }
    }

    /// 结束时窗口缩小飞进菜单栏图标里，告诉用户以后去哪找它。
    func flyAway(to target: NSRect?, completion: @escaping () -> Void) {
        guard let window else { return completion() }
        let end = target.map { NSRect(x: $0.midX - 8, y: $0.midY - 6, width: 16, height: 12) }
            ?? window.frame.insetBy(dx: window.frame.width * 0.4, dy: window.frame.height * 0.4)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.6, -0.1, 0.4, 1)
            window.animator().setFrame(end, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            completion()
        })
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose?()
    }
}

// MARK: - 视觉零件

/// 石墨毛玻璃：窗口透出桌面壁纸，文字是浅色；彩色只留给流光、进度和图标。
/// 沿用 Ink 这个名字：ink 是文字和细线的颜色，paper 是白色主按钮上的深色字。
private enum Ink {
    static let ink = Color(red: 0.949, green: 0.949, blue: 0.957)
    static let paper = Color(red: 0.067, green: 0.071, blue: 0.078)
    static let green = Color(red: 0.45, green: 0.86, blue: 0.56)
}

private let auroraColors: [Color] = Palette.aurora.colors.map { Color(nsColor: $0) }
private let auroraGradient = LinearGradient(colors: auroraColors, startPoint: .leading, endPoint: .trailing)
private let primaryGradient = LinearGradient(colors: [Color(white: 0.98), Color(white: 0.9)],
                                             startPoint: .top, endPoint: .bottom)
private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// 玻璃上的一点质感：顶部像屏幕反光的一抹亮，往下淡出的点阵；换步骤时亮光挪个位置。
private struct AuroraBackground: View {
    let step: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.09), .clear], center: .top, startRadius: 0, endRadius: 380)
                .offset(x: [0, 80, -60, 40, -80][step])
                .animation(.easeInOut(duration: 1.2), value: step)
            DotGrid()
                .mask(RadialGradient(colors: [.black, .clear], center: .top, startRadius: 40, endRadius: 420))
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 9
            while y < size.height {
                var x: CGFloat = 9
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.07)))
                    x += 18
                }
                y += 18
            }
        }
    }
}

/// 从模糊里浮现：每个元素按 index 依次出来。
private struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 8)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.08 + Double(index) * 0.09)) { shown = true }
            }
    }
}

private extension View {
    func stagger(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }

    /// 可点的地方，鼠标移上去变成小手；enabled 为 false 时不变。
    /// 用 set 而不是 push / pop：换步骤时按钮直接消失，收不到移出事件，push 会让小手一直留着。
    func handCursor(_ enabled: Bool = true) -> some View {
        onHover { inside in
            if inside, enabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onDisappear { NSCursor.arrow.set() }
        .noFocusRing()
    }

    /// 不要系统的蓝色焦点光圈：会盖住彩色边框，和纸面风格也不搭。
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}

/// 转圈的彩色流光描边。
private struct GlowRing: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.5
    var glow = true

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // 先取余再换算角度：时间戳是八亿多秒，直接乘出来的角度太大，浮点精度丢掉后整圈渐变会退化成一个颜色。
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
            let gradient = AngularGradient(colors: auroraColors + [auroraColors[0]], center: .center, angle: angle)
            ZStack {
                if glow {
                    RoundedRectangle(cornerRadius: cornerRadius).stroke(gradient, lineWidth: 6).blur(radius: 8).opacity(0.55)
                }
                RoundedRectangle(cornerRadius: cornerRadius).stroke(gradient, lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Ink.paper)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(primaryGradient, in: RoundedRectangle(cornerRadius: 12))
            .overlay(Shine().clipShape(RoundedRectangle(cornerRadius: 12)))
            .shadow(color: Color.black.opacity(0.25), radius: 10, y: 5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .handCursor(isEnabled)
    }
}

/// 主按钮上隔一会儿扫过的一道高光。
private struct Shine: View {
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, auroraColors[0].opacity(0.25), auroraColors[1].opacity(0.3), auroraColors[2].opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.5)
                    .offset(x: phase < 0.4 ? -proxy.size.width : (phase - 0.4) / 0.6 * proxy.size.width * 2 - proxy.size.width * 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Ink.ink.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 11))
            .opacity(isEnabled ? 1 : 0.4)
            .handCursor(isEnabled)
    }
}

private struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Ink.ink.opacity(configuration.isPressed ? 0.9 : 0.5))
            .contentShape(Rectangle())
            .handCursor()
    }
}

private struct DarkField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Ink.ink.opacity(0.1)))
    }
}

/// 真正的应用图标：从模糊里放大浮现，背后一圈暖光，之后轻轻上下浮动。
private struct LogoMark: View {
    @State private var shown = false
    @State private var floating = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 104, height: 104)
            .background(Circle().fill(AngularGradient(colors: auroraColors + [auroraColors[0]], center: .center))
                .frame(width: 92, height: 92).blur(radius: 30).opacity(shown ? 0.32 : 0))
            .scaleEffect(shown ? 1 : 0.7)
            .blur(radius: shown ? 0 : 10)
            .opacity(shown ? 1 : 0)
            .offset(y: floating ? -3 : 3)
            .onAppear {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.15)) { shown = true }
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2.6).repeatForever().delay(1.2)) { floating = true }
            }
    }
}

/// 简单的换行排列：放语言胶囊。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// 模拟的译文浮窗：等待时边框流光 + 跳点，出字时逐字淡入。
private struct DemoBubble: View {
    let state: OnboardingModel.Bubble

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .waiting:
                HStack(spacing: 5) {
                    ForEach(0..<3) { index in BouncingDot(color: auroraColors[index], delay: Double(index) * 0.14) }
                }
                .padding(.vertical, 4)
            case .streaming(let text):
                Text(text).font(.system(size: 15)).foregroundStyle(Color(white: 0.11))
            case .done(let text, let word):
                Text(text).font(.system(size: 15)).foregroundStyle(Color(white: 0.11))
                if let word {
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text(word.word).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(white: 0.11))
                        Text(word.gloss).font(.system(size: 12)).foregroundStyle(Color(white: 0.43))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 7))
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            case .noModel:
                Text(tr("配置好模型后，这里会出现真实的译文。")).font(.system(size: 13)).foregroundStyle(Color(white: 0.35))
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if case .waiting = state { GlowRing(cornerRadius: 12) }
            if case .streaming = state { GlowRing(cornerRadius: 12, lineWidth: 1, glow: false).opacity(0.6) }
        }
        .shadow(color: Color.black.opacity(0.16), radius: 14, y: 7)
    }
}

private struct BouncingDot: View {
    let color: Color
    let delay: Double
    @State private var up = false

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .offset(y: up ? -4 : 0).opacity(up ? 1 : 0.5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.36).repeatForever().delay(delay)) { up = true }
            }
    }
}

// MARK: - 主视图

struct OnboardingView: View {
    @EnvironmentObject var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .top) {
            AuroraBackground(step: model.step.rawValue)
            if model.step != .intro {
                ProgressHeader(step: model.step.rawValue).padding(.top, 22).transition(.opacity)
            }
            Group {
                switch model.step {
                case .intro: IntroStep()
                case .access: AccessStep()
                case .model: ModelStep()
                case .languages: LanguagesStep()
                case .tryIt: TryStep()
                }
            }
            .id("\(model.step.rawValue)-\(model.ui)")
            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(y: -10))))
        }
        .frame(width: 680, height: 520)
        .foregroundStyle(Ink.ink)
        .environment(\.locale, Locale(identifier: model.ui))
    }
}

private struct ProgressHeader: View {
    let step: Int

    var body: some View {
        let labels = [tr("授权"), tr("模型"), tr("语言"), tr("试一下")]
        ZStack(alignment: .top) {
            GeometryReader { proxy in
                let inset: CGFloat = 11
                let width = proxy.size.width - inset * 2
                // 像在纸上画线：没走到的是浅灰虚线，走过的是暗金实线，进入下一步时从左往右画过去。
                Path { path in path.move(to: CGPoint(x: inset, y: 11)); path.addLine(to: CGPoint(x: inset + width, y: 11)) }
                    .stroke(Ink.ink.opacity(0.12), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Path { path in path.move(to: CGPoint(x: inset, y: 11)); path.addLine(to: CGPoint(x: inset + width, y: 11)) }
                    .trim(from: 0, to: CGFloat(max(step - 1, 0)) / 3)
                    .stroke(auroraGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .animation(.easeInOut(duration: 0.8), value: step)
            }
            HStack {
                ForEach(0..<4) { index in
                    let number = index + 1
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(number < step ? Color(white: 0.22) : (number == step ? Color.clear : Color(white: 0.12)))
                            if number == step { Circle().fill(primaryGradient) }
                            Circle().stroke(Ink.ink.opacity(number == step ? 0 : 0.2), lineWidth: 1.5)
                            Text(number < step ? "✓" : "\(number)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(number > step ? Ink.ink.opacity(0.5) : (number == step ? Ink.paper : Ink.ink))
                        }
                        .frame(width: 22, height: 22)
                        .scaleEffect(number == step ? 1.15 : 1)
                        .shadow(color: number == step ? Ink.ink.opacity(0.25) : .clear, radius: 6, y: 2)
                        Text(labels[index]).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.ink.opacity(number == step ? 1 : 0.45))
                            .fixedSize()
                    }
                    .frame(width: 22)
                    if index < 3 { Spacer() }
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: step)
        }
        .frame(height: 44)
        .padding(.horizontal, 150)
    }
}

/// 每一步的公共框架：标题、说明、内容、底部按钮。
private struct StepPage<Content: View, Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 28, weight: .bold)).stagger(0)
            Text(detail).font(.system(size: 14.5)).foregroundStyle(Ink.ink.opacity(0.66)).lineSpacing(3)
                .frame(maxWidth: 540, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).stagger(1)
            content.stagger(2)
            Spacer(minLength: 12)
            HStack { actions }.stagger(4)
        }
        .padding(.top, 96)
        .padding(.horizontal, 56)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: 开场

private struct IntroStep: View {
    @EnvironmentObject var model: OnboardingModel
    @State private var titleShown = false
    @State private var tracking: CGFloat = 1.2

    private var title: String { model.ui == "zh" ? "字里行间" : "Gloss" }
    /// 标题用宋体（英文是 New York 衬线体）：在一片无衬线的界面里带一点书页的文气，和「字里行间」相配。
    /// 宋体是 macOS 自带字体；万一读不到，退回系统衬线体，不会变成普通黑体。
    private var titleFont: Font {
        if model.ui == "zh", NSFont(name: "STSongti-SC-Bold", size: 40) != nil { return .custom("STSongti-SC-Bold", size: 40) }
        return .system(size: 40, weight: .semibold, design: .serif)
    }
    private let titleTracking: CGFloat = 2

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                LogoMark()
                HStack(spacing: 0) {
                    ForEach(Array(title.enumerated()), id: \.offset) { index, char in
                        Text(String(char))
                            .opacity(titleShown ? 1 : 0).blur(radius: titleShown ? 0 : 10).offset(y: titleShown ? 0 : 18)
                            .animation(.spring(response: 0.8, dampingFraction: 0.8).delay(0.6 + Double(index) * 0.09), value: titleShown)
                    }
                }
                .font(titleFont)
                .tracking(titleTracking)
                // 字都出来以后，一道极光从左到右扫过标题一次，停在白色。
                .overlay(Text(title).font(titleFont).tracking(titleTracking).foregroundStyle(auroraGradient).mask(TitleSweep()))
                .padding(.top, 18)
                // 正常大小写的细字：全大写读整句很吃力，也不适合中日文和德语。
                Text(tr("写在行与行之间的翻译"))
                    .font(.system(size: 14)).tracking(tracking).foregroundStyle(Ink.ink.opacity(0.55))
                    .opacity(titleShown ? 1 : 0).padding(.top, 8)
                IntroDemo().padding(.top, 30)
                VStack(spacing: 8) {
                    Button { model.go(.access) } label: { Text(tr("开始设置")) + Text("  →") }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    Button(tr("以后再说")) { model.finish() }.buttonStyle(LinkButtonStyle())
                }
                .padding(.top, 30)
                .stagger(20)
            }
            .padding(.top, 52)
            .frame(maxWidth: .infinity)

            Menu {
                ForEach(L10n.languages, id: \.self) { code in
                    Button { model.chooseUI(code) } label: {
                        if code == model.ui { Label(L10n.choiceTitle(code), systemImage: "checkmark") } else { Text(L10n.choiceTitle(code)) }
                    }
                }
            } label: {
                Label(L10n.choiceTitle(model.ui), systemImage: "globe")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Ink.ink.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Ink.ink.opacity(0.1)))
            // 靠右上角，和窗口上沿、右边缘都留出空隙。
            .padding(.top, 12).padding(.trailing, 18)
            .ignoresSafeArea()
        }
        .onAppear {
            titleShown = true
            withAnimation(.spring(response: 1.2, dampingFraction: 0.9).delay(1.25)) { tracking = 0.1 }
        }
    }
}

/// 标题上的一道光：窄窄的一条亮带从左扫到右，只扫一次。
private struct TitleSweep: View {
    @State private var progress: CGFloat = -0.5

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.45)
                .offset(x: progress * proxy.size.width)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).delay(1.35)) { progress = 1.1 }
        }
    }
}

/// 开场的小演示：一句母语自己打出来，光标旁弹出流光浮窗，译文逐词出现。
private struct IntroDemo: View {
    @EnvironmentObject var model: OnboardingModel
    @State private var typed = 0
    @State private var phase = 0
    @State private var words = 0
    @State private var timers: [Timer] = []

    private var demo: (text: String, words: [String]) {
        let english = ["Want", "to", "go", "hiking", "this", "weekend?"]
        switch model.ui {
        case "zh": return ("周末要不要一起去爬山？", english)
        case "ja": return ("週末、一緒に山登りに行かない？", ["Want", "to", "go", "hiking", "together", "this", "weekend?"])
        case "ko": return ("주말에 같이 등산 갈래?", ["Want", "to", "go", "hiking", "together", "this", "weekend?"])
        case "es": return ("¿Vamos de excursión este fin de semana?", english)
        case "fr": return ("On fait une randonnée ce week-end ?", english)
        case "de": return ("Wollen wir am Wochenende wandern gehen?", english)
        default: return ("Want to grab lunch tomorrow?", ["¿Quieres", "comer", "juntos", "mañana?"])
        }
    }

    var body: some View {
        let chars = Array(demo.text)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 1) {
                Text(String(chars.prefix(typed))).font(.system(size: 15))
                Rectangle().fill(Ink.ink).frame(width: 2, height: 19)
            }
            .padding(.leading, 18).padding(.top, 16)
            if phase >= 1 {
                HStack(spacing: 0) {
                    if phase == 1 {
                        HStack(spacing: 5) { ForEach(0..<3) { index in BouncingDot(color: auroraColors[index], delay: Double(index) * 0.14) } }
                            .padding(.vertical, 4)
                    } else {
                        ForEach(Array(demo.words.enumerated()), id: \.offset) { index, word in
                            Text(word + " ").font(.system(size: 14)).foregroundStyle(Color(white: 0.11))
                                .opacity(index < words ? 1 : 0).blur(radius: index < words ? 0 : 4)
                                .animation(.easeOut(duration: 0.4), value: words)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay { if phase < 3 { GlowRing(cornerRadius: 12) } }
                .shadow(color: Color.black.opacity(0.18), radius: 14, y: 7)
                .padding(.leading, 40).padding(.top, 50)
                .transition(.scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .frame(width: 440, height: 118, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Ink.ink.opacity(0.1)))
        .shadow(color: Color.black.opacity(0.06), radius: 14, y: 6)
        .stagger(12)
        .onAppear(perform: run)
        .onDisappear { timers.forEach { $0.invalidate() } }
    }

    private func run() {
        let count = Array(demo.text).count
        let step = 1.2 / Double(count)
        func after(_ delay: Double, _ action: @escaping () -> Void) {
            timers.append(Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in action() })
        }
        for index in 1...count { after(2.0 + Double(index) * step) { typed = index } }
        after(3.6) { withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { phase = 1 } }
        after(4.5) { phase = 2 }
        for index in 1...demo.words.count { after(4.5 + Double(index) * 0.12) { words = index } }
        after(5.4 + Double(demo.words.count) * 0.12) { withAnimation(.easeOut(duration: 0.8)) { phase = 3 } }
    }
}

// MARK: 授权

private struct AccessStep: View {
    @EnvironmentObject var model: OnboardingModel

    var body: some View {
        StepPage(title: tr("允许读取输入框"),
                 detail: tr("字里行间要看到你正在写的那句话，才能翻译；按快捷键替换时，也要能改写它。这需要 macOS 的辅助功能权限。密码框永远不会读取。")) {
            HStack(alignment: .center, spacing: 28) {
                SettingsMock(granted: model.axGranted)
                VStack(alignment: .leading, spacing: 4) {
                    // 英文等较长的说明允许换行，不要被截成「…」。
                    Group {
                        Text(tr("1. 点下面的按钮，打开系统设置"))
                        Text(tr("2. 在列表里找到「字里行间」"))
                        Text(tr("3. 打开右边的开关"))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    statusPill.padding(.top, 16)
                }
                .font(.system(size: 13.5)).foregroundStyle(Ink.ink.opacity(0.75))
            }
            .padding(.top, 26)
        } actions: {
            Button(tr("上一步")) { model.go(.intro) }.buttonStyle(LinkButtonStyle())
            Spacer()
            if model.axGranted {
                Button { model.go(.model) } label: { Text(tr("继续")) + Text("  →") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button(tr("打开系统设置")) { model.requestAccess() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var statusPill: some View {
        if model.axGranted {
            Label(tr("已授权，可以继续了"), systemImage: "checkmark.circle.fill")
                .fixedSize()
                .foregroundStyle(Ink.green)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.green.opacity(0.16), in: Capsule())
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            HStack(spacing: 8) {
                PulsingDot()
                Text(model.axWaiting ? tr("正在等待你打开开关…") : tr("还没有授权"))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Ink.ink.opacity(0.056), in: Capsule())
        }
    }
}

private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle().fill(Color.orange).frame(width: 8, height: 8)
            .background(Circle().stroke(Color.orange.opacity(pulse ? 0 : 0.6), lineWidth: 2).scaleEffect(pulse ? 2.6 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// 仿系统设置的辅助功能列表：一个指针反复去拨开关，示范该点哪里。
private struct SettingsMock: View {
    let granted: Bool

    var body: some View {
        TimelineView(.animation(paused: granted || reduceMotion)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
            let on = granted || (cycle > 0.5 && cycle < 0.92)
            let move = min(cycle / 0.4, 1)
            let eased = move * move * (3 - 2 * move)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("隐私与安全性 › 辅助功能")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(white: 0.43))
                        .padding(.bottom, 4)
                    row("Raycast", on: true, highlight: false)
                    row(tr("字里行间"), on: on, highlight: true)
                    row(tr("终端"), on: false, highlight: false)
                }
                .padding(16)
                if !granted {
                    Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.black)
                        .shadow(color: .white, radius: 1).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: 180 + (262 - 180) * eased, y: 150 - (150 - 84) * eased)
                        .scaleEffect(cycle > 0.42 && cycle < 0.5 ? 0.85 : 1)
                        .opacity(cycle > 0.85 ? max(0, 1 - (cycle - 0.85) / 0.15) : 1)
                }
            }
            .frame(width: 300, height: 180, alignment: .topLeading)
            .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.15), radius: 20, y: 10)
        }
    }

    private func row(_ title: String, on: Bool, highlight: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if highlight {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.78))
                }
            }
            .frame(width: 22, height: 22)
            Text(title).font(.system(size: 13)).foregroundStyle(Color(white: 0.11))
            Spacer()
            Capsule().fill(on ? Color.green : Color(white: 0.82)).frame(width: 34, height: 20)
                .overlay(Circle().fill(.white).frame(width: 16, height: 16).shadow(radius: 1).offset(x: on ? 7 : -7))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
        .opacity(highlight ? 1 : 0.55)
    }
}

// MARK: 模型

private struct ModelStep: View {
    @EnvironmentObject var model: OnboardingModel

    var body: some View {
        StepPage(title: tr("接上一个模型"),
                 detail: tr("翻译由你自己的模型服务完成，句子只发给它。用 DeepSeek 只要粘贴 API Key；别家选「自定义」。")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    card("DeepSeek", tr("快、便宜，只需 API Key"), selected: !model.useCustom) { model.useCustom = false }
                    card(tr("自定义"), tr("任意 OpenAI 兼容接口"), selected: model.useCustom) { model.useCustom = true }
                }
                if model.useCustom {
                    VStack(spacing: 10) {
                        TextField(tr("名称，显示在菜单里"), text: $model.name).modifier(DarkField())
                        HStack(spacing: 10) {
                            TextField(tr("接口地址，如 https://api.example.com/v1"), text: $model.baseURL).modifier(DarkField())
                            TextField(tr("模型名"), text: $model.modelName).modifier(DarkField()).frame(width: 170)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
                HStack(spacing: 10) {
                    SecureField(tr("粘贴 API Key"), text: $model.apiKey).modifier(DarkField())
                    Button(action: model.test) {
                        HStack(spacing: 8) {
                            if model.testState == .testing { ProgressView().controlSize(.small) }
                            Text(model.testState == .testing ? tr("测试中") : tr("测试连接"))
                        }
                    }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!model.canTest)
                }
                testResult
            }
            .padding(.top, 22)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.useCustom)
            .onChange(of: model.apiKey) { _ in model.testState = .idle }
            .onChange(of: model.useCustom) { _ in model.testState = .idle }
        } actions: {
            Button(tr("上一步")) { model.go(.access) }.buttonStyle(LinkButtonStyle())
            Spacer()
            Button(tr("跳过，稍后在设置里配置")) { model.go(.languages) }.buttonStyle(LinkButtonStyle()).padding(.trailing, 10)
            Button { model.commitModel() } label: { Text(tr("继续")) + Text("  →") }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!isTested)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var isTested: Bool {
        if case .ok = model.testState { return true }
        return false
    }

    @ViewBuilder private var testResult: some View {
        switch model.testState {
        case .ok(let seconds):
            Label(tr("连接正常 · 一句话大约 %@ 秒", String(format: "%.1f", seconds)), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(Ink.green)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(.orange).lineLimit(2)
                .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func card(_ title: String, _ detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Ink.ink.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(selected ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .handCursor()
        // 边框放在按钮外面：放在按钮里时渐变会被渲染成单一的强调色。
        .overlay {
            if selected {
                GlowRing(cornerRadius: 14, lineWidth: 1.6, glow: false)
            } else {
                RoundedRectangle(cornerRadius: 14).stroke(Ink.ink.opacity(0.1)).allowsHitTesting(false)
            }
        }
        .shadow(color: selected ? auroraColors[1].opacity(0.18) : .clear, radius: 12, y: 4)
    }
}

// MARK: 语言

private struct LanguagesStep: View {
    @EnvironmentObject var model: OnboardingModel
    @Namespace private var levelPill

    private let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]
    private let levelNames = ["入门", "初级", "中级", "中高级", "高级", "精通"]

    var body: some View {
        StepPage(title: tr("你在学哪门语言？"), detail: tr("写母语时翻译成它；直接用它写时，帮你改得更地道。")) {
            VStack(alignment: .leading, spacing: 0) {
                label(tr("我平时写"))
                FlowLayout {
                    ForEach(Language.all, id: \.code) { language in
                        pill(language.displayName, selected: model.native == language.code, disabled: false) { model.pickNative(language.code) }
                    }
                }
                label(tr("我在学"))
                FlowLayout {
                    ForEach(Language.all, id: \.code) { language in
                        pill(language.displayName, selected: model.learning == language.code, disabled: model.native == language.code) {
                            model.pickLearning(language.code)
                        }
                    }
                }
                HStack(spacing: 0) {
                    ForEach(levels, id: \.self) { code in
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { model.pickLevel(code) }
                        } label: {
                            Text(code).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(model.level == code ? Ink.paper : Ink.ink.opacity(0.55))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background {
                                    if model.level == code {
                                        RoundedRectangle(cornerRadius: 9).fill(primaryGradient)
                                            .shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)
                                            .matchedGeometryEffect(id: "pill", in: levelPill)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .handCursor()
                    }
                }
                .padding(4)
                .background(Ink.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 20)
                Text(levelDescription).font(.system(size: 12.5)).foregroundStyle(Ink.ink.opacity(0.55)).padding(.top, 10)
            }
        } actions: {
            Button(tr("上一步")) { model.go(.model) }.buttonStyle(LinkButtonStyle())
            Spacer()
            Button { model.go(.tryIt) } label: { Text(tr("继续")) + Text("  →") }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private var levelDescription: String {
        let index = levels.firstIndex(of: model.level) ?? 2
        return tr("%@（%@）", tr(levelNames[index]), model.level) + " · " + tr("只会标出比这个水平高、值得学的词。")
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Ink.ink.opacity(0.5))
            .padding(.top, 16).padding(.bottom, 8)
    }

    private func pill(_ title: String, selected: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { action() } }) {
            Text(title).font(.system(size: 13))
                .foregroundStyle(selected ? Ink.paper : Ink.ink.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(primaryGradient).shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)
                    } else {
                        Capsule().fill(Ink.ink.opacity(0.035)).overlay(Capsule().stroke(Ink.ink.opacity(0.07)))
                    }
                }
                .scaleEffect(selected ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.28 : 1)
        .disabled(disabled)
        .handCursor(!disabled)
    }
}

// MARK: 试一下

private struct TryStep: View {
    @EnvironmentObject var model: OnboardingModel
    @FocusState private var focused: Bool

    var body: some View {
        StepPage(title: tr("写一句试试"), detail: tr("停顿一下，译文就会出现在光标下面。点一句示例看看效果。")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(model.samples, id: \.self) { sample in
                        Button { model.playSample(sample) } label: {
                            Text(sample).font(.system(size: 13)).lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Ink.ink.opacity(0.035), in: Capsule())
                                .overlay(Capsule().stroke(Ink.ink.opacity(0.084)))
                        }
                        .buttonStyle(.plain)
                        .handCursor()
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextField(tr("在这里写点什么…"), text: $model.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .lineLimit(1...2)
                        .focused($focused)
                        .padding(.horizontal, 18).padding(.top, 16)
                    if model.bubble != .none {
                        DemoBubble(state: model.bubble)
                            .padding(.leading, 18).padding(.top, 52)
                            .transition(.scale(scale: 0.4, anchor: .topLeading).combined(with: .opacity))
                    }
                    HStack(spacing: 8) {
                        Rectangle().fill(Ink.ink.opacity(0.056)).frame(height: 1)
                        Text(hint).font(.system(size: 11.5)).foregroundStyle(Ink.ink.opacity(0.35)).fixedSize()
                        Rectangle().fill(Ink.ink.opacity(0.056)).frame(height: 1)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.ink.opacity(live ? 0.3 : 0.1), lineWidth: live ? 1.5 : 1))
                .shadow(color: Color.black.opacity(live ? 0.1 : 0.04), radius: 14, y: 6)
                .animation(.easeOut(duration: 0.3), value: live)
            }
            .padding(.top, 18)
            .onChange(of: model.text) { _ in model.textChanged() }
            .onAppear { focused = true }
        } actions: {
            Button(tr("上一步")) { model.go(.languages) }.buttonStyle(LinkButtonStyle())
            Spacer()
            Button { model.finish() } label: { Text(tr("开始使用")) + Text("  →") }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private var live: Bool {
        guard !model.text.isEmpty else { return false }
        if case .done = model.bubble { return false }
        return true
    }

    private var hint: String {
        if case .done = model.bubble { return tr("按 ⌃⌥E 可以把这句换成译文") }
        return tr("停顿 0.6 秒后开始翻译")
    }
}

// MARK: - 结束提示

/// 引导结束后在菜单栏图标正下方冒出来的提示卡片。
/// 不用系统的 NSPopover：它挂在图标上弹出时，系统会用强调色把图标整块标成「按下」，盖住图标背后的彩带；
/// 样式也是跟着菜单栏走的半透明灰，和引导不搭。
enum StatusHint {
    private static var panel: NSPanel?

    /// anchor 是菜单栏图标在屏幕上的位置。
    static func show(below anchor: NSRect, title: String, detail: String) {
        panel?.orderOut(nil)
        let host = NSHostingView(rootView: StatusHintView(title: title, detail: detail, arrowOffset: 0) { hide() })
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        // 图标靠近屏幕边时卡片会被推回屏幕内，尖角要跟着挪，始终正对图标。
        let arrowOffset = min(max(anchor.midX - (x + size.width / 2), -size.width / 2 + 40), size.width / 2 - 40)
        host.rootView = StatusHintView(title: title, detail: detail, arrowOffset: arrowOffset) { hide() }
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height + 6))
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak panel] in
            if let panel, panel === self.panel { hide() }
        }
    }

    static func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct StatusHintView: View {
    let title: String
    let detail: String
    /// 尖角相对卡片中线的水平偏移。
    let arrowOffset: CGFloat
    let dismiss: () -> Void
    @State private var shown = false

    private let arrow: CGFloat = 8

    var body: some View {
        let shape = HintBubble(cornerRadius: 14, arrowOffset: arrowOffset, arrowHeight: arrow)
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12 + arrow).padding(.bottom, 12)
        .frame(width: 300, alignment: .leading)
        .background(shape.fill(Color(red: 0.12, green: 0.125, blue: 0.14)))
        // 卡片和尖角是同一个形状，流光边框连着尖角一起描。
        .overlay(GlowStroke(shape: shape, lineWidth: 1.2).opacity(0.9))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(16)
        .scaleEffect(shown ? 1 : 0.8, anchor: UnitPoint(x: 0.5 + arrowOffset / 332, y: 0))
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) { shown = true } }
        .environment(\.colorScheme, .dark)
    }
}

/// 顶边长出一个尖角的圆角卡片。
private struct HintBubble: Shape {
    let cornerRadius: CGFloat
    let arrowOffset: CGFloat
    let arrowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight, width: rect.width, height: rect.height - arrowHeight)
        let r = cornerRadius
        let tipX = min(max(rect.midX + arrowOffset, body.minX + r + arrowHeight), body.maxX - r - arrowHeight)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addLine(to: CGPoint(x: tipX - arrowHeight, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: tipX, y: rect.minY + 0.5), control: CGPoint(x: tipX - 1.5, y: rect.minY + 1))
        path.addQuadCurve(to: CGPoint(x: tipX + arrowHeight, y: body.minY), control: CGPoint(x: tipX + 1.5, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 沿任意形状转圈的彩色流光描边（GlowRing 只能描圆角矩形）。
private struct GlowStroke<S: Shape>: View {
    let shape: S
    var lineWidth: CGFloat = 1.5

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
            shape.stroke(AngularGradient(colors: auroraColors + [auroraColors[0]], center: .center, angle: angle), lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}
