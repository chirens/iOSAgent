import SwiftUI

// MARK: - Design Tokens
// 来源：swiftui-design-skill-2 (minimal/friendly) + swiftui-native-component-design-skill 的组件化规范。
// 统一颜色、字体、间距、圆角、阴影，避免各页面硬编码。

extension Color {
    /// 页面背景：#F9F9F9
    static let appBackground = Color(hex: "F9F9F9")
    /// 卡片/浮层面背景：#FFFFFF
    static let appSurface = Color(hex: "FFFFFF")
    /// 输入框/浅灰填充：#F5F5F5
    static let appInputFill = Color(hex: "F5F5F5")
    /// 主文字：#2D2D2D
    static let appPrimaryText = Color(hex: "2D2D2D")
    /// 次文字：#8E8E93
    static let appSecondaryText = Color(hex: "8E8E93")
    /// 分隔线/微弱边框：#E5E5EA
    static let appSeparator = Color(hex: "E5E5EA")
    /// 成功绿
    static let appSuccess = Color(hex: "34C759")
    /// 错误红
    static let appError = Color(hex: "FF3B30")

    /// 品牌强调色：呼应 App 图标蓝色圆环
    static let brandAccent = Color(red: 0.10, green: 0.42, blue: 0.96)

    /// 粉彩分类色（柔和，低饱和度）
    static let pastelBlue = Color(hex: "C6E7FF")
    static let pastelGreen = Color(hex: "E1EACD")
    static let pastelOrange = Color(hex: "FFDDAE")
    static let pastelPurple = Color(hex: "DCD6F7")
    static let pastelPink = Color(hex: "FFD6E0")
    static let pastelTeal = Color(hex: "C8F0F0")
    static let pastelGray = Color(hex: "E8E8ED")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

// MARK: - Typography

extension Font {
    /// Display 34pt bold
    static func appDisplay() -> Font { .system(size: 34, weight: .bold, design: .rounded) }
    /// Title 1：24pt semibold
    static func appTitle1() -> Font { .system(size: 24, weight: .semibold, design: .rounded) }
    /// Title 2：20pt semibold
    static func appTitle2() -> Font { .system(size: 20, weight: .semibold, design: .rounded) }
    /// Title 3：18pt medium
    static func appTitle3() -> Font { .system(size: 18, weight: .medium, design: .rounded) }
    /// Body：16pt medium
    static func appBody() -> Font { .system(size: 16, weight: .medium, design: .rounded) }
    /// Subheadline：15pt medium
    static func appSubheadline() -> Font { .system(size: 15, weight: .medium, design: .rounded) }
    /// Caption：13pt medium
    static func appCaption() -> Font { .system(size: 13, weight: .medium, design: .rounded) }
    /// Caption 2：12pt medium
    static func appCaption2() -> Font { .system(size: 12, weight: .medium, design: .rounded) }
    /// Micro：11pt semibold
    static func appMicro() -> Font { .system(size: 11, weight: .semibold, design: .rounded) }
}

// MARK: - Layout

enum AppSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum AppRadius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 18
    static let xl: CGFloat = 22
}

enum AppShadow {
    /// 卡片标准阴影
    static let card = ShadowStyle(color: .black.opacity(0.04), radius: 8, x: 0, y: 4)
    /// 浮起阴影
    static let elevated = ShadowStyle(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension View {
    func appCardShadow(_ style: ShadowStyle = AppShadow.card) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
