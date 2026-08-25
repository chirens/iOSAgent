import SwiftUI
import EventKit

/// 左侧分栏：展示系统提醒事项中未完成/未来的提醒。
struct RemindersView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var reminders: [EKReminder] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if !settings.isEnabled("reminders") {
                    Section {
                        Text("请在设置中开启“提醒事项”能力")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = errorText {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                } else if reminders.isEmpty && !isLoading {
                    Section {
                        Text("没有待完成的提醒")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("待完成") {
                        ForEach(reminders, id: \.calendarItemIdentifier) { reminder in
                            ReminderRow(reminder: reminder) {
                                complete(reminder)
                            }
                        }
                    }
                }
            }
            .navigationTitle("提醒 / 待办")
            .refreshable {
                await load()
            }
            .task {
                await load()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await load() }
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
        HStack(spacing: 12) {
            Button(action: onComplete) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title ?? "无标题")
                    .font(.body)
                    .strikethrough(reminder.isCompleted)
                if let dueText = dueString {
                    Text(dueText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = reminder.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var dueString: String? {
        guard let date = reminder.dueDateComponents?.date else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
