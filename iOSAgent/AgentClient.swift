import Foundation
import UIKit

enum AgentError: Error, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请在设置中填写 API Key"
        case .invalidResponse: return "API 返回异常"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}

/// 云端 API 客户端：支持**工具调用循环**（agent 核心）。
/// 与 OpenMinis 用 iSH+CLI 让 LLM 调系统能力不同，这里直接在 Swift 里实现：
/// LLM 决定调用工具 → app 用 EventKit/HealthKit/通知执行 → 结果喂回 LLM → 生成自然语言回复。
@MainActor
final class AgentClient {
    static let shared = AgentClient()
    private let session = URLSession.shared
    private init() {}

    /// 运行 agent 循环：传入完整消息历史，返回更新后的历史 + 最终文本。
    /// image 仅由 ChatView 在新增的 user 消息上携带，此处不再重写历史。
    func run(messages: [StoredMessage], image: UIImage?, tools: [ToolSpec], activeSkills: [Skill] = []) async throws
        -> (messages: [StoredMessage], finalText: String) {

        let settings = SettingsStore.shared
        let base = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.apiKey
        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base.trimmingCharacters(in: ["/"]) + "/chat/completions") else {
            throw AgentError.invalidResponse
        }

        var out = messages
        if let image, let jpeg = image.jpegData(compressionQuality: 0.8),
           let lastUserIdx = out.indices.last(where: { out[$0].role == "user" }) {
            out[lastUserIdx].imageBase64 = jpeg.base64EncodedString()
        }

        let toolSchemas = tools.map { $0.schema }
        var finalText = ""

        for _ in 0..<8 {
            let reqMessages = buildAPIMessages(out, includeSystem: !out.contains { $0.role == "system" }, activeSkills: activeSkills)
            // 推理模型（kimi-k3/k2、deepseek-r1、o1/o3/o4、qwq 等）固定采样参数，
            // 传 temperature 会 400（"invalid temperature: only 1 is allowed"）；
            // 且官方已废弃 max_tokens、要求改用 max_completion_tokens。
            let lowerModel = model.lowercased()
            let isReasoning = lowerModel.contains("kimi-k3") || lowerModel.contains("kimi-k2")
                || lowerModel.contains("deepseek-r1") || lowerModel.contains("deepseek-reasoner")
                || lowerModel.hasPrefix("o1") || lowerModel.hasPrefix("o3") || lowerModel.hasPrefix("o4")
                || lowerModel.contains("qwq") || lowerModel.contains("reasoning") || lowerModel.contains("-thinking")
            var body: [String: Any] = [
                "model": model,
                "messages": reqMessages
            ]
            if isReasoning {
                body["max_completion_tokens"] = 8000
            } else {
                body["max_tokens"] = 2000
                body["temperature"] = 0.5
            }
            if !toolSchemas.isEmpty {
                body["tools"] = toolSchemas
                body["tool_choice"] = "auto"
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw AgentError.http(http.statusCode, msg)
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any] else {
                throw AgentError.invalidResponse
            }

            var asst = StoredMessage(role: "assistant", content: msg["content"] as? String ?? "")
            var toolCalls: [StoredToolCall] = []
            if let tcs = msg["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let id = tc["id"] as? String ?? UUID().uuidString
                    let fn = tc["function"] as? [String: Any]
                    toolCalls.append(StoredToolCall(
                        id: id,
                        name: fn?["name"] as? String ?? "",
                        arguments: fn?["arguments"] as? String ?? "{}"))
                }
            }
            if !toolCalls.isEmpty { asst.toolCalls = toolCalls }
            out.append(asst)

            if toolCalls.isEmpty {
                finalText = asst.content
                break
            }

