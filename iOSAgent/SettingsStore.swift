import Foundation
import SwiftUI
import EventKit
import HealthKit
import Contacts
import CoreLocation
import Photos
import UserNotifications

/// 每个系统能力的开关与授权状态
struct CapabilitySetting: Identifiable, Codable {
    let id: String
    var enabled: Bool
    var status: AuthStatus
}

enum AuthStatus: String, Codable, CaseIterable {
    case unknown = "未知"
    case notDetermined = "未请求"
    case denied = "已拒绝"
    case authorized = "已授权"
    case limited = "受限"
    case restricted = "受限制"
    case unavailable = "不可用"
}

/// 全局设置与权限状态
@MainActor
class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("apiBaseURL") var apiBaseURL: String = "https://api.deepseek.com"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("modelName") var modelName: String = "deepseek-chat"
    @AppStorage("sttModelName") var sttModelName: String = "whisper-1"
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false

    @Published var capabilities: [String: CapabilitySetting] = [:]

    let eventStore = EKEventStore()
    let healthStore = HKHealthStore()
    let contactStore = CNContactStore()
    let locationManager = CLLocationManager()

    private let capabilityMeta: [(String, String, Bool)] = [
        ("reminders", "提醒事项", true),
        ("calendar", "日历", true),
        ("health", "健康", false),
        ("contacts", "通讯录", false),
        ("location", "位置", false),
        ("clipboard", "剪贴板", true),
        ("photos", "相册", false),
        ("notifications", "通知/闹钟", true),
        ("device", "设备信息", true),
    ]

    init() {
        loadCapabilities()
        refreshAuthStatuses()
    }

    func loadCapabilities() {
        if let data = UserDefaults.standard.data(forKey: "capabilities"),
           let decoded = try? JSONDecoder().decode([String: CapabilitySetting].self, from: data) {
            capabilities = decoded
        } else {
            for (id, name, def) in capabilityMeta {
                capabilities[id] = CapabilitySetting(id: name, enabled: def, status: .unknown)
            }
        }
    }

    func saveCapabilities() {
        if let data = try? JSONEncoder().encode(capabilities) {
            UserDefaults.standard.set(data, forKey: "capabilities")
        }
    }

    func isEnabled(_ key: String) -> Bool {
        capabilities[key]?.enabled ?? false
    }

    func status(_ key: String) -> AuthStatus {
        capabilities[key]?.status ?? .unknown
    }

    func setEnabled(_ key: String, _ value: Bool) {
        capabilities[key]?.enabled = value
        saveCapabilities()
    }

    func setStatus(_ key: String, _ status: AuthStatus) {
        capabilities[key]?.status = status
        objectWillChange.send()
        saveCapabilities()
    }

    var anyToolEnabled: Bool {
        capabilities.values.contains { $0.enabled }
    }

    /// 刷新所有授权状态（不弹窗）
    func refreshAuthStatuses() {
        // Reminders
        mapEKStatus("reminders", EKEventStore.authorizationStatus(for: .reminder))

        // Calendar
        mapEKStatus("calendar", EKEventStore.authorizationStatus(for: .event))

        // Health
        if HKHealthStore.isHealthDataAvailable() {
            mapHealthStatus()
        } else {
            setStatus("health", .unavailable)
        }

        // Contacts
        mapCNStatus("contacts", CNContactStore.authorizationStatus(for: .contacts))

        // Location
        mapCLStatus("location", CLLocationManager.authorizationStatus())

        // Photos
        mapPHStatus("photos", PHPhotoLibrary.authorizationStatus(for: .readWrite))

        // Notifications
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            DispatchQueue.main.async {
                self?.mapUNStatus("notifications", s.authorizationStatus)
            }
        }

        // Clipboard / Device require no auth
        setStatus("clipboard", .authorized)
        setStatus("device", .authorized)
    }

    private func mapHealthStatus() {
        // 只要步数授权状态能拿到，就以它为代表状态
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            setStatus("health", .unavailable)
            return
        }
        let status = healthStore.authorizationStatus(for: stepType)
        switch status {
        case .notDetermined: setStatus("health", .notDetermined)
        case .sharingDenied: setStatus("health", .denied)
        case .sharingAuthorized: setStatus("health", .authorized)
        @unknown default: setStatus("health", .unknown)
        }
    }

    private func mapEKStatus(_ key: String, _ status: EKAuthorizationStatus) {
        if #available(iOS 17.0, *) {
            switch status {
            case .notDetermined: setStatus(key, .notDetermined)
            case .restricted, .denied: setStatus(key, .denied)
            case .fullAccess, .authorized: setStatus(key, .authorized)
            case .writeOnly: setStatus(key, .limited)
            @unknown default: setStatus(key, .unknown)
            }
        } else {
            switch status {
            case .notDetermined: setStatus(key, .notDetermined)
            case .restricted, .denied: setStatus(key, .denied)
            case .authorized: setStatus(key, .authorized)
            @unknown default: setStatus(key, .unknown)
            }
        }
    }

    private func mapCNStatus(_ key: String, _ status: CNAuthorizationStatus) {
        switch status {
        case .notDetermined: setStatus(key, .notDetermined)
        case .restricted: setStatus(key, .restricted)
        case .denied: setStatus(key, .denied)
        case .authorized: setStatus(key, .authorized)
        case .limited: setStatus(key, .limited)
        @unknown default: setStatus(key, .unknown)
        }
    }

    private func mapCLStatus(_ key: String, _ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: setStatus(key, .notDetermined)
        case .restricted: setStatus(key, .restricted)
        case .denied: setStatus(key, .denied)
        case .authorizedAlways, .authorizedWhenInUse: setStatus(key, .authorized)
        @unknown default: setStatus(key, .unknown)
        }
    }

    private func mapPHStatus(_ key: String, _ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: setStatus(key, .notDetermined)
        case .restricted: setStatus(key, .restricted)
        case .denied: setStatus(key, .denied)
        case .authorized: setStatus(key, .authorized)
        case .limited: setStatus(key, .limited)
        @unknown default: setStatus(key, .unknown)
        }
    }

    private func mapUNStatus(_ key: String, _ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: setStatus(key, .notDetermined)
        case .denied: setStatus(key, .denied)
        case .authorized: setStatus(key, .authorized)
        case .provisional, .ephemeral: setStatus(key, .limited)
        @unknown default: setStatus(key, .unknown)
        }
    }

    /// 请求某个能力的授权（会弹窗）
    func requestAuth(for key: String) async -> AuthStatus {
        switch key {
        case "reminders":
            return await requestRemindersAuth()
        case "calendar":
            return await requestCalendarAuth()
        case "health":
            return await requestHealthAuth()
        case "contacts":
            return await requestContactsAuth()
        case "location":
            return await requestLocationAuth()
        case "photos":
            return await requestPhotosAuth()
        case "notifications":
            return await requestNotificationsAuth()
        default:
            return .authorized
        }
    }

    private func requestRemindersAuth() async -> AuthStatus {
        if #available(iOS 17.0, *) {
            let granted = try? await eventStore.requestFullAccessToReminders()
            let status: AuthStatus = granted == true ? .authorized : .denied
            setStatus("reminders", status)
            return status
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            let status: AuthStatus = granted ? .authorized : .denied
            setStatus("reminders", status)
            return status
        }
    }

    private func requestCalendarAuth() async -> AuthStatus {
        if #available(iOS 17.0, *) {
            let granted = try? await eventStore.requestFullAccessToEvents()
            let status: AuthStatus = granted == true ? .authorized : .denied
            setStatus("calendar", status)
            return status
        } else {
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            let status: AuthStatus = granted ? .authorized : .denied
            setStatus("calendar", status)
            return status
        }
    }

    private func requestHealthAuth() async -> AuthStatus {
        guard HKHealthStore.isHealthDataAvailable() else {
            setStatus("health", .unavailable)
            return .unavailable
        }

        // 只请求常见、稳定的指标，避免某些类型在特定设备上不存在导致整批授权失败
        var readTypes = Set<HKObjectType>()
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .heartRate,
            .distanceWalkingRunning,
            .activeEnergyBurned,
            .bodyMass,
            .height
        ]
        for id in quantityIDs {
            if let t = HKQuantityType.quantityType(forIdentifier: id) {
                readTypes.insert(t)
            }
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleepType)
        }
        readTypes.insert(HKObjectType.workoutType())

        guard !readTypes.isEmpty else {
            setStatus("health", .unavailable)
            return .unavailable
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            setStatus("health", .denied)
            return .denied
        }
        refreshAuthStatuses()
        return status("health")
    }

    private func requestContactsAuth() async -> AuthStatus {
        let granted = await withCheckedContinuation { continuation in
            contactStore.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        let status: AuthStatus = granted ? .authorized : .denied
        setStatus("contacts", status)
        return status
    }

    private func requestLocationAuth() async -> AuthStatus {
        let manager = CLLocationManager()
        let granted = await withCheckedContinuation { continuation in
            let delegate = LocationAuthDelegate { status in
                continuation.resume(returning: status)
            }
            manager.delegate = delegate
            LocationAuthDelegate.retain(delegate)
            manager.requestWhenInUseAuthorization()
        }
        mapCLStatus("location", manager.authorizationStatus)
        return status("location")
    }

    private func requestPhotosAuth() async -> AuthStatus {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
        mapPHStatus("photos", status)
        return self.status("photos")
    }

    private func requestNotificationsAuth() async -> AuthStatus {
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        let status: AuthStatus = granted == true ? .authorized : .denied
        setStatus("notifications", status)
        return status
    }
}

/// 一次性 CoreLocation 授权委托
final class LocationAuthDelegate: NSObject, CLLocationManagerDelegate {
    static private var retained: [LocationAuthDelegate] = []
    static func retain(_ d: LocationAuthDelegate) {
        retained.append(d)
    }

    private let completion: (CLAuthorizationStatus) -> Void
    init(_ completion: @escaping (CLAuthorizationStatus) -> Void) {
        self.completion = completion
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status != .notDetermined {
            completion(status)
            LocationAuthDelegate.retained.removeAll { $0 === self }
        }
    }
}
