import Foundation
import EventKit
import HealthKit
import UserNotifications

/// 一个工具定义（OpenAI function-calling 格式）
struct ToolSpec {
    let schema: [String: Any]
}

/// 系统能力工具：把 LLM 的"意图"落实为真实的 iOS 系统写入/读取。
/// 对标 OpenMinis 用 iSH + CLI 桥接原生框架的做法，这里直接在 Swift 里调用
/// EventKit / HealthKit / UserNotifications，效果一致但更稳更轻。
final class SystemTools {
    static let shared = SystemTools()
    private let eventStore = EKEventStore()
    private let healthStore = HKHealthStore()

    // MARK: - 当前应暴露给 LLM 的工具（由设置开关决定）

    static func activeTools() -> [ToolSpec] {
        let s = SettingsStore.shared
        var list: [ToolSpec] = []
        if s.enableReminders {
            list.append(ToolSpec(schema: createReminderSchema))
            list.append(ToolSpec(schema: listRemindersSchema))
        }
        if s.enableCalendar { list.append(ToolSpec(schema: createEventSchema)) }
        if s.enableAlarm   { list.append(ToolSpec(schema: scheduleAlarmSchema)) }
        if s.enableHealth  { list.append(ToolSpec(schema: readHealthSchema)) }
        return list
    }

    // MARK: - 派发执行

