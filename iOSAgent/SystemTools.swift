import Foundation
import SwiftUI
import EventKit
import HealthKit
import Contacts
import CoreLocation
import Photos
import UserNotifications
import UIKit

/// OpenAI / DeepSeek function calling schema
struct ToolSpec: Codable {
    let type: String
    let function: FunctionSpec
}

struct FunctionSpec: Codable {
    let name: String
    let description: String
    let parameters: ParametersSchema

    init(name: String, description: String, parameters: [String: ParameterSpec], required: [String]) {
        self.name = name
        self.description = description
        self.parameters = ParametersSchema(properties: parameters, required: required)
    }
}

struct ParametersSchema: Codable {
    let type = "object"
    let properties: [String: ParameterSpec]
    let required: [String]
}

struct ParameterSpec: Codable {
    let type: String
    let description: String
    let enumValues: [String]?
    private enum CodingKeys: String, CodingKey {
        case type, description, enumValues = "enum"
    }
    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

struct ToolCall: Codable {
    let name: String
    let arguments: [String: AnyCodable]
}

struct ToolResult: Codable {
    let success: Bool
    let message: String
    let data: [String: AnyCodable]?
    let fileURL: URL?

    init(success: Bool, message: String, data: [String: AnyCodable]? = nil, fileURL: URL? = nil) {
        self.success = success
        self.message = message
        self.data = data
        self.fileURL = fileURL
    }
}

/// 万能包装，让 [String: Any] 可以 Codable
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { value = "" }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? Bool { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double { try container.encode(v) }
        else if let v = value as? String { try container.encode(v) }
        else if let v = value as? [Any] { try container.encode(v.map { AnyCodable($0) }) }
        else if let v = value as? [String: Any] { try container.encode(v.mapValues { AnyCodable($0) }) }
        else { try container.encode(String(describing: value)) }
    }
}

@MainActor
final class SystemTools {

