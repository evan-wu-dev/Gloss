import AppKit

/// 不抢焦点的浮窗：点上面的词不会把输入框的焦点拿走。
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// 实色背景：毛玻璃压在深色窗口上会发灰看不清。updateLayer 在外观切换时会重跑，深浅色跟着系统走。
private final class OverlayBackground: NSView {
    var radius: CGFloat = 12

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// 给卡片投影的外壳：窗口自带的阴影会把外圈的光晕也算进去，所以自己画。
private final class ShadowHost: NSView {
    var radius: CGFloat = 12

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.5 : 0.16
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

/// 绕卡片边缘转圈的彩色流光。ring 是贴边的细线（盖在卡片上），glow 是外圈的柔光（垫在卡片下）。
private final class FlowRing: NSView {
    enum Style { case ring, glow }

    private let style: Style
    private let host = CALayer()
    private let gradient = CAGradientLayer()
    private let shape = CAShapeLayer()
    private let halo = CALayer()
    /// 光晕从卡片边缘往外淡出的距离。
    private static let haloBlur: CGFloat = 10

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(host)
        host.addSublayer(gradient)
        host.mask = shape
        host.opacity = 0
        halo.contentsGravity = .resize
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        shape.fillColor = nil
        shape.strokeColor = NSColor.black.cgColor
        shape.lineWidth = 1
        // 光晕的遮罩是一张预先画好的「卡片 + 外圈渐淡」透明度图：卡片盖住中间，只在四周露出由浓到淡的彩光。
        // （给图层加 CIGaussianBlur 在这个窗口里不生效，所以不靠滤镜。）
        if style == .glow { host.mask = halo }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColors(_ colors: [NSColor]) {
        gradient.colors = (colors + colors.prefix(1)).map(\.cgColor)
    }

    func place(around card: CGRect, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = bounds
        shape.frame = bounds
        let side = hypot(card.width, card.height) + 40
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: card.midX, y: card.midY)
        let rect = card.insetBy(dx: 0.5, dy: 0.5)
        shape.path = CGPath(roundedRect: rect, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil)
        if style == .glow {
            halo.frame = bounds
            halo.contents = Self.haloImage(size: bounds.size, card: card, radius: radius, scale: window?.backingScaleFactor ?? 2)
        }
        CATransaction.commit()
    }

    private static func haloImage(size: CGSize, card: CGRect, radius: CGFloat, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // 阴影的模糊半径按像素算、不跟 CTM 缩放，要手动乘上屏幕倍数；叠画两次让靠近卡片的那圈更浓。
        context.setShadow(offset: .zero, blur: haloBlur * scale, color: NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for _ in 0..<2 {
            context.addPath(path)
            context.fillPath()
        }
        return context.makeImage()
    }

    /// level 0 熄灭、1 全亮；熄灭后停掉旋转动画省电。
    func setLevel(_ level: Float, animated: Bool) {
        let target = style == .glow ? level * 0.55 : level
        guard host.opacity != target else { return }
        if target > 0, gradient.animation(forKey: "spin") == nil, !reduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 2.4
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.host.opacity == 0 else { return }
            self.gradient.removeAnimation(forKey: "spin")
        }
        host.opacity = target
        CATransaction.commit()
    }
}

/// 继续编辑时盖在旧译文上的扫光：一道彩色渐变，只在字形上露出来。
private final class SheenView: NSView {
    private let gradient = CAGradientLayer()
    private let glyphs = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.mask = glyphs
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start(over label: NSTextField, colors: [NSColor]) {
        guard let card = superview, label.bounds.width > 0,
              let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return }
        label.cacheDisplay(in: label.bounds, to: rep)
        let image = NSImage(size: label.bounds.size)
        image.addRepresentation(rep)
        frame = label.convert(label.bounds, to: card)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        glyphs.frame = bounds
        glyphs.contents = image
        glyphs.contentsScale = window?.backingScaleFactor ?? 2
        let clear = colors[0].withAlphaComponent(0).cgColor
        gradient.colors = [clear, colors[0].cgColor, colors[1].cgColor, colors[2].cgColor, clear]
        CATransaction.commit()

        if gradient.animation(forKey: "sweep") == nil {
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.5, -0.375, -0.25, -0.125, 0]
            sweep.toValue = [1, 1.125, 1.25, 1.375, 1.5]
            sweep.duration = reduceMotion ? 3.2 : 1.6
            sweep.repeatCount = .infinity
            gradient.add(sweep, forKey: "sweep")
        }
        isHidden = false
    }

    func stop() {
        isHidden = true
        gradient.removeAllAnimations()
    }
}