    func dispatch(_ name: String, arguments: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8), options: [])) as? [String: Any] ?? [:]
        switch name {
        case "create_reminder":      return await createReminder(args)
        case "list_reminders":       return await listReminders()
        case "create_calendar_event":return await createEvent(args)
        case "schedule_alarm":       return await scheduleAlarm(args)
        case "read_health":          return await readHealth(args)
        default:                     return "未知工具：\(name)"
        }
    }

    // MARK: - 提醒事项（EventKit）

    private func createReminder(_ a: [String: Any]) async -> String {
        guard SettingsStore.shared.enableReminders else { return "提醒事项功能未开启，请在「设置 → 系统能力」中打开。" }
        let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "提醒"
        let notes = a["notes"] as? String
        let due = parseDate(a["due"] as? String)
        return await withCheckedContinuation { cont in
            eventStore.requestFullAccessToReminders { granted, _ in
                guard granted else { cont.resume(returning: "无权访问提醒事项，请在系统设置中授权。"); return }
                let r = EKReminder(eventStore: self.eventStore)
                r.title = title
                r.notes = notes
                r.calendar = self.eventStore.defaultCalendarForNewReminders()
                if let due {
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                    r.addAlarm(EKAlarm(absoluteDate: due))
                }
                do {
                    try self.eventStore.save(r, commit: true)
                    cont.resume(returning: "✅ 已创建提醒「\(title)」" + (due != nil ? "，时间 \(self.fmt(due!))" : "（无截止时间）"))
                } catch {
                    cont.resume(returning: "❌ 创建提醒失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func listReminders() async -> String {
        guard SettingsStore.shared.enableReminders else { return "提醒事项功能未开启。" }
        return await withCheckedContinuation { cont in
            eventStore.requestFullAccessToReminders { granted, _ in
                guard granted else { cont.resume(returning: "无权访问提醒事项。"); return }
                let pred = self.eventStore.predicateForReminders(in: nil)
                self.eventStore.fetchReminders(matching: pred) { reminders in
                    guard let reminders else { cont.resume(returning: "读取提醒失败。"); return }
                    let incomplete = reminders.filter { !$0.isCompleted }
                    if incomplete.isEmpty { cont.resume(returning: "当前没有未完成的提醒。"); return }
                    let lines = incomplete.prefix(12).map { r -> String in
                        var s = "• \(r.title ?? "")"
                        if let c = r.dueDateComponents, let d = Calendar.current.date(from: c) {
                            s += "（\(self.fmt(d))）"
                        }
                        return s
                    }
                    cont.resume(returning: "未完成提醒（共 \(incomplete.count) 条）：\n" + lines.joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - 日历事件（EventKit）

    private func createEvent(_ a: [String: Any]) async -> String {
        guard SettingsStore.shared.enableCalendar else { return "日历功能未开启，请在设置中打开。" }
        let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "事件"
        let notes = a["notes"] as? String
        guard let start = parseDate(a["start"] as? String) else {
            return "请提供有效的 start（ISO8601 开始时间）。"
        }
        let end = parseDate(a["end"] as? String) ?? start.addingTimeInterval(3600)
        return await withCheckedContinuation { cont in
            eventStore.requestFullAccessToEvents { granted, _ in
                guard granted else { cont.resume(returning: "无权访问日历，请在系统设置中授权。"); return }
                let ev = EKEvent(eventStore: self.eventStore)
                ev.title = title
                ev.notes = notes
                ev.startDate = start
                ev.endDate = end
                ev.calendar = self.eventStore.defaultCalendarForNewEvents
                do {
                    try self.eventStore.save(ev, span: .thisEvent, commit: true)
                    cont.resume(returning: "✅ 已创建日历事件「\(title)」，\(self.fmt(start)) – \(self.fmt(end))")
                } catch {
                    cont.resume(returning: "❌ 创建日历事件失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 闹钟 / 本地提醒（UNUserNotificationCenter）
    // 说明：iOS 第三方 App 无法写入系统「时钟」App 的闹钟，
    // 此工具以「本地通知」形式在指定时间弹出提醒，是最接近闹钟的可行方案。

    private func scheduleAlarm(_ a: [String: Any]) async -> String {
        guard SettingsStore.shared.enableAlarm else { return "闹钟/提醒功能未开启，请在设置中打开。" }
        let label = (a["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "提醒"
        guard let fire = parseDate(a["fire_at"] as? String) else {
            return "请提供有效的 fire_at（ISO8601 时间）。"
        }
        guard fire > Date() else { return "时间必须晚于当前时间。" }
        return await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { cont.resume(returning: "未授权通知，无法设置。"); return }
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(label)"
                content.body = "来自 iOSAgent 的提醒"
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire),
                    repeats: false)
                let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(req) { err in
                    if let err {
                        cont.resume(returning: "❌ 设置失败：\(err.localizedDescription)")
                    } else {
                        cont.resume(returning: "✅ 已设置提醒「\(label)」，时间 \(self.fmt(fire))（以本地通知形式提醒，非系统时钟 App 闹钟）。")
                    }
                }
            }
        }
    }

    // MARK: - 健康数据（HealthKit）

    private func readHealth(_ a: [String: Any]) async -> String {
        guard SettingsStore.shared.enableHealth else { return "健康数据功能未开启，请在设置中打开。" }
        let metric = (a["metric"] as? String) ?? "steps"
        let days = max(1, min(90, (a["days"] as? Int) ?? 7))
        let type: HKObjectType?
        switch metric {
        case "heart_rate":  type = HKObjectType.quantityType(forIdentifier: .heartRate)
        case "active_energy": type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case "weight":      type = HKObjectType.quantityType(forIdentifier: .bodyMass)
        case "sleep":       type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        default:            type = HKObjectType.quantityType(forIdentifier: .stepCount)
        }
        guard let type else { return "不支持的指标：\(metric)" }
        return await withCheckedContinuation { cont in
            guard self.healthStore.authorizationStatus(for: type) == .sharingAuthorized else {
                cont.resume(returning: "健康数据未授权，请在设置中开启并允许读取。"); return
            }
            let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let end = Date()
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

            if metric == "sleep" {
                let q = HKSampleQuery(sampleType: type as! HKSampleType, predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, err in
                    guard let samples = samples as? [HKCategorySample], err == nil else {
                        cont.resume(returning: "读取睡眠失败。"); return
                    }
                    let secs = samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                    cont.resume(returning: "近 \(days) 天共 \(samples.count) 段睡眠记录，总时长约 \(String(format: "%.1f", secs / 3600)) 小时。")
                }
                self.healthStore.execute(q)
                return
            }

            let qType = type as! HKQuantityType
            let opts: HKStatisticsOptions = (metric == "heart_rate") ? .discreteAverage : .cumulativeSum
            let q = HKStatisticsCollectionQuery(quantityType: qType, quantitySamplePredicate: pred,
                                                options: opts, anchorDate: start,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, stats, err in
                guard let stats, err == nil else { cont.resume(returning: "读取\(metric)失败。"); return }
                if metric == "heart_rate" {
                    var sum = 0.0, n = 0
                    let unit = HKUnit.count().unitDivided(by: .minute())
                    stats.enumerateStatistics(from: start, to: end) { st, _ in
                        if let v = st.averageQuantity()?.doubleValue(for: unit) { sum += v; n += 1 }
                    }
                    cont.resume(returning: n > 0 ? "近 \(days) 天平均心率约 \(String(format: "%.0f", sum / Double(n))) bpm。" : "近 \(days) 天无心率数据。")
                } else {
                    let unit: HKUnit = (metric == "weight") ? .gramUnit(with: .kilo) : (metric == "active_energy" ? .kilocalorie() : .count())
                    var total = 0.0
                    stats.enumerateStatistics(from: start, to: end) { st, _ in
                        if let v = st.sumQuantity()?.doubleValue(for: unit) { total += v }
                    }
                    let label = metric == "steps" ? "步数" : (metric == "weight" ? "体重" : "活动能量")
                    let unitS = metric == "steps" ? "步" : (metric == "weight" ? "kg" : "kcal")
                    cont.resume(returning: "近 \(days) 天累计\(label)约 \(String(format: "%.0f", total)) \(unitS)。")
                }
            }
            self.healthStore.execute(q)
        }
    }

    // MARK: - 日期/格式辅助

    private func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        let f2 = DateFormatter()
        f2.timeZone = .current
        f2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = f2.date(from: s) { return d }
        f2.dateFormat = "yyyy-MM-dd HH:mm"
        return f2.date(from: s)
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: d)
    }

    // MARK: - 工具 JSON Schema（OpenAI function-calling）

    private static let createReminderSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_reminder",
            "description": "在系统「提醒事项」中创建一个提醒，可用于待办、备忘。",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "提醒标题"],
                    "due": ["type": "string", "description": "到期时间，ISO8601，例如 2026-08-26T09:30:00"],
                    "notes": ["type": "string", "description": "备注（可选）"]
                ],
                "required": ["title"]
            ]
        ]
    ]

    private static let listRemindersSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "list_reminders",
            "description": "列出当前未完成的提醒事项。",
            "parameters": ["type": "object", "properties": [:]]
        ]
    ]

    private static let createEventSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "create_calendar_event",
            "description": "在系统「日历」中创建一条事件。",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "事件标题"],
                    "start": ["type": "string", "description": "开始时间，ISO8601"],
                    "end": ["type": "string", "description": "结束时间，ISO8601（可选，默认 1 小时后）"],
                    "notes": ["type": "string", "description": "备注（可选）"]
                ],
                "required": ["title", "start"]
            ]
        ]
    ]

    private static let scheduleAlarmSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "schedule_alarm",
            "description": "设置一个本地提醒（以通知形式在指定时间弹出，并非系统时钟 App 的闹钟）。",
            "parameters": [
                "type": "object",
                "properties": [
                    "label": ["type": "string", "description": "提醒标签"],
                    "fire_at": ["type": "string", "description": "触发时间，ISO8601，必须晚于当前时间"]
                ],
                "required": ["label", "fire_at"]
            ]
        ]
    ]

    private static let readHealthSchema: [String: Any] = [
        "type": "function",
        "function": [
            "name": "read_health",
            "description": "读取 Apple 健康数据（步数/心率/睡眠/活动能量/体重）。",
            "parameters": [
                "type": "object",
                "properties": [
                    "metric": ["type": "string",
                               "description": "指标：steps(步数) / heart_rate(心率) / sleep(睡眠) / active_energy(活动能量) / weight(体重)",
                               "enum": ["steps", "heart_rate", "sleep", "active_energy", "weight"]],
                    "days": ["type": "integer", "description": "统计最近多少天，默认 7，最大 90"]
                ],
                "required": ["metric"]
            ]
        ]
    ]
}
