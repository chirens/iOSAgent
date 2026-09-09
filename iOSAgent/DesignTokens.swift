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
    // MARK: - 背景 / 卡片（v9.0.12 全部改用 Apple HIG 系统色）
    //
    // 之前几版我用自定义 hex（#E0E0E0 / #FFFFFF 等）自己拼"灰底白卡"层级，
    // 但 iOS 17/18 NavigationStack 内部会用 `.systemBackground` 覆盖 ScrollView 的 `.background()`，
    // 导致用户实际看到的是 iOS 默认（白底 + 浅灰分组 #F2F2F7），跟我设计意图完全不同。
    //
    // Apple 自家 Settings / Mail / Notes / Files 的标准就是：
    //   - 页面底色：systemGroupedBackground          (#F2F2F7 浅 / #000000 深)
    //   - 卡片/分组：secondarySystemGroupedBackground (#FFFFFF 浅 / #1C1C1E 深)
    //   - 卡片浮起感：纯靠颜色差，不靠阴影
    // 直接用系统色，SwiftUI 会自动适配深浅、永不被覆盖。
    static let appBackground = Color(.systemGroupedBackground)
    static let appSurface = Color(.secondarySystemGroupedBackground)
    /// 输入框/浅灰填充：tertiarySystemFill 是 Apple 标准的"低层级填充色"
    static let appInputFill = Color(.tertiarySystemFill)
    /// 主文字：直接用系统 label
    static let appPrimaryText = Color(.label)
    /// 次文字：直接用系统 secondaryLabel（#3C3C4399 浅 / #EBEBF599 深，60% 不透明度）
    static let appSecondaryText = Color.secondary
    /// 分隔线：opaqueSeparator 比 separator 更实，跟 Apple Mail 列表一致
    static let appSeparator = Color(.opaqueSeparator)
    /// 成功绿
    static let appSuccess = dynamicColor(dark: "10B981", light: "059669")
    /// 错误红
    static let appError = dynamicColor(dark: "FF453A", light: "DC2626")
    /// 微信品牌绿（两种模式同色）
    static let appWechat = Color(uiColor: UIColor(hex: "07C160"))

    /// 品牌强调色：WorkBuddy 绿
    static let brandAccent = Color(uiColor: UIColor(hex: "10B981"))

    // MARK: - 分类图标色（v9.0.12 重写：放弃 pastel 浅色块，Apple 标准做法）
    //
    // 之前 pastel 系列（#BFDBFE / #BBF7D0 等）做图标背景 + 同色 icon，
    // 在白底 #FFFFFF 上几乎透明不可见（用户报 2 次）。
    //
    // Apple Mail / Reminders / Settings 的标准做法：
    //   1. icon 本身用全饱和的 `.blue / .green / .orange / .purple / .pink / .teal / .red` SF Symbol
    //   2. 背景完全透明（或用 `.tertiarySystemFill` 极淡填充）
    //   3. icon 字号 18+，weight semibold，symbolRenderingMode .hierarchical 多级灰度
    //
    // 这里保留同名 enum 方便迁移，但每个图标色都是全饱和的 SwiftUI 系统色：
    static let pastelBlue   = Color.blue
    static let pastelGreen  = Color.green
    static let pastelOrange = Color.orange
    static let pastelPurple = Color.purple
    static let pastelPink   = Color.pink
    static let pastelTeal   = Color.teal
    static let pastelRed    = Color.red
    static let pastelGray   = Color(.systemGray)

    /// 图标饱和版（v9.0.11 引入，v9.0.12 废弃合并到 pastel*）
    /// 保留别名给旧调用点，避免全量替换报错
    static let pastelBlueFG = Color.blue
    static let pastelGreenFG = Color.green
    static let pastelOrangeFG = Color.orange
    static let pastelPurpleFG = Color.purple
    static let pastelPinkFG = Color.pink
    static let pastelTealFG = Color.teal
    static let pastelGrayFG = Color(.systemGray)

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
    /// 卡片阴影（v9.0.12 完全去掉）：Apple HIG 的 grouped 布局完全靠颜色差（#F2F2F7 底 + #FFFFFF 卡）
    /// 表达浮起感，不加阴影——加阴影反而让卡片像"铁板"。这里把 card / elevated 都改成 .clear。
    static var card: ShadowStyle { ShadowStyle(color: .clear, radius: 0, x: 0, y: 0) }
    static var elevated: ShadowStyle { ShadowStyle(color: .clear, radius: 0, x: 0, y: 0) }
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