/// 等待中的三个跳动小点：依次上浮、变淡，循环播放；颜色取配色的前三个。
private final class LoadingDots: NSView {
    private let size: CGFloat = 6
    private let gap: CGFloat = 5
    private let lift: CGFloat = 4
    private var dots: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(index) * (size + gap), y: 0, width: size, height: size)
            dot.cornerRadius = size / 2
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 3 * size + 2 * gap, height: size + lift) }

    func setColors(_ colors: [NSColor]) {
        for (dot, color) in zip(dots, colors) { dot.backgroundColor = color.cgColor }
    }

    func start() {
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() where dot.animation(forKey: "bounce") == nil {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = reduceMotion ? 0 : lift
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.45
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 0.36
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = now + Double(index) * 0.14
            group.fillMode = .backwards
            dot.add(group, forKey: "bounce")
        }
    }

    func stop() {
        dots.forEach { $0.removeAllAnimations() }
    }
}

struct OverlayWord: Equatable {
    let word: String
    let gloss: String
    let level: String
    let isNew: Bool
}

/// 一段带底色的小字：润色徽章、生词等级。
private final class Pill: NSView {
    private let label: NSTextField
    private let fill: () -> NSColor?
    private let stroke: () -> NSColor?

    init(_ text: String, font: NSFont, color: NSColor, insets: NSEdgeInsets, radius: CGFloat,
         fill: @escaping () -> NSColor? = { nil }, stroke: @escaping () -> NSColor? = { nil }) {
        label = NSTextField(labelWithString: text)
        self.fill = fill
        self.stroke = stroke
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill()?.cgColor
        layer?.borderColor = stroke()?.cgColor
        layer?.borderWidth = stroke() == nil ? 0 : 1
    }
}

/// 一个词的小标签：中性底色，生词前面一个橙点，右侧小字标等级。左键朗读，右键标记认识了。
private final class WordChip: NSView {
    let word: String
    var onClick: ((String) -> Void)?
    var onRightClick: ((String) -> Void)?

    init(_ item: OverlayWord) {
        word = item.word
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        toolTip = item.isNew ? tr("生词 · 点击朗读 · 右键标记为认识了") : tr("点击朗读 · 右键标记为认识了")

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        if item.isNew {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            row.addArrangedSubview(dot)
        }
        let wordLabel = NSTextField(labelWithString: item.word)
        wordLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        wordLabel.textColor = .labelColor
        row.addArrangedSubview(wordLabel)
        if !item.gloss.isEmpty {
            let gloss = NSTextField(labelWithString: item.gloss)
            gloss.font = .systemFont(ofSize: 12)
            gloss.textColor = .secondaryLabelColor
            row.addArrangedSubview(gloss)
        }
        if !item.level.isEmpty {
            row.addArrangedSubview(Pill(item.level, font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor,
                                        insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4), radius: 4,
                                        stroke: { NSColor.secondaryLabelColor.withAlphaComponent(0.3) }))
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?(word) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(word) }
}

