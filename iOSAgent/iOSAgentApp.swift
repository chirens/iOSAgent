import SwiftUI
import UserNotifications

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

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
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
