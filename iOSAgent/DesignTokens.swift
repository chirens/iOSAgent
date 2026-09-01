import SwiftUI

// MARK: - Design Tokens
// 来源：swiftui-design-skill-2 (minimal/friendly) + swiftui-native-component-design-skill 的组件化规范。
// 统一颜色、字体、间距、圆角、阴影，避免各页面硬编码。

extension Color {
    /// 页面背景：纯黑
    static let appBackground = Color(hex: "000000")
    /// 卡片/浮层面背景：iOS 系统深灰
    static let appSurface = Color(hex: "1C1C1E")
    /// 输入框/浅灰填充：比卡片稍亮
    static let appInputFill = Color(hex: "2C2C2E")
    /// 主文字：纯白
    static let appPrimaryText = Color(hex: "FFFFFF")
    /// 次文字：系统灰
    static let appSecondaryText = Color(hex: "8E8E93")
    /// 分隔线/微弱边框：深灰
    static let appSeparator = Color(hex: "38383A")
    /// 成功绿（WorkBuddy 绿）
    static let appSuccess = Color(hex: "10B981")
    /// 错误红（暗红）
    static let appError = Color(hex: "FF453A")

    /// 品牌强调色：WorkBuddy 绿（呼应截图中的标签/同步状态绿）
    static let brandAccent = Color(hex: "10B981")

    /// 粉彩分类色（暗黑模式下降低亮度）
    static let pastelBlue = Color(hex: "2C4A5E")
    static let pastelGreen = Color(hex: "2D4A34")
    static let pastelOrange = Color(hex: "5A4A2A")
    static let pastelPurple = Color(hex: "4A4460")
    static let pastelPink = Color(hex: "5A3A44")
    static let pastelTeal = Color(hex: "2A4A4A")
    static let pastelGray = Color(hex: "3A3A3C")

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
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 14
    static let xxl: CGFloat = 16
    static let xxxl: CGFloat = 20
}

enum AppRadius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 18
    static let xl: CGFloat = 22
}

enum AppShadow {
    /// 暗黑模式下卡片阴影用极淡白色勾边，避免黑底发灰
    static let card = ShadowStyle(color: .white.opacity(0.04), radius: 6, x: 0, y: 3)
    /// 浮起阴影
    static let elevated = ShadowStyle(color: .white.opacity(0.06), radius: 10, x: 0, y: 5)
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
