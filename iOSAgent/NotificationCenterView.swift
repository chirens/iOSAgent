import SwiftUI

/// App 内通知中心：展示待触发的定时通知 + 历史通知（notify / 定时任务触发记录）。
struct NotificationCenterView: View {
    @StateObject private var notes = NotificationsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // 待触发
                sectionHeader("待触发通知", count: notes.pendingAlarms.count, icon: "alarm.fill")
                if notes.pendingAlarms.isEmpty {
                    emptyHint("还没有待触发的定时通知。让 Velos「每天 9 点提醒我开会」即可在此看到。")
                } else {
                    ForEach(notes.pendingAlarms) { a in
                        row(icon: "alarm", color: .pastelPurple, title: a.title,
                            subtitle: "\(formatFire(a.fireDate)) · 重复 \(repeatText(a.repeatPattern))")
                    }
                }

                // 历史
                sectionHeader("通知历史", count: notes.history.count, icon: "clock.fill")
                if notes.history.isEmpty {
                    emptyHint("还没有通知记录。用「发个通知」或安排定时任务后会出现在这里。")
                } else {
                    ForEach(notes.history) { item in
                        row(icon: item.kind == "task" ? "calendar" : "bell", color: .pastelBlue,
                            title: item.title, subtitle: "\(item.body)\n\(formatFire(item.date))")
                    }
                    Button {
                        notes.clearHistory()
                    } label: {
                        Text("清空历史")
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, AppSpacing.sm)
                    }
                }
            }
            .padding(AppSpacing.lg)
        }
        .background(Color.appBackground)
        .navigationTitle("通知中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Color.appSecondaryText) }
            }
        }
        .onAppear { notes.refreshPending() }
    }

    private func sectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: icon).foregroundStyle(Color.brandAccent)
            Text(title).font(.appHeadline()).foregroundStyle(Color.appText)
            Text("\(count)").font(.appCaption()).foregroundStyle(Color.appSecondaryText)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.brandAccent.opacity(0.12), in: Capsule())
        }
    }

    private func row(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.appBody()).foregroundStyle(Color.appText)
                Text(subtitle).font(.appCaption()).foregroundStyle(Color.appSecondaryText)
            }
            Spacer()
        }
        .padding(AppSpacing.md)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(.appCaption()).foregroundStyle(Color.appSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.md)
            .background(Color.appSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func formatFire(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    private func repeatText(_ p: String?) -> String {
        switch p {
        case "daily": return "每天"
        case "weekly": return "每周"
        case "weekdays": return "工作日"
        case "custom": return "自定义"
        default: return "一次"
        }
    }
}
