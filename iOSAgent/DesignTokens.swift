import SwiftUI
import UIKit

// MARK: - Design Tokens
// 来源：swiftui-design-skill-2 (minimal/friendly) + swiftui-native-component-design-skill 的组件化规范。
// 统一颜色、字体、间距、圆角、阴影，避免各页面硬编码。
// v8.9.3：颜色已适配浅色/深色双模式，跟随系统或用户手动切换。

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

private func dynamicColor(dark: String, light: String) -> Color {
    Color(uiColor: UIColor(dynamicProvider: { traits in
        switch traits.userInterfaceStyle {
        case .dark: return UIColor(hex: dark)
        default: return UIColor(hex: light)
        }
    }))
}

extension Color {
    /// 页面背景：深色纯黑 / 浅色纯白
    static let appBackground = dynamicColor(dark: "000000", light: "FFFFFF")
    /// 卡片/浮层面背景
    static let appSurface = dynamicColor(dark: "1C1C1E", light: "F2F2F7")
    /// 输入框/浅灰填充
    static let appInputFill = dynamicColor(dark: "2C2C2E", light: "E5E5EA")
    /// 主文字
    static let appPrimaryText = dynamicColor(dark: "FFFFFF", light: "000000")
    /// 次文字
    static let appSecondaryText = Color(uiColor: UIColor(hex: "8E8E93"))
    /// 分隔线/微弱边框
    static let appSeparator = dynamicColor(dark: "38383A", light: "C6C6C8")
    /// 成功绿
    static let appSuccess = dynamicColor(dark: "10B981", light: "059669")
    /// 错误红
    static let appError = dynamicColor(dark: "FF453A", light: "DC2626")
    /// 微信品牌绿（两种模式同色）
    static let appWechat = Color(uiColor: UIColor(hex: "07C160"))

    /// 品牌强调色：WorkBuddy 绿
    static let brandAccent = Color(uiColor: UIColor(hex: "10B981"))

    /// 粉彩分类色（深色模式降低亮度，浅色模式明亮）
    static let pastelBlue = dynamicColor(dark: "2C4A5E", light: "E0F2FE")
    static let pastelGreen = dynamicColor(dark: "2D4A34", light: "DCFCE7")
    static let pastelOrange = dynamicColor(dark: "5A4A2A", light: "FFEDD5")
    static let pastelPurple = dynamicColor(dark: "4A4460", light: "F3E8FF")
    static let pastelPink = dynamicColor(dark: "5A3A44", light: "FCE7F3")
    static let pastelTeal = dynamicColor(dark: "2A4A4A", light: "CCFBF1")
    static let pastelGray = dynamicColor(dark: "3A3A3C", light: "E5E5EA")

    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
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
    /// 卡片阴影：深色用极淡白色勾边，浅色用淡黑色投影
    static var card: ShadowStyle {
        ShadowStyle(color: Color(uiColor: UIColor(dynamicProvider: { traits in
            switch traits.userInterfaceStyle {
            case .dark: return UIColor.white.withAlphaComponent(0.04)
            default: return UIColor.black.withAlphaComponent(0.06)
            }
        })), radius: 6, x: 0, y: 3)
    }
    /// 浮起阴影
    static var elevated: ShadowStyle {
        ShadowStyle(color: Color(uiColor: UIColor(dynamicProvider: { traits in
            switch traits.userInterfaceStyle {
            case .dark: return UIColor.white.withAlphaComponent(0.06)
            default: return UIColor.black.withAlphaComponent(0.08)
            }
        })), radius: 10, x: 0, y: 5)
    }
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
