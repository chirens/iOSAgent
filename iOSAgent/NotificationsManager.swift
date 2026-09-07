import Foundation
import UserNotifications
import UIKit

/// 本地通知闹钟 / 计时器 / 提醒 管理器
@MainActor
class NotificationsManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationsManager()
    @Published var pendingAlarms: [PendingAlarm] = []

    override init() {
        super.init()
        loadPending()
    }

    func ensureCategory() {
        let stopAction = UNNotificationAction(identifier: "stop_timer", title: "停止计时器", options: [.destructive])
        let category = UNNotificationCategory(identifier: "timer_category", actions: [stopAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func refreshPending() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] requests in
            let alarms = requests.map { r in
                PendingAlarm(id: r.identifier,
                             title: r.content.title,
                             body: r.content.body,
                             fireDate: (r.content.userInfo["fireAt"] as? Date) ?? Date.distantFuture,
                             repeatPattern: r.content.userInfo["repeatPattern"] as? String)
            }.sorted { $0.fireDate < $1.fireDate }
            DispatchQueue.main.async {
                self?.pendingAlarms = alarms
            }
        }
    }

    private func loadPending() {
        refreshPending()
    }

    /// 设置一个闹钟 / 提醒。支持重复：none（默认）/ daily / weekly / weekdays / custom。
    /// 返回第一个通知 id；weekdays/custom 会创建多个通知，id 以 "group:" 为前缀、用逗号连接各子 id。
    func scheduleAlarm(id: String? = nil, title: String, body: String, fireAt: Date,
                       soundName: String? = nil, isTimer: Bool = false,
                       repeatPattern: String = "none", weekdays: [Int] = []) async throws -> String {
        let baseId = id ?? UUID().uuidString
        let cal = Calendar.current
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundName != nil ? UNNotificationSound(named: UNNotificationSoundName(soundName!)) : .default
        content.badge = 1
        if isTimer { content.categoryIdentifier = "timer_category" }
        content.userInfo = ["fireAt": fireAt, "repeatPattern": repeatPattern]

        let center = UNUserNotificationCenter.current()
        let baseComps = cal.dateComponents([.hour, .minute, .second], from: fireAt)

        func makeRequest(_ comps: DateComponents, _ subId: String) async throws {
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeatPattern != "none")
            let request = UNNotificationRequest(identifier: subId, content: content, trigger: trigger)
            try await center.add(request)
        }

        switch repeatPattern {
        case "daily":
            var comps = baseComps
            comps.second = 0
            try await makeRequest(comps, baseId)
            return baseId
        case "weekly":
            var comps = baseComps
            comps.weekday = cal.component(.weekday, from: fireAt)
            comps.second = 0
            try await makeRequest(comps, baseId)
            return baseId
        case "weekdays":
            let targetWeekdays = [2, 3, 4, 5, 6] // Mon-Fri
            var ids: [String] = []
            for wd in targetWeekdays {
                var comps = baseComps
                comps.weekday = wd
                comps.second = 0
                let subId = "\(baseId):wd\(wd)"
                try await makeRequest(comps, subId)
                ids.append(subId)
            }
            return "group:\(ids.joined(separator: ","))"
        case "custom":
            let targetWeekdays = weekdays.isEmpty ? [cal.component(.weekday, from: fireAt)] : weekdays
            var ids: [String] = []
            for wd in targetWeekdays {
                var comps = baseComps
                comps.weekday = wd
                comps.second = 0
                let subId = "\(baseId):wd\(wd)"
                try await makeRequest(comps, subId)
                ids.append(subId)
            }
            return "group:\(ids.joined(separator: ","))"
        default:
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
            try await makeRequest(comps, baseId)
            return baseId
        }
    }

    /// 设置一个倒计时器
    func scheduleTimer(duration: TimeInterval, label: String) async throws -> String {
        let fireAt = Date().addingTimeInterval(duration)
        let id = "timer:\(UUID().uuidString)"
        return try await scheduleAlarm(id: id, title: label.isEmpty ? "计时器" : label, body: "倒计时已结束", fireAt: fireAt, isTimer: true)
    }

    func cancelAlarm(id: String) async {
        var ids = [id]
        if id.hasPrefix("group:"), let range = id.range(of: "group:") {
            ids = String(id[range.upperBound...]).split(separator: ",").map(String.init)
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        refreshPending()
    }

    func cancelAllAlarms() async {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        refreshPending()
    }

    /// 前台也能收到通知
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

struct PendingAlarm: Identifiable, Codable {
    let id: String
    let title: String
    let body: String
    let fireDate: Date
    let repeatPattern: String?   // none / daily / weekly / weekdays / custom
}
