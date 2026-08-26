import SwiftUI
import EventKit

enum AppTab: String, CaseIterable {
    case chat, settings

    var title: String {
        switch self {
        case .chat: return "对话"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

enum ChatRoute: Hashable {
    case chat(UUID)
    case reminders
}

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @State private var selectedTab: AppTab = .chat

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .chat:
                    ChatRootView()
                case .settings:
                    SettingsRootView()
                }
            }
            .environmentObject(store)
            .environmentObject(settings)

            GlassTabBar(selected: $selectedTab)
                .padding(.horizontal, 28)
                .padding(.bottom, 10)
        }
        .overlay {
            if !settings.hasSeenWelcome {
                WelcomeOverlay {
                    withAnimation(.easeInOut) { settings.hasSeenWelcome = true }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}

// MARK: - 玻璃态底栏

struct GlassTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        selected = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(selected == tab ? .white : .primary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        selected == tab
                            ? Color.accentColor
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
    }
}

// MARK: - 首次启动欢迎页

struct WelcomeOverlay: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { }

            VStack(spacing: 0) {
                CapabilitiesView()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                Button {
                    onContinue()
                } label: {
                    Text("开始使用")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding()
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 30, x: 0, y: 10)
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 对话 Tab

struct ChatRootView: View {
    @EnvironmentObject var store: ChatStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ChatRootList(path: $path)
                .navigationTitle("对话")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            let id = store.newConversation()
                            path.append(ChatRoute.chat(id))
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                }
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .chat(let id):
                        ChatView(conversationId: id, path: $path)
                    case .reminders:
                        RemindersView()
                    }
                }
        }
    }
}

struct ChatRootList: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @Binding var path: NavigationPath
    @State private var reminders: [EKReminder] = []
    @State private var loadingReminders = false

    var body: some View {
        List {
            newConversationSection
            conversationsSection
            remindersSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
        .task { await loadReminders() }
        .refreshable { await loadReminders() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await loadReminders() }
        }
    }

    private var newConversationSection: some View {
        Section {
            Button {
                let id = store.newConversation()
                path.append(ChatRoute.chat(id))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                    Text("新建对话")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var conversationsSection: some View {
        Section {
            ForEach(store.sorted) { conversation in
                NavigationLink(value: ChatRoute.chat(conversation.id)) {
                    ConversationRow(conversation: conversation)
                }
            }
            .onDelete { indexSet in
                let ids = indexSet.map { store.sorted[$0].id }
                ids.forEach { store.delete($0) }
            }
        } header: {
            Text("历史对话")
        }
    }

    private var remindersSection: some View {
        Section {
            if !settings.isEnabled("reminders") {
                Text("在设置中开启“提醒事项”以查看待办")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else if reminders.isEmpty && !loadingReminders {
                Text("没有待完成的提醒")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(reminders.prefix(5), id: \.calendarItemIdentifier) { reminder in
                    MiniReminderRow(reminder: reminder) {
                        complete(reminder)
                    }
                }

                if reminders.count > 5 {
                    Button {
                        path.append(ChatRoute.reminders)
                    } label: {
                        Text("查看全部 \(reminders.count) 条")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        } header: {
            HStack {
                Text("提醒 / 待办")
                Spacer()
                if loadingReminders {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        }
    }

    private func loadReminders() async {
        guard settings.isEnabled("reminders") else { return }
        loadingReminders = true
        defer { loadingReminders = false }

        let store = settings.eventStore
        let calendars = store.calendars(for: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let items = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
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
            Task { await loadReminders() }
        } catch {
            // silent
        }
    }
}

struct MiniReminderRow: View {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title ?? "无标题")
                    .font(.subheadline.weight(.medium))
                if let dueText = dueString {
                    Text(dueText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var dueString: String? {
        guard let date = reminder.dueDateComponents?.date else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - 设置 Tab

struct SettingsRootView: View {
    var body: some View {
        NavigationStack {
            SettingsView()
        }
    }
}
