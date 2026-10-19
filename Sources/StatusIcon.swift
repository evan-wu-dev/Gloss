import AppKit

/// 菜单栏图标：两行字（上长下短的粗横线）之间一道手写弧线，和应用图标同一个造型。
/// 不放文字，任何语言的用户都看得懂。模板图，深浅色菜单栏由系统着色。
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            for (y, end) in [(4.2, 17.0), (14.2, 10.5)] {
                let bar = NSBezierPath()
                bar.move(to: NSPoint(x: 3, y: y))
                bar.line(to: NSPoint(x: end, y: y))
                bar.lineWidth = 2.3
                bar.lineCapStyle = .round
                bar.stroke()
            }
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 3, y: 10.2))
            wave.curve(to: NSPoint(x: 7.6, y: 7.4), controlPoint1: NSPoint(x: 4.6, y: 8.6), controlPoint2: NSPoint(x: 6.4, y: 6.6))
            wave.curve(to: NSPoint(x: 9.4, y: 10.4), controlPoint1: NSPoint(x: 8.8, y: 8.2), controlPoint2: NSPoint(x: 7.6, y: 10.8))
            wave.curve(to: NSPoint(x: 12.6, y: 8.8), controlPoint1: NSPoint(x: 10.8, y: 10.0), controlPoint2: NSPoint(x: 11.4, y: 8.6))
            wave.curve(to: NSPoint(x: 17, y: 8.0), controlPoint1: NSPoint(x: 13.8, y: 9.0), controlPoint2: NSPoint(x: 15.4, y: 8.8))
            wave.lineWidth = 1.5
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Gloss"
        return image
    }()

    /// 引导结束时让菜单栏图标亮一下：背后一条流动的彩带，上面是白色图标，约 3 秒后淡掉。
    static func celebrate(_ button: NSStatusBarButton, palette: Palette) {
        button.wantsLayer = true
        guard let layer = button.layer, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else { return }
        let glow = CALayer()
        glow.frame = button.bounds.insetBy(dx: 0, dy: 2)
        glow.cornerRadius = 6
        glow.masksToBounds = true
        glow.opacity = 0
        // 横向流动的彩带：四种颜色同时排在图标背后、一直往左流。绕中心转的锥形渐变在这么扁的区域里
        // 同一时刻只露出一两种颜色，看起来像单色在闪。颜色重复两遍，平移一个周期正好接上，循环无缝。
        let gradient = CAGradientLayer()
        let colors = palette.colors + palette.colors.prefix(1)
        gradient.colors = (colors + colors.dropFirst()).map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let period = glow.bounds.width * 1.05
        gradient.frame = CGRect(x: 0, y: 0, width: period * 2, height: glow.bounds.height)
        glow.addSublayer(gradient)

        let flow = CABasicAnimation(keyPath: "position.x")
        flow.fromValue = gradient.position.x
        flow.toValue = gradient.position.x - period
        flow.duration = 1.4
        flow.repeatCount = .infinity
        gradient.add(flow, forKey: "flow")

        // 自己加的图层会画在按钮图标上面，所以流光上面再放一个白色图标。
        let icon = CALayer()
        let white = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        icon.contents = white
        icon.contentsScale = button.window?.backingScaleFactor ?? 2
        icon.frame = CGRect(x: glow.bounds.midX - image.size.width / 2, y: glow.bounds.midY - image.size.height / 2,
                            width: image.size.width, height: image.size.height)
        glow.addSublayer(icon)
        layer.addSublayer(glow)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.75, 1]
        fade.duration = 3
        glow.add(fade, forKey: "fade")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.12, 1, 1]
        pop.keyTimes = [0, 0.12, 0.2, 1]
        pop.duration = 3
        glow.add(pop, forKey: "pop")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { glow.removeFromSuperlayer() }
    }
}

/// 菜单第一行：「边打边译」加当前语言和模型，右侧一个开关。
/// 开关自己画：菜单窗口不是 key 窗口，系统的 NSSwitch 在里面打开时也是灰的，看不出开没开。
final class SwitchMenuView: NSView {
    private let onToggle: (Bool) -> Void
    private let toggle: MenuSwitch

    init(title: String, subtitle: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        toggle = MenuSwitch(isOn: isOn)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        autoresizingMask = .width

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        toggle.onChange = { [weak self] on in self?.onToggle(on) }

        for view in [text, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 16),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 32),
            toggle.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// 开为系统强调色、关为灰色的小开关，点一下切换，圆钮带滑动动画。
private final class MenuSwitch: NSView {
    var onChange: ((Bool) -> Void)?
    private var isOn: Bool
    private let knob = CALayer()

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
        wantsLayer = true
        layer?.addSublayer(knob)
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(tr("字里行间"))
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = isOn ? NSColor.controlAccentColor.cgColor : NSColor.tertiaryLabelColor.cgColor
        let size = bounds.height - 4
        knob.cornerRadius = size / 2
        knob.frame = CGRect(x: isOn ? bounds.width - size - 2 : 2, y: 2, width: size, height: size)
        setAccessibilityValue(isOn)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        isOn.toggle()
        needsDisplay = true
        onChange?(isOn)
    }
}
