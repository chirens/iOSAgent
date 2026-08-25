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
                             fireDate: (r.content.userInfo["fireAt"] as? Date) ?? Date.distantFuture)
            }.sorted { $0.fireDate < $1.fireDate }
            DispatchQueue.main.async {
                self?.pendingAlarms = alarms
            }
        }
    }

    private func loadPending() {
        refreshPending()
    }

    /// 设置一个闹钟 / 一次性提醒
    func scheduleAlarm(id: String? = nil, title: String, body: String, fireAt: Date, soundName: String? = nil, isTimer: Bool = false) async throws -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundName != nil ? UNNotificationSound(named: UNNotificationSoundName(soundName!)) : .default
        content.badge = 1
        if isTimer { content.categoryIdentifier = "timer_category" }
        content.userInfo = ["fireAt": fireAt]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: content, trigger: trigger)

        try await UNUserNotificationCenter.current().add(request)
        refreshPending()
        return request.identifier
    }

    /// 设置一个倒计时器
    func scheduleTimer(duration: TimeInterval, label: String) async throws -> String {
        let fireAt = Date().addingTimeInterval(duration)
        let id = "timer:\(UUID().uuidString)"
        return try await scheduleAlarm(id: id, title: label.isEmpty ? "计时器" : label, body: "倒计时已结束", fireAt: fireAt, isTimer: true)
    }

    func cancelAlarm(id: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
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
}