/// 悬停工具栏上的一个图标按钮。
private final class ToolButton: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var hovered = false { didSet { needsDisplay = true } }

    init(symbol: String, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .labelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovered ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 浮窗所处的阶段，决定 loading 怎么画。
enum OverlayPhase: Equatable {
    /// 第一次翻译、还没有任何译文：光标旁一个带流光的小胶囊。
    case waiting
    /// 还在打同一句、新请求还没发：上一版译文变淡。
    case stale
    /// 新请求在路上：上一版译文上扫过一道光。
    case refreshing
    /// 流式出字中：新字带一点颜色余温，边框流光变弱。
    case streaming
    case done
    /// 报错、配置有问题。
    case message
}

struct OverlayContent: Equatable {
    var phase: OverlayPhase
    var translation = ""
    /// 润色模式下与原句的对比；nil 时直接显示译文。
    var diff: [Diff.Segment]?
    var badge: String?
    /// 等待时跳点旁边的一行小字（段落模式翻得慢时提示一下）。
    var hint: String?
    /// 卡片顶上的灰色小标签，如「已发送」。
    var tag: String?
    var note = ""
    var noteIsOK = false
    var words: [OverlayWord] = []
}

/// 光标下方的译文浮窗。窗口比卡片大一圈透明边：留给外圈光晕、阴影和悬停工具栏。
final class OverlayController: NSObject {
    var onSpeakWord: ((String) -> Void)?
    var onToggleKnown: ((String) -> Void)?
    var onSpeak: (() -> Void)?
    var onReplace: (() -> Void)?
    var palette: Palette = .aurora { didSet { applyPalette() } }
    /// 演示截图用：当作鼠标一直停在卡片上，工具栏常亮。
    var pinHover = false { didSet { updateHover() } }
    /// 工具栏按钮的悬停提示里显示的快捷键。
    /// 设快捷键时顺带按当前界面语言刷新三个按钮的提示（重新加载配置时会设）。
    var speakShortcut: String? {
        didSet {
            speakButton.toolTip = [tr("朗读"), speakShortcut].compactMap { $0 }.joined(separator: " ")
            copyButton.toolTip = tr("复制译文")
        }
    }
    var replaceShortcut: String? { didSet { replaceButton.toolTip = [tr("替换原句"), replaceShortcut].compactMap { $0 }.joined(separator: " ") } }

    private let panel: OverlayPanel
    private let root = NSView()
    private let glow = FlowRing(style: .glow)
    private let shadowHost = ShadowHost()
    private let card = OverlayBackground()
    private let ring = FlowRing(style: .ring)
    private let toolbar = OverlayBackground()
    private let speakButton = ToolButton(symbol: "speaker.wave.2", label: tr("朗读"))
    private let replaceButton = ToolButton(symbol: "arrow.turn.down.left", label: tr("替换原句"))
    private let copyButton = ToolButton(symbol: "doc.on.doc", label: tr("复制"))
    private let badgeRow = NSStackView()
    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    private let sheen = SheenView()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let wordsRow = NSStackView()
    private let dots = LoadingDots()
    private let waitHint = NSTextField(labelWithString: "")
    private lazy var waitRow = NSStackView(views: [dots, waitHint])
    private let stack = NSStackView()

    private let textWidth: CGFloat = 420
    private let radius: CGFloat = 12
    /// 卡片四周的透明边：上边留给工具栏（压在卡片上沿），其余留给光晕和阴影。
    private let margin = NSEdgeInsets(top: 24, left: 16, bottom: 22, right: 16)

    private(set) var isVisible = false
    /// 鼠标正停在卡片（或工具栏）上。
    var isHovering: Bool { isVisible && hovering }
    private var content: OverlayContent?
    private var placedAbove = false
    private var hovering = false
    private var toolbarShown = false
    private var mouseMonitors: [Any] = []
    private var caret: CGRect = .zero
    /// 逐字出现：revealText 是收到的译文，已经打出前 shown 个字，births 是最近打出的那些字各自出现的时间。
    private var revealText = ""
    private var shown = 0
    private var births: [CFTimeInterval] = []
    private var carry = 0.0
    private var lastStep: CFTimeInterval = 0
    private var revealTimer: Timer?
    /// 新字从透明淡入的时长、从配色褪回正文色的时长。
    private let fadeDuration: CFTimeInterval = 0.18
    private let tintDuration: CFTimeInterval = 0.7

    override init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        root.wantsLayer = true
        panel.contentView = root
        card.radius = radius
        shadowHost.radius = radius
        card.autoresizingMask = [.width, .height]
        shadowHost.addSubview(card)
        for view in [glow, shadowHost, ring, toolbar] { root.addSubview(view) }

        translationLabel.font = .systemFont(ofSize: 15)
        translationLabel.isSelectable = false
        translationLabel.lineBreakMode = .byWordWrapping
        noteLabel.font = .systemFont(ofSize: 12.5)
        noteLabel.isSelectable = false
        badgeRow.orientation = .horizontal
        wordsRow.orientation = .horizontal
        wordsRow.spacing = 6

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        waitRow.orientation = .horizontal
        waitRow.alignment = .centerY
        waitRow.spacing = 8
        waitHint.font = .systemFont(ofSize: 12)
        waitHint.textColor = .secondaryLabelColor
        for view in [badgeRow, translationLabel, noteLabel, wordsRow, waitRow] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(10, after: noteLabel)
        stack.setCustomSpacing(10, after: translationLabel)
        card.addSubview(stack)
        card.addSubview(sheen)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
        ])

        toolbar.radius = 9
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        for (index, button) in [speakButton, replaceButton, copyButton].enumerated() {
            button.frame.origin = NSPoint(x: 3 + CGFloat(index) * 30, y: 3)
            toolbar.addSubview(button)
        }
        speakButton.onClick = { [weak self] in self?.onSpeak?() }
        replaceButton.onClick = { [weak self] in self?.onReplace?() }
        copyButton.onClick = { [weak self] in self?.copyTranslation() }
        copyButton.toolTip = tr("复制译文")
        speakButton.toolTip = tr("朗读")
        replaceButton.toolTip = tr("替换原句")
        applyPalette()

        // 透明边不该挡住下面的正文：平时整个窗口不收鼠标，指针移到卡片上才收。
        let track: (NSEvent) -> Void = { [weak self] _ in self?.updateHover() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in track(event); return event }) {
            mouseMonitors.append(local)
        }
    }

    /// caret 是 AX 坐标（主屏左上原点）。内容没变时只挪位置，不重放动画。
    func show(_ next: OverlayContent, caret: CGRect) {
        let previous = content
        let wasVisible = isVisible
        self.caret = caret
        if next != previous || !wasVisible {
            content = next
            apply(next, previous: wasVisible ? previous : nil)
        }
        placeWindow()

        if !wasVisible {
            isVisible = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            pop(from: 0.55)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else if previous?.phase == .waiting, next.phase != .waiting {
            // 小胶囊撑开成整张卡片。
            pop(from: 0.92)
        }
        updateHover()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        content = nil
        hovering = false
        toolbarShown = false
        panel.ignoresMouseEvents = true
        toolbar.alphaValue = 0
        toolbar.isHidden = true
        stopReveal()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.dots.stop()
            self.sheen.stop()
            self.ring.setLevel(0, animated: false)
            self.glow.setLevel(0, animated: false)
        })
    }

    // MARK: - 内容

    private func apply(_ next: OverlayContent, previous: OverlayContent?) {
        let waiting = next.phase == .waiting
        waitRow.isHidden = !waiting
        waitHint.stringValue = next.hint ?? ""
        waitHint.isHidden = next.hint == nil
        if waiting { dots.start() } else { dots.stop() }

        badgeRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let badge = next.badge, !waiting {
            badgeRow.addArrangedSubview(Pill(badge, font: .systemFont(ofSize: 11, weight: .semibold), color: .systemGreen,
                                             insets: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6), radius: 5,
                                             fill: { NSColor.systemGreen.withAlphaComponent(0.14) }))
        }
        if let tag = next.tag {
            badgeRow.addArrangedSubview(Pill(tag, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor,
                                             insets: NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6), radius: 5,
                                             fill: { NSColor.labelColor.withAlphaComponent(0.07) }))
        }
        badgeRow.isHidden = badgeRow.arrangedSubviews.isEmpty

        updateReveal(next, previous: previous)
        translationLabel.isHidden = waiting || next.translation.isEmpty
        updateLabel(next)

        noteLabel.stringValue = next.note
        noteLabel.textColor = next.noteIsOK ? .systemGreen : .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = textWidth

        wordsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !waiting {
            for item in next.words {
                let chip = WordChip(item)
                chip.onClick = { [weak self] word in self?.onSpeakWord?(word) }
                chip.onRightClick = { [weak self] word in self?.onToggleKnown?(word) }
                wordsRow.addArrangedSubview(chip)
            }
        }
        updateExtras(animated: previous?.phase == .streaming && next.phase == .done)
        layoutCard()

        if next.phase == .refreshing, !translationLabel.isHidden {
            sheen.start(over: translationLabel, colors: palette.colors)
        } else {
            sheen.stop()
        }

        // 等待时流光最亮；出字和重新翻译时留一层；译文定下来就熄灭，变回普通细边。
        let animated = previous != nil
        let level: (ring: Float, glow: Float)
        switch next.phase {
        case .waiting: level = (1, 1)
        case .streaming, .refreshing: level = (0.6, 0.55)
        default: level = (0, 0)
        }
        ring.setLevel(level.ring, animated: animated)
        glow.setLevel(level.glow, animated: animated)
    }

    /// 说明和生词等整句打完再出来，免得卡片在出字时上下乱跳。
    private func updateExtras(animated: Bool) {
        guard let content else { return }
        let ready = content.phase != .waiting && !isRevealing
        noteLabel.isHidden = content.note.isEmpty || !ready
        wordsRow.isHidden = wordsRow.arrangedSubviews.isEmpty || !ready
        guard animated else { return }
        for view in [noteLabel, wordsRow] where !view.isHidden {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                view.animator().alphaValue = 1
            }
        }
    }

    private func layoutCard() {
        card.layoutSubtreeIfNeeded()
        // 卡片至少能放下悬停工具栏（94 宽，离右边 12，再留点左边距），不然短译文（「Done.」）时工具栏会伸出窗口被裁掉。
        var cardSize = card.fittingSize
        // 只有译文出来以后才会出现工具栏，等待中的小胶囊保持原来的大小。
        if content?.phase == .done { cardSize.width = max(cardSize.width, 124) }
        let cardFrame = NSRect(x: margin.left, y: margin.bottom, width: cardSize.width, height: cardSize.height)
        root.frame.size = NSSize(width: cardSize.width + margin.left + margin.right,
                                 height: cardSize.height + margin.top + margin.bottom)
        shadowHost.frame = cardFrame
        card.frame = shadowHost.bounds
        card.layoutSubtreeIfNeeded()
        for view in [glow, ring] {
            view.frame = root.bounds
            view.place(around: cardFrame, radius: radius)
        }
        toolbar.frame = NSRect(x: cardFrame.maxX - 12 - 94, y: cardFrame.maxY - 17, width: 94, height: 34)
    }

    private func placeWindow() {
        let size = NSSize(width: shadowHost.frame.width + margin.left + margin.right,
                          height: shadowHost.frame.height + margin.top + margin.bottom)
        let frame = NSRect(origin: origin(for: size, caret: caret), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func updateLabel(_ content: OverlayContent, now: CFTimeInterval = CACurrentMediaTime()) {
        let text = translationText(content, now: now)
        translationLabel.attributedStringValue = text
        // 短译文按实际宽度收窄，长译文到 textWidth 换行。
        translationLabel.preferredMaxLayoutWidth = min(ceil(text.size().width) + 4, textWidth)
    }

    private func translationText(_ content: OverlayContent, now: CFTimeInterval) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 15)
        let base: NSColor
        switch content.phase {
        case .stale, .message: base = .secondaryLabelColor
        case .refreshing: base = .tertiaryLabelColor
        default: base = .labelColor
        }
        let result = NSMutableAttributedString()
        if let diff = content.diff {
            var previous: Diff.Kind?
            for segment in diff {
                // 删掉的词紧跟着加上的词时隔一个空格，免得两个词粘在一起。
                if previous == .deleted, segment.kind == .inserted,
                   let first = segment.text.first, first.isLetter, let last = result.string.last, last.isLetter {
                    result.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                result.append(NSAttributedString(string: segment.text, attributes: diffAttributes(segment.kind, base: base, font: font)))
                previous = segment.kind
            }
            return result
        }

        guard revealing(content) else {
            result.append(NSAttributedString(string: content.translation, attributes: [.font: font, .foregroundColor: base]))
            return result
        }
        let shownText = String(revealText.prefix(shown))
        result.append(NSAttributedString(string: shownText, attributes: [.font: font, .foregroundColor: base]))
        var tint = palette.colors[0]
        var label = NSColor.labelColor
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = tint.usingColorSpace(.sRGB) ?? tint
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        // 只给还在褪色的那几个字单独上色：先从透明淡入，再从配色褪回正文色。
        // births 只记最后打出的那些字，与 shownText 的末尾对齐。
        var offset = (shownText as NSString).length
        var index = births.count
        for ch in shownText.reversed() {
            index -= 1
            guard index >= 0 else { break }
            let length = String(ch).utf16.count
            offset -= length
            let age = now - births[index]
            guard age < tintDuration else { break }
            let t = max(age, 0) / tintDuration
            let color = tint.blended(withFraction: 1 - pow(1 - t, 2), of: label) ?? label
            let alpha = min(max(age, 0) / fadeDuration, 1)
            result.addAttribute(.foregroundColor, value: color.withAlphaComponent(alpha), range: NSRange(location: offset, length: length))
        }
        return result
    }

    private func diffAttributes(_ kind: Diff.Kind, base: NSColor, font: NSFont) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .same:
            return [.font: font, .foregroundColor: base]
        case .deleted:
            return [.font: font, .foregroundColor: NSColor.secondaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.secondaryLabelColor]
        case .inserted:
            return [.font: font, .foregroundColor: NSColor.systemGreen,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.14),
                    .underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.systemGreen]
        }
    }

    // MARK: - 逐字出现

    private var isRevealing: Bool { shown < revealText.count }

    private func revealing(_ content: OverlayContent) -> Bool {
        content.diff == nil && [.streaming, .done].contains(content.phase) && revealTimer != nil
    }

    /// 模型的流是一截一截到的，直接显示就是一块块跳出来。这里把收到的译文当目标，按字匀速打出来，
    /// 积压越多打得越快，停手后一两百毫秒内追上。
    private func updateReveal(_ next: OverlayContent, previous: OverlayContent?) {
        let animate = !reduceMotion && next.diff == nil && [.streaming, .done].contains(next.phase)
            && (isRevealing || previous == nil && next.phase == .streaming
                || [.waiting, .streaming, .refreshing].contains(previous?.phase))
        guard animate else {
            stopReveal()
            revealText = next.translation
            shown = revealText.count
            return
        }
        if !next.translation.hasPrefix(String(revealText.prefix(shown))) {
            shown = 0
            births = []
        }
        revealText = next.translation
        guard revealTimer == nil else { return }
        lastStep = CACurrentMediaTime()
        carry = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepReveal() }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func stepReveal() {
        guard let content else { return stopReveal() }
        let now = CACurrentMediaTime()
        let backlog = revealText.count - shown
        carry += (30 + Double(backlog) * 2.5) * (now - lastStep)
        lastStep = now
        let count = min(Int(carry), backlog)
        carry -= Double(count)
        if count > 0 {
            births.append(contentsOf: Array(repeating: now, count: count))
            births.removeFirst(max(births.count - 200, 0))
            shown += count
        }
        let fading = births.last.map { now - $0 < tintDuration } ?? false
        if count == 0, !fading, !isRevealing {
            stopReveal()
            updateLabel(content, now: now)
            return
        }
        updateLabel(content, now: now)
        if count > 0 {
            if !isRevealing { updateExtras(animated: true) }
            layoutCard()
            placeWindow()
        }
    }

    private func stopReveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        births = []
        shown = revealText.count
    }

    // MARK: - 动画、悬停

    /// 从光标那一角弹出来：卡片整体从 scale 放大到原尺寸，带一点回弹。
    private func pop(from scale: CGFloat) {
        guard !reduceMotion, let layer = root.layer else { return }
        let card = shadowHost.frame
        let pivot = CGPoint(x: card.minX - layer.anchorPoint.x * layer.bounds.width,
                            y: (placedAbove ? card.minY : card.maxY) - layer.anchorPoint.y * layer.bounds.height)
        var from = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        from = CATransform3DScale(from, scale, scale, 1)
        from = CATransform3DTranslate(from, -pivot.x, -pivot.y, 0)
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.damping = 16
        spring.stiffness = 320
        spring.duration = spring.settlingDuration
        layer.sublayerTransform = CATransform3DIdentity
        layer.add(spring, forKey: "pop")
    }

    private func updateHover() {
        guard isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let cardRect = panel.convertToScreen(shadowHost.frame).insetBy(dx: -2, dy: -2)
        let canAct = content?.phase == .done
        let toolbarRect = panel.convertToScreen(toolbar.frame)
        let inside = pinHover || cardRect.contains(mouse) || (toolbarShown && toolbarRect.contains(mouse))
        hovering = inside
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        let show = inside && canAct
        guard show != toolbarShown else { return }
        toolbarShown = show
        // 隐藏时连点击也不收，免得透明的按钮被误点。
        if show { toolbar.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            toolbar.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.toolbarShown else { return }
            self.toolbar.isHidden = true
        })
    }

    private func copyTranslation() {
        guard let text = content?.translation, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func applyPalette() {
        let colors = palette.colors
        dots.setColors(colors)
        ring.setColors(colors)
        glow.setColors(colors)
        if content?.phase == .refreshing, !translationLabel.isHidden {
            sheen.start(over: translationLabel, colors: colors)
        }
    }

    /// 卡片放在光标下方，放不下就放上方；左右夹在屏幕可见区域里。窗口比卡片多出 margin。
    private func origin(for size: NSSize, caret: CGRect) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let caretBottom = primaryHeight - caret.maxY
        let caretTop = primaryHeight - caret.minY
        let probe = NSPoint(x: caret.minX, y: caretBottom)
        let visible = (NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let cardHeight = size.height - margin.top - margin.bottom
        let cardWidth = size.width - margin.left - margin.right

        var cardY = caretBottom - cardHeight - 6
        placedAbove = cardY < visible.minY
        if placedAbove { cardY = caretTop + 6 }
        let cardX = min(max(caret.minX, visible.minX + 4), visible.maxX - cardWidth - 4)
        return NSPoint(x: cardX - margin.left, y: cardY - margin.bottom)
    }
}
