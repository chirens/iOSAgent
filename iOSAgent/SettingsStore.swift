import Foundation
import Combine
import EventKit
import HealthKit
import UserNotifications

/// 全局设置 + iOS 系统能力开关 + 权限请求。
/// 所有开关都持久化到 UserDefaults，并被 AgentClient / SystemTools 实时读取。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // ---- API 配置 ----
    @Published var baseURL: String { didSet { d.set(baseURL, forKey: "baseURL") } }
    @Published var apiKey: String  { didSet { d.set(apiKey, forKey: "apiKey") } }
    @Published var model: String   { didSet { d.set(model, forKey: "model") } }

    // ---- 系统能力开关 ----
    @Published var enableReminders: Bool { didSet { d.set(enableReminders, forKey: "enableReminders") } }
    @Published var enableCalendar: Bool  { didSet { d.set(enableCalendar, forKey: "enableCalendar") } }
    @Published var enableHealth: Bool    { didSet { d.set(enableHealth, forKey: "enableHealth") } }
    @Published var enableAlarm: Bool     { didSet { d.set(enableAlarm, forKey: "enableAlarm") } }
    @Published var enableContacts: Bool  { didSet { d.set(enableContacts, forKey: "enableContacts") } }

    // ---- 授权状态（用于 UI 展示）----
    @Published var authReminders: String { didSet { d.set(authReminders, forKey: "authReminders") } }
    @Published var authCalendar: String  { didSet { d.set(authCalendar, forKey: "authCalendar") } }
    @Published var authHealth: String    { didSet { d.set(authHealth, forKey: "authHealth") } }
    @Published var authAlarm: String     { didSet { d.set(authAlarm, forKey: "authAlarm") } }

    private let d = UserDefaults.standard
    private let eventStore = EKEventStore()
    private let healthStore = HKHealthStore()

    init() {
        baseURL       = d.string(forKey: "baseURL") ?? "https://api.openai.com/v1"
        apiKey        = d.string(forKey: "apiKey") ?? ""
        model         = d.string(forKey: "model") ?? "deepseek-chat"
        enableReminders = d.bool(forKey: "enableReminders")
        enableCalendar  = d.bool(forKey: "enableCalendar")
        enableHealth    = d.bool(forKey: "enableHealth")
        enableAlarm     = d.bool(forKey: "enableAlarm")
        enableContacts  = d.bool(forKey: "enableContacts")
        authReminders = d.string(forKey: "authReminders") ?? "unknown"
        authCalendar  = d.string(forKey: "authCalendar") ?? "unknown"
        authHealth    = d.string(forKey: "authHealth") ?? "unknown"
        authAlarm     = d.string(forKey: "authAlarm") ?? "unknown"
    }

    // MARK: - 权限请求（在开关打开时调用）

    func requestReminders() {
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToReminders()
                await MainActor.run {
                    authReminders = granted ? "granted" : "denied"
                    if !granted { enableReminders = false }
                }
            } catch {
                await MainActor.run { authReminders = "denied"; enableReminders = false }
            }
        }
    }

    func requestCalendar() {
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                await MainActor.run {
                    authCalendar = granted ? "granted" : "denied"
                    if !granted { enableCalendar = false }
                }
            } catch {
                await MainActor.run { authCalendar = "denied"; enableCalendar = false }
            }
        }
    }

    func requestHealth() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authHealth = "denied"; enableHealth = false
            return
        }
        let types: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .bodyMass)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        Task {
            do {
                try await healthStore.requestAuthorization(toShare: [], read: types)
                let st = healthStore.authorizationStatus(for: HKObjectType.quantityType(forIdentifier: .stepCount)!)
                await MainActor.run {
                    authHealth = (st == .sharingAuthorized) ? "granted" : "denied"
                    if st != .sharingAuthorized { enableHealth = false }
                }
            } catch {
                await MainActor.run { authHealth = "denied"; enableHealth = false }
            }
        }
    }

    func requestAlarm() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run {
                    authAlarm = granted ? "granted" : "denied"
                    if !granted { enableAlarm = false }
                }
            } catch {
                await MainActor.run { authAlarm = "denied"; enableAlarm = false }
            }
        }
    }
}