    // MARK: - 工具清单
    // 核心工具：生成 / 连接类，不触碰隐私权限，始终下发给模型（含 web_request 万能连接器）
    // 核心工具：生成 / 连接类，不触碰隐私权限，始终下发给模型（含 web_request 万能连接器）
    static let coreTools: [ToolSpec] = [
        ToolSpec(type: "function", function: FunctionSpec(
            name: "get_current_time",
            description: "获取当前系统时间和日期。当用户提到相对时间（如“5分钟后”“明天”）而你又需要确认时间基准时调用。",
            parameters: [:],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "create_file",
            description: "在 App 文档目录创建一个文本文件（txt/md/html/csv/json）。",
            parameters: [
                "filename": ParameterSpec(type: "string", description: "文件名，必须包含扩展名，如 notes.md、data.csv。"),
                "content": ParameterSpec(type: "string", description: "文件内容。")
            ],
            required: ["filename", "content"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "create_ppt",
            description: "根据标题和每页要点生成 .pptx 文件并保存到 App 文档目录，可在聊天中分享。",
            parameters: [
                "title": ParameterSpec(type: "string", description: "PPT 标题，也会作为文件名（无需 .pptx 后缀）。"),
                "slides": ParameterSpec(type: "array", description: "幻灯片数组，每项为对象：{title: 本页标题, bullets: [要点1, 要点2, ...]}")
            ],
            required: ["title", "slides"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "web_request",
            description: "向任意 HTTP(S) 接口发起请求并返回结果，用于调用外部服务（如 dashi-ppt、图像/视频/音频生成 API、Webhook 等）。返回状态码与响应体；若响应为二进制文件（或指定 save_as），自动保存到 App 文档并可在聊天中打开/分享。这是【始终可用】的“万能连接器”：无论是否开启系统权限都能调用。仅在用户明确要求调用某外部服务时使用，密钥放 headers，不要写进回复文本。",
            parameters: [
                "method": ParameterSpec(type: "string", description: "请求方法 GET/POST/PUT/DELETE/PATCH，默认 GET。"),
                "url": ParameterSpec(type: "string", description: "完整请求地址，必须 http(s) 开头。"),
                "headers": ParameterSpec(type: "string", description: "请求头 JSON 字符串，如 {\"Authorization\":\"Bearer xxx\",\"Content-Type\":\"application/json\"}，可省略。"),
                "body": ParameterSpec(type: "string", description: "请求体，通常为 JSON 字符串；GET 一般省略。"),
                "save_as": ParameterSpec(type: "string", description: "可选，保存为文件的文件名（含扩展名，如 result.pptx / img.png / clip.mp3）。指定后即使返回文本也会存为文件；不指定时按 Content-Type 自动判断二进制并保存。")
            ],
            required: ["url"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "open_url",
            description: "用系统打开一个 URL 或启动支持 URL Scheme 的 App。",
            parameters: ["url": ParameterSpec(type: "string", description: "URL 或 scheme，如 weixin://、https://example.com、tel://10086")],
            required: ["url"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "get_clipboard",
            description: "读取剪贴板文本。",
            parameters: [:],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "set_clipboard",
            description: "写入文本到剪贴板。",
            parameters: ["text": ParameterSpec(type: "string", description: "要写入的文本。")],
            required: ["text"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "device_info",
            description: "获取设备信息：型号、系统版本、电量、存储等。",
            parameters: [:],
            required: []
        ))
    ]

    // 隐私 / 系统权限类工具：仅在用户于设置中开启任一系统能力后下发（anyToolEnabled）
    static let systemTools: [ToolSpec] = [
        ToolSpec(type: "function", function: FunctionSpec(
            name: "set_alarm",
            description: "设置一个闹钟，到点以本地通知响铃/弹窗。用户说“叫我起床”“N分钟后叫我”“明早7点叫我”时使用。不会写入系统提醒事项。",
            parameters: [
                "fire_in_minutes": ParameterSpec(type: "integer", description: "相对几分钟后触发。若用户说“5分钟后叫我”则填5。"),
                "fire_at": ParameterSpec(type: "string", description: "绝对触发时间 ISO8601（如 2026-08-26T09:00:00+08:00）。当用户提供明确时间如“明早9点”时使用。"),
                "title": ParameterSpec(type: "string", description: "闹钟标题，如“起床”“会议提醒”。")
            ],
            required: ["title"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "set_timer",
            description: "设置一个倒计时器。用户说“计时5分钟”“5分钟倒计时”时使用。",
            parameters: [
                "duration_minutes": ParameterSpec(type: "integer", description: "倒计时分钟数。"),
                "duration_seconds": ParameterSpec(type: "integer", description: "倒计时秒数。"),
                "label": ParameterSpec(type: "string", description: "计时器标签，如“煮蛋”。")
            ],
            required: ["duration_minutes"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "list_alarms",
            description: "列出当前已设置的所有闹钟/计时器/本地通知。",
            parameters: [:],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "cancel_alarm",
            description: "取消指定 id 的闹钟或取消全部闹钟。",
            parameters: [
                "id": ParameterSpec(type: "string", description: "要取消的通知 id。"),
                "cancel_all": ParameterSpec(type: "boolean", description: "是否取消全部。")
            ],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "create_reminder",
            description: "在系统“提醒事项”App 中创建一条提醒。用户说“提醒我N分钟后做某事”“提醒我拿快递”“明天提醒我交报告”时使用。会出现在系统提醒事项和通知中心，即使 同步 不在后台也能收到。",
            parameters: [
                "title": ParameterSpec(type: "string", description: "提醒标题，即要做的事情，如“喝水”“拿快递”。"),
                "notes": ParameterSpec(type: "string", description: "备注。"),
                "due_in_minutes": ParameterSpec(type: "integer", description: "相对几分钟后到期。"),
                "due_at": ParameterSpec(type: "string", description: "绝对到期时间 ISO8601。")
            ],
            required: ["title"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "list_reminders",
            description: "列出未来 N 条系统提醒事项中的未完成任务。",
            parameters: ["limit": ParameterSpec(type: "integer", description: "最多返回条数，默认20。")],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "complete_reminder",
            description: "把指定 id 的提醒事项标记为完成。",
            parameters: ["id": ParameterSpec(type: "string", description: "提醒 id。")],
            required: ["id"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "create_calendar_event",
            description: "在系统“日历”中创建日程。用户说“周五下午3点开会”“明天上午10点日程”时使用。",
            parameters: [
                "title": ParameterSpec(type: "string", description: "事件标题。"),
                "start_at": ParameterSpec(type: "string", description: "开始时间 ISO8601。"),
                "end_at": ParameterSpec(type: "string", description: "结束时间 ISO8601。"),
                "notes": ParameterSpec(type: "string", description: "备注。"),
                "calendar_name": ParameterSpec(type: "string", description: "日历名称，如“iCloud”、“工作”。默认主日历。")
            ],
            required: ["title", "start_at"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "list_events",
            description: "列出从今天起 N 天内的日历事件。",
            parameters: ["days": ParameterSpec(type: "integer", description: "查看未来几天，默认7。")],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "read_health",
            description: "读取健康数据。支持的指标：steps(步数)、heart_rate(心率)、sleep(睡眠时长分钟)、active_energy(活动能量千卡)、distance(步行距离公里)、body_mass(体重kg)。",
            parameters: [
                "metric": ParameterSpec(type: "string", description: "指标名", enumValues: ["steps", "heart_rate", "sleep", "active_energy", "distance", "body_mass"]),
                "days": ParameterSpec(type: "integer", description: "过去多少天，默认7。")
            ],
            required: ["metric"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "search_contacts",
            description: "搜索通讯录联系人。",
            parameters: ["name": ParameterSpec(type: "string", description: "姓名关键词。")],
            required: ["name"]
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "get_location",
            description: "获取当前位置（经纬度与城市名）。",
            parameters: [:],
            required: []
        )),
        ToolSpec(type: "function", function: FunctionSpec(
            name: "list_photos",
            description: "获取相册最近 N 张图片。",
            parameters: ["limit": ParameterSpec(type: "integer", description: "最多返回条数，默认5。")],
            required: []
        ))
    ]

    /// 实际下发给模型的工具清单：核心工具始终包含；隐私 / 系统权限类工具需用户授权后追加
    static var activeTools: [ToolSpec] {
        var t = coreTools
        if SettingsStore.shared.anyToolEnabled {
            t.append(contentsOf: systemTools)
        }
        return t
    }

    static func execute(tool name: String, call: [String: AnyCodable]) async -> ToolResult {
        do {
            switch name {
            case "get_current_time": return currentTime(call)
            case "set_alarm": return try await setAlarm(call)
            case "set_timer": return try await setTimer(call)
            case "list_alarms": return try await listAlarms(call)
            case "cancel_alarm": return try await cancelAlarm(call)
            case "create_reminder": return try await createReminder(call)
            case "list_reminders": return try await listReminders(call)
            case "complete_reminder": return try await completeReminder(call)
            case "create_calendar_event": return try await createCalendarEvent(call)
            case "list_events": return try await listEvents(call)
            case "read_health": return try await readHealth(call)
            case "search_contacts": return try await searchContacts(call)
            case "get_location": return try await getLocation(call)
            case "get_clipboard": return try await getClipboard(call)
            case "set_clipboard": return try await setClipboard(call)
            case "list_photos": return try await listPhotos(call)
            case "open_url": return try await openURL(call)
            case "device_info": return try await deviceInfo(call)
            case "create_file": return try await createFile(call)
            case "create_ppt": return try await createPPT(call)
            case "web_request": return try await webRequest(call)
            default: return ToolResult(success: false, message: "未知工具 \(name)", data: nil)
            }
        } catch {
            return ToolResult(success: false, message: "执行失败：\(error.localizedDescription)", data: nil)
        }
    }

    // MARK: - Current time

    private static func currentTime(_ call: [String: AnyCodable]) -> ToolResult {
        let now = Date()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let iso = fmt.string(from: now)
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        let readable = df.string(from: now)
        return ToolResult(success: true, message: "当前时间：\(readable)", data: [
            "iso": AnyCodable(iso),
            "readable": AnyCodable(readable),
            "timezone": AnyCodable("Asia/Shanghai")
        ])
    }

    // MARK: - Alarms / Timers

    private static func setAlarm(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("notifications") else { return needEnable("通知/闹钟") }
        let title = string(call, "title") ?? "闹钟"
        let body = string(call, "label") ?? "时间到了"
        let fireAt: Date
        if let mins = int(call, "fire_in_minutes"), mins > 0 {
            fireAt = Date().addingTimeInterval(TimeInterval(mins) * 60)
        } else if let iso = string(call, "fire_at"), let d = parseISO(iso) {
            fireAt = d
        } else {
            return ToolResult(success: false, message: "需要提供 fire_in_minutes 或 fire_at", data: nil)
        }
        let id = try await NotificationsManager.shared.scheduleAlarm(title: title, body: body, fireAt: fireAt)
        return ToolResult(success: true, message: "已设置闹钟：\(formatDate(fireAt))",
                          data: ["id": AnyCodable(id), "fire_at": AnyCodable(formatDate(fireAt)), "title": AnyCodable(title)])
    }

    private static func setTimer(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("notifications") else { return needEnable("通知/闹钟") }
        let minutes = int(call, "duration_minutes") ?? 0
        let seconds = int(call, "duration_seconds") ?? 0
        let total = TimeInterval(minutes * 60 + seconds)
        guard total > 0 else { return ToolResult(success: false, message: "倒计时时间必须大于0", data: nil) }
        let label = string(call, "label") ?? "计时器"
        let id = try await NotificationsManager.shared.scheduleTimer(duration: total, label: label)
        return ToolResult(success: true, message: "已开始 \(formatDuration(total)) 倒计时",
                          data: ["id": AnyCodable(id), "fires_at": AnyCodable(formatDate(Date().addingTimeInterval(total)))])
    }

    private static func listAlarms(_ call: [String: AnyCodable]) async throws -> ToolResult {
        await NotificationsManager.shared.refreshPending()
        let list = NotificationsManager.shared.pendingAlarms.map { ["id": AnyCodable($0.id), "title": AnyCodable($0.title), "fire_at": AnyCodable(formatDate($0.fireDate))] }
        return ToolResult(success: true, message: "当前有 \(list.count) 个待触发通知", data: ["alarms": AnyCodable(list)])
    }

    private static func cancelAlarm(_ call: [String: AnyCodable]) async throws -> ToolResult {
        if bool(call, "cancel_all") {
            await NotificationsManager.shared.cancelAllAlarms()
            return ToolResult(success: true, message: "已取消全部闹钟/计时器", data: nil)
        }
        guard let id = string(call, "id") else {
            return ToolResult(success: false, message: "需要提供 id 或 cancel_all=true", data: nil)
        }
        await NotificationsManager.shared.cancelAlarm(id: id)
        return ToolResult(success: true, message: "已取消通知 \(id)", data: nil)
    }

    // MARK: - Authorization helpers

    /// EKEntityType 是否已授权（兼容 iOS 16 仅有 .authorized 与 iOS 17+ 新增 .fullAccess）
    private static func ekAuthorized(_ type: EKEntityType) -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if #available(iOS 17.0, *) {
            return status == .fullAccess || status == .authorized
        } else {
            return status == .authorized
        }
    }

    // MARK: - Reminders

    private static func createReminder(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("reminders") else { return needEnable("提醒事项") }
        guard ekAuthorized(.reminder) else {
            return ToolResult(success: false, message: "提醒事项未授权，请在设置中开启", data: nil)
        }
        let title = string(call, "title") ?? "提醒"
        let notes = string(call, "notes")
        let reminder = EKReminder(eventStore: SettingsStore.shared.eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = SettingsStore.shared.eventStore.defaultCalendarForNewReminders() ?? SettingsStore.shared.eventStore.calendars(for: .reminder).first

        var due: Date?
        if let mins = int(call, "due_in_minutes"), mins > 0 {
            due = Date().addingTimeInterval(TimeInterval(mins) * 60)
        } else if let iso = string(call, "due_at"), let d = parseISO(iso) {
            due = d
        }
        if let due = due {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.dueDateComponents = comps
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try SettingsStore.shared.eventStore.save(reminder, commit: true)
        return ToolResult(success: true, message: due != nil ? "已创建提醒：\(title)，到期 \(formatDate(due!))" : "已创建提醒：\(title)",
                          data: ["id": AnyCodable(reminder.calendarItemIdentifier), "title": AnyCodable(title), "due": AnyCodable(due.map(formatDate) ?? "")])
    }

    private static func listReminders(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("reminders") else { return needEnable("提醒事项") }
        let store = SettingsStore.shared.eventStore
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let reminders = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }
        let limit = int(call, "limit") ?? 20
        let result = reminders.prefix(limit).map { r in
            ["id": AnyCodable(r.calendarItemIdentifier),
             "title": AnyCodable(r.title ?? ""),
             "due": AnyCodable(r.dueDateComponents?.date.map(formatDate) ?? "")]
        }
        return ToolResult(success: true, message: "找到 \(result.count) 条未完成提醒", data: ["reminders": AnyCodable(result)])
    }

    private static func completeReminder(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("reminders") else { return needEnable("提醒事项") }
        guard let id = string(call, "id") else { return ToolResult(success: false, message: "缺少 id", data: nil) }
        let store = SettingsStore.shared.eventStore
        let predicate = store.predicateForReminders(in: nil)
        let reminders = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }
        guard let reminder = reminders.first(where: { $0.calendarItemIdentifier == id }) else {
            return ToolResult(success: false, message: "未找到该提醒", data: nil)
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return ToolResult(success: true, message: "已完成提醒：\(reminder.title ?? "")", data: ["id": AnyCodable(id)])
    }

    // MARK: - Calendar

    private static func createCalendarEvent(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("calendar") else { return needEnable("日历") }
        guard ekAuthorized(.event) else {
            return ToolResult(success: false, message: "日历未授权，请在设置中开启", data: nil)
        }
        let title = string(call, "title") ?? "日程"
        guard let startIso = string(call, "start_at"), let start = parseISO(startIso) else {
            return ToolResult(success: false, message: "缺少 start_at", data: nil)
        }
        let end = string(call, "end_at").flatMap(parseISO) ?? start.addingTimeInterval(3600)
        let event = EKEvent(eventStore: SettingsStore.shared.eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = string(call, "notes")
        if let calName = string(call, "calendar_name") {
            event.calendar = SettingsStore.shared.eventStore.calendars(for: .event).first { $0.title == calName }
        }
        event.calendar = event.calendar ?? SettingsStore.shared.eventStore.defaultCalendarForNewEvents
        try SettingsStore.shared.eventStore.save(event, span: .thisEvent)
        return ToolResult(success: true, message: "已创建日程：\(title) \(formatDate(start)) - \(formatDate(end))",
                          data: ["id": AnyCodable(event.calendarItemIdentifier), "title": AnyCodable(title), "start": AnyCodable(formatDate(start))])
    }

    private static func listEvents(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("calendar") else { return needEnable("日历") }
        let days = int(call, "days") ?? 7
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = SettingsStore.shared.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = SettingsStore.shared.eventStore.events(matching: predicate).map { e in
            ["id": AnyCodable(e.calendarItemIdentifier),
             "title": AnyCodable(e.title ?? ""),
             "start": AnyCodable(formatDate(e.startDate)),
             "end": AnyCodable(formatDate(e.endDate))]
        }
        return ToolResult(success: true, message: "未来 \(days) 天共有 \(events.count) 个日程", data: ["events": AnyCodable(events)])
    }

    // MARK: - HealthKit

    private static func readHealth(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("health") else { return needEnable("健康") }
        guard HKHealthStore.isHealthDataAvailable() else { return ToolResult(success: false, message: "设备不支持 HealthKit", data: nil) }
        let metric = string(call, "metric") ?? "steps"
        let days = int(call, "days") ?? 7
        let store = SettingsStore.shared.healthStore

        // 授权状态预检：给出明确诊断，而非笼统失败
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let st = store.authorizationStatus(for: stepType)
            if st == .notDetermined {
                return ToolResult(success: false, message: "健康数据尚未授权。请在 App“设置 → 系统权限”中开启健康，并用包含 HealthKit 能力的付费开发者描述文件重签 IPA。免费 Apple ID 侧载通常无法开启 HealthKit 能力，会导致授权被系统拒绝。", data: nil)
            }
            if st == .sharingDenied {
                return ToolResult(success: false, message: "健康数据读取被拒绝。请在 iOS 系统“设置 → 隐私与安全性 → 健康”中重新允许 同步 读取。", data: nil)
            }
        }

        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!

        switch metric {
        case "steps":
            guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return unavailable }
            let (value, unit) = try await healthSum(type, .count(), start, end, store)
            return ToolResult(success: true, message: "过去 \(days) 天共 \(Int(value)) 步", data: ["steps": AnyCodable(Int(value)), "unit": AnyCodable(unit.unitString)])
        case "distance":
            guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return unavailable }
            let (value, _) = try await healthSum(type, .meterUnit(with: .kilo), start, end, store)
            return ToolResult(success: true, message: "过去 \(days) 天步行距离约 \(String(format: "%.2f", value)) 公里", data: ["distance_km": AnyCodable(value)])
        case "active_energy":
            guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return unavailable }
            let (value, _) = try await healthSum(type, .kilocalorie(), start, end, store)
            return ToolResult(success: true, message: "过去 \(days) 天活动能量约 \(Int(value)) 千卡", data: ["kcal": AnyCodable(Int(value))])
        case "heart_rate":
            guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return unavailable }
            let samples = try await healthSamples(type, start, end, store)
            guard !samples.isEmpty else { return ToolResult(success: true, message: "未找到心率数据", data: nil) }
            let avg = samples.map { $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()) ) }.reduce(0, +) / Double(samples.count)
            return ToolResult(success: true, message: "过去 \(days) 天平均心率约 \(Int(avg)) 次/分", data: ["avg_bpm": AnyCodable(Int(avg)), "samples": AnyCodable(samples.count)])
        case "sleep":
            guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return unavailable }
            let samples = try await healthCategorySamples(type, start, end, store)
            let totalMin = samples.filter { $0.value != HKCategoryValueSleepAnalysis.awake.rawValue && $0.value != HKCategoryValueSleepAnalysis.inBed.rawValue }
                .map { $0.endDate.timeIntervalSince($0.startDate) / 60 }.reduce(0, +)
            return ToolResult(success: true, message: "过去 \(days) 天睡眠约 \(Int(totalMin / 60)) 小时 \(Int(totalMin.truncatingRemainder(dividingBy: 60))) 分", data: ["sleep_minutes": AnyCodable(Int(totalMin))])
        case "body_mass":
            guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return unavailable }
            let samples = try await healthSamples(type, start, end, store)
            guard let latest = samples.last else { return ToolResult(success: true, message: "未找到体重数据", data: nil) }
            let kg = latest.quantity.doubleValue(for: .gramUnit(with: .kilo))
            return ToolResult(success: true, message: "最新体重 \(String(format: "%.1f", kg)) kg", data: ["kg": AnyCodable(kg)])
        default:
            return ToolResult(success: false, message: "不支持的指标 \(metric)", data: nil)
        }
    }

    private static func healthSum(_ type: HKQuantityType, _ unit: HKUnit, _ start: Date, _ end: Date, _ store: HKHealthStore) async throws -> (Double, HKUnit) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error = error { continuation.resume(throwing: error); return }
                let value = result?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: (value, unit))
            }
            store.execute(query)
        }
    }

    private static func healthSamples(_ type: HKQuantityType, _ start: Date, _ end: Date, _ store: HKHealthStore) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private static func healthCategorySamples(_ type: HKCategoryType, _ start: Date, _ end: Date, _ store: HKHealthStore) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private static var unavailable: ToolResult {
        ToolResult(success: false, message: "该健康指标在当前设备不可用", data: nil)
    }

    // MARK: - Contacts

    private static func searchContacts(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("contacts") else { return needEnable("通讯录") }
        let name = string(call, "name") ?? ""
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return ToolResult(success: false, message: "通讯录未授权", data: nil)
        }
        let store = SettingsStore.shared.contactStore
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactIdentifierKey] as [CNKeyDescriptor]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        let result = contacts.map { c in
            ["id": AnyCodable(c.identifier),
             "name": AnyCodable("\(c.familyName)\(c.givenName)"),
             "phones": AnyCodable(c.phoneNumbers.map { $0.value.stringValue }),
             "emails": AnyCodable(c.emailAddresses.map { String($0.value) })]
        }
        return ToolResult(success: true, message: "找到 \(result.count) 位联系人", data: ["contacts": AnyCodable(result)])
    }

    // MARK: - Location

    private static func getLocation(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("location") else { return needEnable("位置") }
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return ToolResult(success: false, message: "位置权限未授权", data: nil)
        }
        let location = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            let delegate = LocationFetchDelegate { result in
                continuation.resume(with: result)
            }
            LocationFetchDelegate.retain(delegate)
            manager.delegate = delegate
            manager.requestLocation()
        }
        let coord = ["latitude": AnyCodable(location.coordinate.latitude), "longitude": AnyCodable(location.coordinate.longitude)]
        return ToolResult(success: true, message: "当前位置：纬度 \(String(format: "%.5f", location.coordinate.latitude))，经度 \(String(format: "%.5f", location.coordinate.longitude))",
                          data: ["coordinate": AnyCodable(coord), "accuracy": AnyCodable(location.horizontalAccuracy)])
    }

    // MARK: - Clipboard

    private static func getClipboard(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("clipboard") else { return needEnable("剪贴板") }
        let text = UIPasteboard.general.string ?? ""
        return ToolResult(success: true, message: text.isEmpty ? "剪贴板为空" : "剪贴板内容：\(text)", data: ["text": AnyCodable(text)])
    }

    private static func setClipboard(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("clipboard") else { return needEnable("剪贴板") }
        guard let text = string(call, "text") else { return ToolResult(success: false, message: "缺少 text", data: nil) }
        UIPasteboard.general.string = text
        return ToolResult(success: true, message: "已写入剪贴板", data: ["text": AnyCodable(text)])
    }

    // MARK: - Photos

    private static func listPhotos(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard SettingsStore.shared.isEnabled("photos") else { return needEnable("相册") }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return ToolResult(success: false, message: "相册未授权", data: nil) }
        let limit = int(call, "limit") ?? 5
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: options)
        var items: [[String: Any]] = []
        assets.enumerateObjects { asset, idx, stop in
            items.append([
                "id": asset.localIdentifier,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight,
                "created": asset.creationDate?.ISO8601Format() ?? ""
            ])
        }
        return ToolResult(success: true, message: "最近 \(items.count) 张照片", data: ["photos": AnyCodable(items)])
    }

    // MARK: - Open URL

    private static func openURL(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard let urlString = string(call, "url"), let url = URL(string: urlString) else {
            return ToolResult(success: false, message: "无效的 URL", data: nil)
        }
        let canOpen = await UIApplication.shared.canOpenURL(url)
        guard canOpen else { return ToolResult(success: false, message: "系统无法打开该 URL：\(urlString)", data: nil) }
        await UIApplication.shared.open(url)
        return ToolResult(success: true, message: "已打开 \(urlString)", data: ["url": AnyCodable(urlString)])
    }

    // MARK: - Device

    private static func deviceInfo(_ call: [String: AnyCodable]) async throws -> ToolResult {
        let device = UIDevice.current
        let info: [String: Any] = [
            "name": device.name,
            "model": device.model,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "battery_level": Int(device.batteryLevel * 100),
            "is_battery_monitoring": device.isBatteryMonitoringEnabled,
            "thermal_state": ProcessInfo.processInfo.thermalStateDescription
        ]
        return ToolResult(success: true,
                          message: "\(device.model)，iOS \(device.systemVersion)，电量 \(Int(device.batteryLevel * 100))%",
                          data: ["device": AnyCodable(info)])
    }

    // MARK: - Document generation

    private static func createFile(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard let filename = string(call, "filename"), let content = string(call, "content") else {
            return ToolResult(success: false, message: "缺少 filename 或 content", data: nil)
        }
        let url = try DocumentGenerator.generateTextFile(filename: filename, content: content)
        return ToolResult(success: true, message: "已创建文件：\(url.lastPathComponent)",
                          data: ["path": AnyCodable(url.path), "filename": AnyCodable(filename)],
                          fileURL: url)
    }

    private static func createPPT(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard let title = string(call, "title") else {
            return ToolResult(success: false, message: "缺少 title", data: nil)
        }
        guard let slidesRaw = call["slides"]?.value as? [Any] else {
            return ToolResult(success: false, message: "slides 格式错误，应为数组", data: nil)
        }
        var slides: [(title: String, bullets: [String])] = []
        for item in slidesRaw {
            guard let dict = item as? [String: Any],
                  let slideTitle = dict["title"] as? String else { continue }
            let bullets = (dict["bullets"] as? [String]) ?? []
            slides.append((title: slideTitle, bullets: bullets))
        }
        guard !slides.isEmpty else {
            return ToolResult(success: false, message: "slides 为空或格式无法解析", data: nil)
        }
        let url = try DocumentGenerator.generatePPTX(title: title, slides: slides)
        return ToolResult(success: true, message: "已生成 PPT：\(url.lastPathComponent)，可在聊天中点击分享。",
                          data: ["path": AnyCodable(url.path), "filename": AnyCodable(url.lastPathComponent)],
                          fileURL: url)
    }

    // MARK: - 通用 HTTP 请求（类 Manus 连接器，可编排任意外部服务）

    private static let webSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private static func webRequest(_ call: [String: AnyCodable]) async throws -> ToolResult {
        guard let rawURL = string(call, "url"),
              let u = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme, scheme == "http" || scheme == "https" else {
            return ToolResult(success: false, message: "url 无效，必须是 http(s) 开头", data: nil)
        }

        let method = (string(call, "method") ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var req = URLRequest(url: u)
        req.httpMethod = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"].contains(method) ? method : "GET"

        if let hStr = string(call, "headers"),
           let hData = hStr.data(using: .utf8),
           let hDict = try? JSONSerialization.jsonObject(with: hData) as? [String: Any] {
            for (k, v) in hDict {
                req.setValue("\(v)", forHTTPHeaderField: k)
            }
        }

        // 自动鉴权：仅当请求主机与配置的远程执行服务一致时，附加用户 token（或 BYOS 静态密钥）。
        // 这样密钥不进模型上下文、不进聊天，且用户换任意 skill 都自动带上自己的凭证。
        if let ep = URL(string: SettingsStore.shared.connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
           let epHost = ep.host, epHost == u.host {
            let existing = req.value(forHTTPHeaderField: "Authorization")
            if existing == nil || existing?.isEmpty == true {
                let token = SettingsStore.shared.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                } else {
                    let key = SettingsStore.shared.connectorApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty {
                        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                    }
                }
            }
        }

        if let bStr = string(call, "body"), !bStr.isEmpty {
            req.httpBody = Data(bStr.utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let saveAs = string(call, "save_as")?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let (data, resp) = try await webSession.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let contentType = ((resp as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String) ?? ""

            let forceFile = (saveAs != nil)
            let isBinary = forceFile ? !Self.isLikelyText(contentType) : Self.isBinaryContent(contentType)

            if isBinary || forceFile {
                let filename = saveAs ?? Self.defaultFilename(from: u, contentType: contentType)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileURL = docs.appendingPathComponent(filename)
                try data.write(to: fileURL, options: .atomic)
                return ToolResult(success: true,
                                  message: "HTTP \(status)，已保存文件：\(filename)（\(data.count) 字节），可在聊天中打开/分享。",
                                  data: ["status": AnyCodable(status), "filename": AnyCodable(filename), "bytes": AnyCodable(data.count)],
                                  fileURL: fileURL)
            }

            let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            let shown = String(text.prefix(4000))
            return ToolResult(success: true,
                              message: "HTTP \(status)，响应体已返回（\(data.count) 字节）。",
                              data: ["status": AnyCodable(status), "body": AnyCodable(shown)])
        } catch {
            return ToolResult(success: false, message: "请求失败：\(error.localizedDescription)", data: nil)
        }
    }

    private static func isBinaryContent(_ ct: String) -> Bool {
        let lower = ct.lowercased()
        if lower.contains("text/") || lower.contains("application/json") || lower.contains("application/xml")
            || lower.contains("application/javascript") || lower.contains("+xml") { return false }
        if lower.contains("application/") || lower.contains("image/") || lower.contains("audio/")
            || lower.contains("video/") || lower.contains("font/") || lower.contains("zip")
            || lower.contains("octet-stream") { return true }
        return false
    }

    private static func isLikelyText(_ ct: String) -> Bool {
        let lower = ct.lowercased()
        return lower.contains("text/") || lower.contains("json") || lower.contains("xml")
    }

    private static func defaultFilename(from url: URL, contentType ct: String) -> String {
        let ext: String
        if ct.contains("pptx") { ext = "pptx" }
        else if ct.contains("pdf") { ext = "pdf" }
        else if ct.contains("image/png") { ext = "png" }
        else if ct.contains("image/jpeg") { ext = "jpg" }
        else if ct.contains("image/") { ext = "img" }
        else if ct.contains("audio/") { ext = "audio" }
        else if ct.contains("video/") { ext = "mp4" }
        else { ext = "bin" }
        let ts = Int(Date().timeIntervalSince1970)
        return "web_\(ts).\(ext)"
    }

    // MARK: - Helpers

    private static func needEnable(_ name: String) -> ToolResult {
        ToolResult(success: false, message: "请在设置中开启\(name)能力", data: nil)
    }

    private static func string(_ call: [String: AnyCodable], _ key: String) -> String? {
        call[key]?.value as? String
    }
    private static func int(_ call: [String: AnyCodable], _ key: String) -> Int? {
        call[key]?.value as? Int
    }
    private static func bool(_ call: [String: AnyCodable], _ key: String) -> Bool {
        call[key]?.value as? Bool ?? false
    }

    private static func parseISO(_ iso: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: iso) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: iso)
    }

    private static func formatDate(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        if m > 0 { return "\(m)分\(s)秒" }
        return "\(s)秒"
    }
}

// MARK: - Location delegates

final class LocationFetchDelegate: NSObject, CLLocationManagerDelegate {
    static private var retained: [LocationFetchDelegate] = []
    static func retain(_ d: LocationFetchDelegate) { retained.append(d) }

    private let completion: (Result<CLLocation, Error>) -> Void
    private var done = false
    init(_ completion: @escaping (Result<CLLocation, Error>) -> Void) { self.completion = completion }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !done, let loc = locations.last else { return }
        done = true
        completion(.success(loc))
        LocationFetchDelegate.retained.removeAll { $0 === self }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !done else { return }
        done = true
        completion(.failure(error))
        LocationFetchDelegate.retained.removeAll { $0 === self }
    }
}

extension ProcessInfo {
    var thermalStateDescription: String {
        switch thermalState {
        case .nominal: return "正常"
        case .fair: return "轻微发热"
        case .serious: return "严重发热"
        case .critical: return "极热"
        @unknown default: return "未知"
        }
    }
}
