import AppKit

/// 等待时边框流光、跳动小点、文字扫光用的配色。
enum Palette: String, CaseIterable {
    case aurora, ocean, sunset, mono

    var title: String {
        switch self {
        case .aurora: return tr("极光")
        case .ocean: return tr("冷蓝")
        case .sunset: return tr("日落")
        case .mono: return tr("单色")
        }
    }

    /// 四个色依次排在一圈锥形渐变上，首尾相接。
    var colors: [NSColor] {
        switch self {
        case .aurora: return [0x0A84FF, 0x7C5CFF, 0xFF4FA3, 0xFFB340].map(Palette.rgb)
        case .ocean: return [0x0A84FF, 0x30C8FF, 0x7C5CFF, 0x30C8FF].map(Palette.rgb)
        case .sunset: return [0xFF6A3D, 0xFF3D8B, 0xA35CFF, 0xFFB340].map(Palette.rgb)
        case .mono: return [0x0A84FF, 0x5EB0FF, 0x0A84FF, 0x5EB0FF].map(Palette.rgb)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
