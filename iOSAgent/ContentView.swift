import SwiftUI
import EventKit

// 对话导航目标（被 NavigationStack path 使用）
enum ChatRoute: Hashable {
    case chat(UUID)
    case reminders
    case filesHistory
}

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @State private var showSideMenu = false
    @State private var showSettings = false
    @State private var path = NavigationPath()

    var body: some View {
        ZStack {
            ChatRootView(onMenu: { withAnimation(.spring()) { showSideMenu = true } }, path: $path)

            if showSettings {
                SettingsRootView(onBack: { withAnimation(.spring()) { showSettings = false } })
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showSettings)
        .overlay {
            if showSideMenu {
                SideMenuOverlay(isPresented: $showSideMenu, path: $path, onSettings: { showSettings = true })
                    .zIndex(3)
                    .transition(.move(edge: .leading))
            }
            if !settings.hasSeenWelcome {
                WelcomeOverlay {
                    withAnimation(.easeInOut) { settings.hasSeenWelcome = true }
                }
                .transition(.opacity)
                .zIndex(4)
            }
        }
    }
}

// MARK: - 对话 Tab

struct ChatRootView: View {
    @EnvironmentObject var store: ChatStore
    let onMenu: () -> Void
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            ChatRootList(path: $path)
                .navigationTitle("iOSAgent")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onMenu()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(10)
                                .background(Color(.systemBackground))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            let id = store.newConversation()
                            path.removeLast(path.count)
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
                    case .filesHistory:
                        FilesHistoryView()
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

struct ConversationRow: View {
    let conversation: Conversation
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let last = conversation.messages.last {
                Text(last.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - 左侧抽屉

struct SideMenuOverlay: View {
    @Binding var isPresented: Bool
    @Binding var path: NavigationPath
    var onSettings: () -> Void
    @EnvironmentObject var store: ChatStore

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        sideMenuHeader
                        sideMenuList
                        Spacer(minLength: 0)
                        sideMenuFooter
                    }
                    .frame(width: min(geo.size.width * 0.78, 320))
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 8, y: 0)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var sideMenuHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("iOSAgent")
                    .font(.title3.weight(.bold))
                Text("本地 AI 助手 · 可操作 iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var sideMenuList: some View {
        List {
            Section {
                SideMenuButton(icon: "plus", color: .blue, title: "新建对话") {
                    let id = store.newConversation()
                    path.removeLast(path.count)
                    path.append(ChatRoute.chat(id))
                    isPresented = false
                }
                if !store.sorted.isEmpty {
                    ForEach(store.sorted) { conversation in
                        SideMenuButton(icon: "bubble.left", color: .indigo, title: conversation.title) {
                            path.append(ChatRoute.chat(conversation.id))
                            isPresented = false
                        }
                    }
                } else {
                    Text("暂无历史对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("对话")
            }

            Section {
                SideMenuButton(icon: "checkmark.square.fill", color: .green, title: "待办 / 提醒") {
                    path.append(ChatRoute.reminders)
                    isPresented = false
                }
            } header: {
                Text("效率")
            }

            Section {
                SideMenuButton(icon: "folder.fill", color: .orange, title: "生成文件") {
                    path.append(ChatRoute.filesHistory)
                    isPresented = false
                }
            } header: {
                Text("创作")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
    }

    private var sideMenuFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                isPresented = false
                onSettings()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.gray)
                    }
                    Text("设置")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
    }
}

struct SideMenuButton: View {
    let icon: String
    let color: Color
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 生成文件历史

struct FilesHistoryView: View {
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty {
                Section {
                    Text("还没有生成文件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            } else {
                Section {
                    ForEach(files, id: \.self) { url in
                        HStack(spacing: 12) {
                            Image(systemName: fileIcon(for: url))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(modifiedString(for: url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("生成文件")
        .onAppear { scanFiles() }
    }

    private func scanFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        files = urls.filter { ["txt", "pptx"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pptx": return "play.rectangle.fill"
        case "txt": return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    private func modifiedString(for url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - 设置 Tab

struct SettingsRootView: View {
    let onBack: () -> Void
    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(8)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                }
        }
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
                        .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.85)], startPoint: .top, endPoint: .bottom))
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
