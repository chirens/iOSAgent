import SwiftUI
import UserNotifications
import Foundation

@main
struct iOSAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ChatStore.shared)
                .environmentObject(SettingsStore.shared)
                .environmentObject(NotificationsManager.shared)
                .tint(Color.brandAccent)
        }
    }
}

/// 全局未捕获 ObjC 异常处理 + 运行时关键错误落盘：
/// EventKit / CoreLocation / Photos 等系统库的内部 NSException 一旦抛出，Swift 的 try/catch 捕获不了，
/// 会直接终止进程；这里在最后一刻把异常名、reason、callStackSymbols 写入 Documents/crash.log，
/// 下次启动时由 SettingsView 顶卡显示，让用户/开发者看到真正的崩溃原因，避免连续多个版本"修了又闪"却不知道闪在哪。
enum CrashGuard {
    /// 启动时一次性安装全局 handler。
    static func install() {
        NSSetUncaughtExceptionHandler { exc in
            CrashGuard.persist(exc: exc)
        }
    }

    /// 记录 EventKit / 其它非致命内部错误（已被 ObjC 桥捕获，不会闪退，但仍要落盘）。
    static func logEventKitCrash(_ message: String) {
        write("CRASH [EventKit internal error]", body: message)
    }

    /// crash.log 路径（SettingsView 读取用）
    static var crashLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("crash.log")
    }

    private static func persist(exc: NSException) {
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        let body = """
        name:    \(exc.name.rawValue)
        reason:  \(exc.reason ?? "n/a")
        ---
        \(stack)
        """
        write("CRASH [ObjC NSException]", body: body)
    }

    /// 写入 Documents/crash.log（每次启动覆盖，只保留最后一次崩溃）。
    private static func write(_ title: String, body: String) {
        let url = crashLogURL
        let ts = ISO8601DateFormatter().string(from: Date())
        let content = "=== \(title) @ \(ts) ===\n\(body)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 进程启动第一件事：装全局 ObjC exception 拦截器
        // 这样 EventKit / CoreLocation 等库的内部 NSException 闪退前能落盘到 crash.log，
        // 下次启动 SettingsView 顶卡显示，让用户和开发者看到真正的崩溃原因。
        CrashGuard.install()

        UNUserNotificationCenter.current().delegate = self
        NotificationsManager.shared.ensureCategory()
        Task { @MainActor in
            SettingsStore.shared.refreshAuthStatuses()
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 回前台重新确认常亮开关（系统会在后台重置 idle timer 行为）
        UIApplication.shared.isIdleTimerDisabled = SettingsStore.shared.keepAwakeEnabled
        SettingsStore.shared.refreshAuthStatuses()
        NotificationsManager.shared.refreshPending()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // 入后台释放常亮，避免系统层面被判定为异常持锁
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
