import AppIntents
import UIKit

/// 通过 URL Scheme 打开其他 App。
/// iOS 上第三方 app 操作别家 app 的合法通道之一（打开 + 传参，而非坐标点击）。
struct OpenAppIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 App（URL Scheme）"
    static var description = IntentDescription("通过 URL Scheme 打开其他 App，例如 maps:// 或 https://")

    @Parameter(title: "URL Scheme", description: "要打开的 URL，例如 tel://10086 或 maps://")
    var urlScheme: String

    init() {}
    init(urlScheme: String) { self.urlScheme = urlScheme }

    func perform() async throws -> some IntentResult {
        guard let url = URL(string: urlScheme) else {
            throw $urlScheme.needsValueError("请输入有效的 URL Scheme")
        }
        let canOpen = await MainActor.run { UIApplication.shared.canOpenURL(url) }
        guard canOpen else {
            throw $urlScheme.needsValueError("设备无法打开该 URL（App 未安装或无权限）")
        }
        await MainActor.run { UIApplication.shared.open(url) }
        return .result()
    }
}

/// 把问题发给已配置的云端模型并取回回答。
/// 让 Siri / 快捷指令也能调你的 Agent（系统级入口）。
struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "询问 Agent"
    static var description = IntentDescription("把问题发给已配置的云端模型并取回回答")

    @Parameter(title: "问题")
    var question: String

    init() {}
    init(question: String) { self.question = question }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = try await AgentClient.shared.ask(question)
        return .result(dialog: IntentDialog(stringLiteral: answer))
    }
}