            // 执行每个工具，并把结果追加为 tool 消息
            for tc in toolCalls {
                let args = parseArgs(tc.arguments)
                let result = await SystemTools.execute(tool: tc.name, call: args)
                let content = toolResultString(result)
                out.append(StoredMessage(role: "tool", content: content,
                                         toolCallId: tc.id, toolName: tc.name,
                                         fileURL: result.fileURL))
            }
        }

        if finalText.isEmpty, let last = out.last, last.role == "assistant" {
            finalText = last.content
        }
        return (out, finalText)
    }

    /// 单轮问答（供 App Intents 使用，不挂工具）
    func ask(_ text: String, image: UIImage? = nil) async throws -> String {
        let (_, final) = try await run(messages: [StoredMessage(role: "user", content: text)],
                                       image: image, tools: [])
        return final
    }

    /// 语音转文字：调用 OpenAI 兼容的 /audio/transcriptions
    func transcribe(audioURL: URL) async throws -> String {
        let settings = SettingsStore.shared
        let base = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = settings.apiKey
        let model = settings.sttModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.missingAPIKey }
        guard let url = URL(string: base + "/audio/transcriptions") else {
            throw AgentError.invalidResponse
        }

        let boundary = UUID().uuidString
        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8) ?? Data())
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AgentError.http(http.statusCode, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else {
            throw AgentError.invalidResponse
        }
        return text
    }

    // MARK: - 消息序列化

    private func buildAPIMessages(_ msgs: [StoredMessage], includeSystem: Bool, activeSkills: [Skill] = []) -> [[String: Any]] {
        var arr: [[String: Any]] = []
        if includeSystem {
            arr.append(["role": "system", "content": systemPrompt(activeSkills: activeSkills)])
        }
        for m in msgs {
            if m.role == "user", let b64 = m.imageBase64 {
                arr.append(["role": "user", "content": [
                    ["type": "text", "text": m.content],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]
                ]])
            } else if m.role == "assistant", let tcs = m.toolCalls {
                let tca = tcs.map { [
                    "id": $0.id, "type": "function",
                    "function": ["name": $0.name, "arguments": $0.arguments]
                ]}
                var item: [String: Any] = ["role": "assistant", "content": m.content, "tool_calls": tca]
                arr.append(item)
            } else if m.role == "tool" {
                arr.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            } else {
                arr.append(["role": m.role, "content": m.content])
            }
        }
        return arr
    }

    private func parseArgs(_ json: String) -> [String: AnyCodable] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else { return [:] }
        return dict
    }

    private func toolResultString(_ result: ToolResult) -> String {
        var base = result.success ? "[执行成功]" : "[执行失败]"
        base += " \(result.message)"
        if let data = result.data, let dataJson = try? JSONSerialization.data(withJSONObject: data.mapValues { $0.value }, options: .fragmentsAllowed),
           let s = String(data: dataJson, encoding: .utf8) {
            base += "\n数据：\(s)"
        }
        return base
    }

    // MARK: - 系统提示词

    private func systemPrompt(activeSkills: [Skill] = []) -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        let nowStr = fmt.string(from: now)

        var enabled: [String] = []
        if SettingsStore.shared.isEnabled("reminders") { enabled.append("提醒事项") }
        if SettingsStore.shared.isEnabled("calendar") { enabled.append("日历") }
        if SettingsStore.shared.isEnabled("health") { enabled.append("健康数据") }
        if SettingsStore.shared.isEnabled("contacts") { enabled.append("通讯录") }
        if SettingsStore.shared.isEnabled("location") { enabled.append("当前位置") }
        if SettingsStore.shared.isEnabled("clipboard") { enabled.append("剪贴板") }
        if SettingsStore.shared.isEnabled("photos") { enabled.append("相册") }
        if SettingsStore.shared.isEnabled("notifications") { enabled.append("闹钟/计时器/本地通知") }
        if SettingsStore.shared.isEnabled("device") { enabled.append("设备信息") }

        let capabilities = enabled.isEmpty ? "（当前未开启任何系统能力，请在设置中开启）" : enabled.joined(separator: "、")

        let custom = SettingsStore.shared.systemPrompt
        let customBlock = custom.isEmpty ? "" : "\n\n用户自定义补充：\(custom)"
        let skillBlock = buildSkillBlock(activeSkills)

        return """
        你是 同步，一个运行在 iPhone 上的本地 AI Agent。你可以调用系统工具帮用户完成操作。

        当前时间：\(nowStr)（东八区，北京时间）。系统时间已直接提供给你，不要向用户询问现在几点或今天几号，直接用当前时间计算。
        已开启的系统能力：\(capabilities)

        重要规则：
        1. 当用户请求设置闹钟、提醒、日程、倒计时等时间相关操作时，必须使用对应的工具函数，不要只回答文字。
        2. 工具选择必须精确：
           - “闹钟”“叫我起床”“N分钟后叫我” → 用 set_alarm（本地通知响铃）。
           - “提醒”“提醒我N分钟后做某事”“提醒事项” → 用 create_reminder（写入系统“提醒事项”App，会在锁屏/通知中心弹窗，即使 同步 被划掉也能收到）。
           - “日程”“会议”“约会” → 用 create_calendar_event（写入系统“日历”App）。
           - “计时”“倒计时” → 用 set_timer。
        3. 对于相对时间如“5分钟后”“半小时后”“明天早上9点”，直接使用 fire_in_minutes / due_in_minutes / duration_minutes；对于绝对时间使用 fire_at / due_at / start_at（ISO8601 格式，如 2026-08-26T09:00:00+08:00）。
        4. 用户说“提醒我N分钟后做某事”时，标题就是这件事本身（如“喝水”“拿快递”），不要再问用户标题。
        5. 如果用户没有指定标题，根据内容推断一个合适的标题。
        6. 工具执行后，根据结果用一句话向用户确认，不要暴露内部 ID 或 JSON。
        7. 如果某个能力未开启，引导用户到设置页开启，不要重复尝试调用失败工具。
        8. 当用户要求生成文件、PPT、写报告、整理数据时，使用 create_file（文本/md/csv）或 create_ppt（PPT）。先自己规划内容结构，再调用工具生成；生成后用一句话告诉用户文件已保存，可点击分享按钮导出。

        示例：
        用户：5分钟后提醒我喝水
        → 调用 create_reminder(title="喝水", due_in_minutes=5)

        用户：帮我设个明早7点的闹钟
        → 调用 set_alarm(title="起床闹钟", fire_at="\(formatISODate(now.addingTimeInterval(86400), hour: 7))")

        用户：10分钟后叫我
        → 调用 set_alarm(title="提醒", fire_in_minutes=10)

        \(customBlock)\(skillBlock)
        """
    }

    private func buildSkillBlock(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "" }
        let header = "\n\n当前激活的专业技能：\n" + skills.map { "- \($0.name)：\($0.description)" }.joined(separator: "\n") + "\n\n请严格遵循对应技能的规则。若用户需求与技能无关，则忽略技能规则，按常规方式回答。"
        let bodies = skills.map { "[\($0.name)]\n\($0.prompt)" }.joined(separator: "\n\n")
        return header + "\n\n" + bodies
    }

    private func formatISODate(_ date: Date, hour: Int) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = 0
        return fmt.string(from: Calendar.current.date(from: comps) ?? date)
    }
}

