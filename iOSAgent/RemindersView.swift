import SwiftUI
import EventKit

/// 左侧分栏：展示系统提醒事项中未完成/未来的提醒。
struct RemindersView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var reminders: [EKReminder] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                Text("提醒 / 待办")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                if !settings.isEnabled("reminders") {
                    statusCard("请在设置中开启“提醒事项”能力")
                } else if let error = errorText {
                    statusCard(error, color: .appError)
                } else if reminders.isEmpty && !isLoading {
                    statusCard("没有待完成的提醒")
                } else {
                    remindersContent
                }
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(Color.appBackground)
        .refreshable { await load() }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
        .navigationTitle("提醒 / 待办")
    }

    private func statusCard(_ text: String, color: Color = .appSecondaryText) -> some View {
        Text(text)
            .font(.appSubheadline())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.lg)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appCardShadow()
    }

    private var remindersContent: some View {
        VStack(spacing: AppSpacing.xl) {
            let grouped = Dictionary(grouping: reminders, by: { $0.calendar?.title ?? "未分类" })
            let keys = grouped.keys.sorted()
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack {
                        Text(key)
                            .font(.appCaption().weight(.semibold))
                            .foregroundStyle(Color.appSecondaryText)
                        Spacer()
                        Text("\(grouped[key]?.count ?? 0)")
                            .font(.appSubheadline())
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    .padding(.horizontal, AppSpacing.lg)

                    VStack(spacing: 0) {
                        ForEach(grouped[key] ?? [], id: \.calendarItemIdentifier) { reminder in
                            ReminderRow(reminder: reminder) { complete(reminder) }
                            if reminder.calendarItemIdentifier != grouped[key]?.last?.calendarItemIdentifier {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
                    .appCardShadow()
                }
            }
        }
    }

    private func load() async {
        guard settings.isEnabled("reminders") else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let store = settings.eventStore
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)

        let items = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // 按到期时间排序，无到期时间的放最后
        reminders = items.sorted {
            let d1 = $0.dueDateComponents?.date ?? Date.distantFuture
            let d2 = $1.dueDateComponents?.date ?? Date.distantFuture
            return d1 < d2
        }
    }

    private func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        do {
            try settings.eventStore.save(reminder, commit: true)
            Task { await load() }
        } catch {
            errorText = "标记完成失败：\(error.localizedDescription)"
        }
    }
}

struct ReminderRow: View {
    let reminder: EKReminder
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            Button(action: onComplete) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.brandAccent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(reminder.title ?? "无标题")
                    .font(.appBody().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .strikethrough(reminder.isCompleted)
                if let dueText = dueString {
                    Text(dueText)
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.md)
        .contentShape(Rectangle())
    }

    private var dueString: String? {
        guard let date = reminder.dueDateComponents?.date else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
