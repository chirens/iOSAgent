import Foundation
import SwiftUI
import Combine

/// 启动后与 GitHub 最新 Release 比对版本号：
/// - 发现新版本时，`updateAvailable` 置真，驱动「关于」页版本号旁的红点（直到本机版本追上 GitHub 版本才消失）；
/// - 对每个“新版本”只弹一次窗（`lastNotifiedVersion` 记已提示版本），用户选择“稍后”后红点保留但不再重复打扰。
@MainActor
final class VersionChecker: ObservableObject {
    static let shared = VersionChecker()

    @Published var latestVersion: String?
    @Published var updateAvailable: Bool = false
    @Published var isChecking: Bool = false
    /// 是否弹出“发现新版本”提示框（由 ContentView 的 .alert 消费）
    @Published var showUpdateAlert: Bool = false

    /// 当前 App 版本（取自 Info.plist CFBundleShortVersionString）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private let lastNotifiedKey = "velosLastNotifiedVersion"
    private let repoLatestURL = "https://api.github.com/repos/chirens/velos/releases/latest"

    /// 启动检查：拉取 GitHub 最新 Release 并比对。网络不可达时静默失败，不影响使用。
    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { Task { @MainActor in self.isChecking = false } }
            do {
                let tag = try await fetchLatestReleaseTag()
                let normalized = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                await MainActor.run { self.latestVersion = normalized }
                guard !normalized.isEmpty else { return }

                let hasUpdate = compare(normalized, currentVersion) > 0
                await MainActor.run { self.updateAvailable = hasUpdate }

                if hasUpdate {
                    let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedKey)
                    if lastNotified != normalized {
                        await MainActor.run { self.showUpdateAlert = true }
                        UserDefaults.standard.set(normalized, forKey: lastNotifiedKey)
                    }
                }
            } catch {
                // 网络不可达 / GitHub 被墙：保持 updateAvailable=false，无红点无弹窗
            }
        }
    }

    // MARK: - GitHub

    private func fetchLatestReleaseTag() async throws -> String {
        guard let url = URL(string: repoLatestURL) else {
            throw NSError(domain: "Version", code: 0, userInfo: [NSLocalizedDescriptionKey: "URL 非法"])
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw NSError(domain: "Version", code: 0, userInfo: [NSLocalizedDescriptionKey: "无法解析版本"])
        }
        return tag
    }

    // MARK: - 版本号比较（按 . 分段数值比较）

    /// 返回 >0 表示 lhs 比 rhs 新；=0 相同；<0 更旧。
    private func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").compactMap { Int($0) }
        let b = rhs.split(separator: ".").compactMap { Int($0) }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x - y }
        }
        return 0
    }
}