// MARK: - ToolSpec schema 转 OpenAI 可用字典

extension ToolSpec {
    var schema: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

// MARK: - Skill 框架

/// 技能定义：可插拔的领域知识 + 行为配方。
struct Skill: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let triggers: [String]
    let tools: [String]
    let prompt: String
}

/// 技能路由：根据用户输入匹配相关技能。
@MainActor
final class SkillRouter: ObservableObject {
    static let shared = SkillRouter()
    let allSkills: [Skill] = SkillRegistry.allSkills
    private init() {}

    func match(input: String) -> [Skill] {
        let lower = input.lowercased()
        let matched = allSkills.filter { skill in
            skill.triggers.contains { lower.contains($0.lowercased()) }
        }
        return Array(matched.prefix(2))
    }

    func match(messages: [StoredMessage]) -> [Skill] {
        guard let lastUser = messages.last(where: { $0.role == "user" })?.content else { return [] }
        return match(input: lastUser)
    }

    /// 解析 `@技能名` 前缀强制加载技能；无前缀返回 nil。
    func matchExplicit(input: String) -> [Skill]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return nil }
        let after = String(trimmed.dropFirst())
        let token = after.split(separator: " ", maxSplits: 1).first.map(String.init) ?? after
        let lower = token.lowercased()
        guard !lower.isEmpty else { return nil }
        let hit = allSkills.first { skill in
            let n = skill.name.lowercased()
            let id = skill.id.lowercased()
            return n.contains(lower) || lower.contains(n) || id.contains(lower) || lower.contains(id)
        }
        return hit.map { [$0] }
    }

    /// 去掉 `@技能名 ` 前缀，返回真正要发送的文本内容。
    func stripSkillPrefix(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@") else { return trimmed }
        let after = String(trimmed.dropFirst())
        let parts = after.split(separator: " ", maxSplits: 1)
        if parts.count > 1 {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }
}

