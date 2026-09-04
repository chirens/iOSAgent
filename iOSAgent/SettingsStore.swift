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

/// 一个云端 API 配置（可保存多个，聊天中随时切换）
struct APIProfile: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var modelName: String
    var sttModelName: String

    static var `default`: APIProfile {
        APIProfile(id: "default", name: "默认配置",
                   baseURL: "https://api.deepseek.com",
                   apiKey: "", modelName: "deepseek-chat",
                   sttModelName: "whisper-1")
    }
}

/// 应用主题模式
enum AppColorScheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }
}

/// 全局设置与权限状态
@MainActor
class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("apiBaseURL") var apiBaseURL: String = "https://api.deepseek.com"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("modelName") var modelName: String = "deepseek-chat"
    @AppStorage("sttModelName") var sttModelName: String = "whisper-1"
    /// GitHub 访问令牌（可选）：用于提升 GitHub 搜索 / 安装接口限额（未认证仅 10 次/分钟，带令牌 30 次/分钟）。
    @AppStorage("githubToken") var githubToken: String = ""
    /// 远程执行服务地址（多租户后端，固定 https://velos.chen.cm）。
    @AppStorage("connectorEndpoint") var connectorEndpoint: String = "https://velos.chen.cm"
    /// 远程执行服务静态 API 密钥（BYOS 模式：服务器 REQUIRE_AUTH=false 时使用的简单密钥；与服务器 RELAY_SECRET 无关）。
    @AppStorage("connectorApiKey") var connectorApiKey: String = ""

    /// 主题模式：浅色 / 深色 / 跟随系统（默认深色，与 v8.9.2 之前一致）。
    @AppStorage("appColorScheme") var appColorSchemeRaw: String = AppColorScheme.dark.rawValue

    /// 当前主题偏好（供 UI 绑定）。
    var colorSchemePreference: AppColorScheme {
        AppColorScheme(rawValue: appColorSchemeRaw) ?? .dark
    }

    /// 用于 SwiftUI .preferredColorScheme 的值：system 返回 nil。
    var preferredColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
    /// 登录后由服务器签发的每用户 JWT（Bearer token）。仅在 connectorEndpoint 匹配的请求上自动附加。
    @AppStorage("authToken") var authToken: String = ""
    /// 当前登录用户名（仅展示用）。
    @AppStorage("authUser") var authUser: String = ""
    /// 当前登录用户邮箱（服务器登录标识，也用于展示）。
    @AppStorage("authEmail") var authEmail: String = ""
    /// 当前登录用户的显示昵称（可编辑，默认取自邮箱前缀）。
    @AppStorage("authDisplayName") var authDisplayName: String = ""
    /// 头像图片数据（JPEG/PNG），本地存储；登录态展示与侧边栏使用。
    @AppStorage("authAvatarData") var authAvatarData: Data = Data()
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false

    @Published var capabilities: [String: CapabilitySetting] = [:]

    // MARK: - 多 API 配置
    @Published var profiles: [APIProfile] = []
    @Published var activeProfileID: String = ""

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
        loadProfiles()
        refreshAuthStatuses()
    }

    // MARK: - API 配置持久化

    func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "apiProfiles"),
           let decoded = try? JSONDecoder().decode([APIProfile].self, from: data) {
            profiles = decoded
        } else {
            // 首次启动：用旧的单配置字段播种一个默认 profile
            let legacy = APIProfile(
                id: UUID().uuidString,
                name: "我的配置",
                baseURL: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey,
                modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                sttModelName: sttModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            profiles = [legacy]
        }
        activeProfileID = UserDefaults.standard.string(forKey: "activeProfileID") ?? profiles.first?.id ?? ""
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "apiProfiles")
        }
        UserDefaults.standard.set(activeProfileID, forKey: "activeProfileID")
    }

    /// 当前生效的配置（聊天/语音转写都读它）
    var activeProfile: APIProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first ?? APIProfile.default
    }

    /// 新增或更新一个配置；若当前没有激活项则自动激活
    func saveProfile(_ p: APIProfile) {
        var list = profiles
        if let idx = list.firstIndex(where: { $0.id == p.id }) {
            list[idx] = p
        } else {
            list.append(p)
        }
        profiles = list
        if activeProfileID.isEmpty { activeProfileID = p.id }
        persistProfiles()
    }

    func deleteProfile(_ id: String) {
        profiles = profiles.filter { $0.id != id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id ?? ""
        }
        persistProfiles()
    }

    func setActiveProfile(_ id: String) {
        activeProfileID = id
        persistProfiles()
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
        // 若授权后仍 notDetermined，多半是签名描述文件未含 HealthKit 能力，
        // 系统静默拒绝了授权请求（免费 Apple ID 侧载常见）。
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
           healthStore.authorizationStatus(for: stepType) == .notDetermined {
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

    // MARK: - 账户（远程执行服务，邮箱 + 密码）

    enum AccountAuthMode { case login, register }

    /// 登录或注册远程执行服务（多租户后端）。邮箱作为登录标识，成功后保存每用户 token。
    /// 返回 nil 表示成功，否则返回错误文案。
    func accountAuth(endpoint: String, email: String, password: String, displayName: String, mode: AccountAuthMode) async -> String? {
        let ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: ep), !ep.isEmpty else { return "服务器地址无效" }
        let path = mode == .login ? "auth/login" : "auth/register"
        guard let u = URL(string: base.absoluteString + (ep.hasSuffix("/") ? "" : "/") + path) else { return "服务器地址无效" }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mail.contains("@"), password.count >= 6 else {
            return mode == .login ? "请输入邮箱与密码（密码≥6）" : "请输入有效邮箱，密码≥6 字符"
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["email": mail, "password": password]
        if mode == .register, !displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            let dn = displayName.trimmingCharacters(in: .whitespaces)
            payload["displayName"] = String(dn.prefix(8))
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            struct Resp: Decodable { let token: String?; let email: String?; let username: String?; let error: String? }
            let r = try? JSONDecoder().decode(Resp.self, from: data)
            guard code == 200, let t = r?.token else {
                return "失败（\(code)）：" + (r?.error ?? "未知错误")
            }
            authToken = t
            authEmail = r?.email ?? mail
            let name = (r?.username ?? displayName.trimmingCharacters(in: .whitespaces)).prefix(8)
            authUser = String(name)
            authDisplayName = String(name)
            return nil
        } catch {
            return "网络错误：\(error.localizedDescription)"
        }
    }

    /// 更新昵称（displayName），同步到服务器；失败返回错误文案，成功返回 nil。
    func updateAccountProfile(displayName: String) async -> String? {
        let ep = connectorEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authToken.isEmpty, !ep.isEmpty,
              let base = URL(string: ep),
              let u = URL(string: base.absoluteString + (ep.hasSuffix("/") ? "" : "/") + "auth/profile") else {
            return "未登录或服务器地址未设置"
        }
        let dn = displayName.trimmingCharacters(in: .whitespaces)
        guard !dn.isEmpty, dn.count <= 8 else { return "用户名需为 1–8 字符" }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["displayName": dn])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            struct Resp: Decodable { let ok: Bool?; let username: String?; let error: String? }
            let r = try? JSONDecoder().decode(Resp.self, from: data)
            guard code == 200 else {
                return "失败（\(code)）：" + (r?.error ?? "未知错误")
            }
            authDisplayName = dn
            authUser = dn
            return nil
        } catch {
            return "网络错误：\(error.localizedDescription)"
        }
    }

    /// 退出登录（清掉 token 与本地身份信息，含头像）。
    func logoutAccount() {
        authToken = ""
        authUser = ""
        authEmail = ""
        authDisplayName = ""
        authAvatarData = Data()
    }

    var isLoggedIn: Bool { !authToken.isEmpty }
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
