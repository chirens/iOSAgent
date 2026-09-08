import SwiftUI
import UserNotifications
import ObjectiveC

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

/// 全局未捕获 ObjC 异常 / Swift 致命错误处理：
/// EventKit / CoreLocation / Photos 等系统库的内部 NSException 一旦抛出，Swift 的 try/catch 捕获不了，
/// 会直接终止进程；这里在最后一刻把异常名、reason、callStackSymbols 写入 Documents/crash.log，
/// 下次启动时由 SettingsView 顶卡显示，让用户/开发者看到真正的崩溃原因，避免连续多个版本"修了又闪"却不知道闪在哪。
enum CrashGuard {
    /// 启动时一次性安装全局 handler。
    static func install() {
        let previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exc in
            CrashGuard.persist(exc: exc)
            // 调用系统默认行为（让进程真的崩，但日志已落盘）
            previous?(exc)
        }
        // Swift fatalError / 断言失败
        Swift.setFatalErrorCallback { message, file, line, flags in
            CrashGuard.persistSwift(message: message, file: file, line: line)
        }
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

    private static func persistSwift(message: String, file: String, line: UInt) {
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        let body = """
        message: \(message)
        at:      \(file):\(line)
        ---
        \(stack)
        """
        write("CRASH [Swift fatalError]", body: body)
    }

    /// 写入 Documents/crash.log（每次启动覆盖，只保留最后一次崩溃）。
    private static func write(_ title: String, body: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("crash.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let content = "=== \(title) @ \(ts) ===\n\(body)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 进程启动第一件事：装全局 ObjC exception + Swift fatalError 拦截器
        // 这样无论是 EventKit 的 NSException 还是其他 Swift fatal 都能在闪退前落盘。
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