/// v7.5 使用内嵌注册表；v7.6 改为 bundle 内 Skills/*.md 文件便于用户随时添加。
enum SkillRegistry {
    static let allSkills: [Skill] = [
        Skill(
            id: "wxoa-writer",
            name: "公众号写作",
            icon: "pencil.line",
            description: "按「忘仙」调性写公众号随笔",
            triggers: ["公众号", "文章", "写作", "忘仙", "东邪西毒", "随笔", "山丘", "三十到三十五"],
            tools: ["create_file"],
            prompt: """
            你是「忘仙」公众号主笔。当用户要求写公众号文章/随笔/诗歌时，严格遵循：
            1. 调性：洒脱、看淡红尘，可自然化用《东邪西毒》台词与李宗盛《山丘》意象，但禁止生硬堆砌。
            2. 主题聚焦：30-35岁生活感悟。
            3. 格式：随笔/诗歌体，≤300字，句式稍长、句间有衔接、有文学性。
            4. 禁用："一座又一座"等无效叠词。
            5. 必含关键词（自然融入）：初入江湖、翻山、山丘、白了头、醉生梦死、酒、回首、追求。
            6. 只输出文章正文，不加标题，不解释。
            7. 如用户要求保存，调用 create_file 写入 .md。
            """
        ),
        Skill(
            id: "ea-analyzer",
            name: "EA 解读",
            icon: "chart.line.uptrend.xyaxis",
            description: "解读 HJDS038OU 等 XAUUSD EA 逻辑",
            triggers: ["EA", "HJDS", "锁利", "keepRatio", "信号塔", "MT4", "XAUUSD", "量化", "马丁", "止盈", "止损", "爆仓"],
            tools: ["create_file"],
            prompt: """
            你是 XAUUSD/MT4 量化交易专家，精通 HJDS038OU 策略。回答必须基于源码+日志+交易记录交叉分析，禁用笼统定论，每条结论必须有具体数字/逻辑支撑。
            核心参数：MagicNumber=20045，ADXRangeThreshold=18.0，MaxStopLossPercent=12。
            锁利模型：10级，keepRatio Lv1=22%、Lv2=35%、Lv3=48%、Lv4=58%、Lv5=52%、Lv6=55%、Lv7=60%、Lv8=65%、Lv9=70%、Lv10=75%；Lv10含max-8保护；由highestProfit驱动。
            关键修复点：
            - signal strength 枚举 EXTREME=0、STRONG=1、MEDIUM=2、WEAK=3；EMA过滤比较应为 <=。
            - 强趋势（signal≤STRONG + H1=YES + D1=YES）跳过距离检查，允许追涨。
            - EMA冲突时跳过市价单，改用pending order。
            - lock mode只在lockLevel变化时更新SL，加lastLockLevel变量。
            - DailyHardStop=10U应移除或调至999。
            若需要整理结论或生成报告，调用 create_file。
            """
        ),
        Skill(
            id: "domain-picker",
            name: "域名选品",
            icon: "globe",
            description: "按规则筛选短域名",
            triggers: ["域名", "选品", "expireddomains", "Whoxy", "Whois", "后缀", ".com", ".cc", ".co", ".cm", ".net", ".cn", ".org", ".pw", ".ai", ".io"],
            tools: ["create_file"],
            prompt: """
            你是短域名选品助手。规则：
            1. 优先纯字母、无符号、短到长。
            2. 后缀优先级：.com/.cc/.co/.cm/.net/.cn/.org/.pw/.ai/.io。
            3. 默认预算 ≤5000 RMB；若用户没给预算/后缀/用途，先反问再输出。
            4. 输出格式：序号、域名、后缀、长度、估值理由、风险提醒。
            5. 注意 Whoxy 免费列表存在到期日续费误区，提醒用户以注册商数据为准。
            如需保存候选列表，调用 create_file 输出 csv/md。
            """
        )
    ]
}
