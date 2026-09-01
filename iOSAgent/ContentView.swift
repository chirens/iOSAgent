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
                .navigationTitle("同步")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onMenu()
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.appPrimaryText)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            let id = store.newConversation()
                            path.removeLast(path.count)
                            path.append(ChatRoute.chat(id))
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.brandAccent)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
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
                .overlay(alignment: .leading) {
                    if path.count == 0 {
                        Color.clear
                            .frame(width: 44)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture()
                                    .onEnded { value in
                                        if value.translation.width > 50 {
                                            onMenu()
                                        }
                                    }
                            )
                    }
                }
        }
        .background(Color.appBackground)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct ChatRootList: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @Binding var path: NavigationPath
    @State private var reminders: [EKReminder] = []
    @State private var loadingReminders = false
    @State private var reminderExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                newConversationCard
                conversationsCard
                remindersCard
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .refreshable { await loadReminders() }
        .task { await loadReminders() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await loadReminders() }
        }
    }

    private var newConversationCard: some View {
        VStack(spacing: 0) {
            Button {
                let id = store.newConversation()
                path.append(ChatRoute.chat(id))
            } label: {
                HStack(spacing: AppSpacing.md) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.brandAccent)
                    Text("新建对话")
                        .font(.appSubheadline().weight(.semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appSecondaryText)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private var conversationsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("历史对话")
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
                .padding(.leading, AppSpacing.md)

            VStack(spacing: 0) {
                ForEach(store.sorted) { conversation in
                    Button {
                        path.append(ChatRoute.chat(conversation.id))
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.delete(conversation.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    if conversation.id != store.sorted.last?.id {
                        Divider().padding(.leading, AppSpacing.md)
                    }
                }
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()
        }
    }

    private var remindersCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reminderExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("提醒 / 待办")
                        .font(.appCaption2().weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer()
                    if !reminders.isEmpty {
                        Text("\(reminders.count)")
                            .font(.appSubheadline())
                            .foregroundStyle(Color.appSecondaryText)
                    }
                    if loadingReminders {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appSecondaryText)
                        .rotationEffect(.degrees(reminderExpanded ? 0 : -90))
                }
                .padding(.leading, AppSpacing.md)
                .padding(.vertical, AppSpacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if reminderExpanded {
                VStack(spacing: 0) {
                    if !settings.isEnabled("reminders") {
                        Text("在设置中开启“提醒事项”以查看待办")
                            .font(.appSubheadline())
                            .foregroundStyle(Color.appSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.md)
                    } else if reminders.isEmpty && !loadingReminders {
                        Text("没有待完成的提醒")
                            .font(.appSubheadline())
                            .foregroundStyle(Color.appSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.md)
                    } else {
                        ForEach(reminders.prefix(5), id: \.calendarItemIdentifier) { reminder in
                            MiniReminderRow(reminder: reminder) { complete(reminder) }
                            if reminder.calendarItemIdentifier != reminders.prefix(5).last?.calendarItemIdentifier {
                                Divider().padding(.leading, 44)
                            }
                        }
                        if reminders.count > 5 {
                            Button {
                                path.append(ChatRoute.reminders)
                            } label: {
                                Text("查看全部 \(reminders.count) 条")
                                    .font(.appSubheadline().weight(.medium))
                                    .foregroundStyle(Color.brandAccent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.md)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                .appCardShadow()
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
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(conversation.title)
                .font(.appSubheadline().weight(.semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
            if let last = conversation.messages.last {
                Text(last.content)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MiniReminderRow: View {
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
                    .font(.appSubheadline().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                if let dueText = dueString {
                    Text(dueText)
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
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
                    .background(Color.appSurface)
                    .shadow(color: .black.opacity(0.3), radius: 16, x: 8, y: 0)

                    Spacer(minLength: 0)
                }
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.width > 60 {
                            isPresented = false
                        }
                    }
            )
        }
    }

    private var sideMenuHeader: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .fill(Color.brandAccent)
                    .frame(width: 44, height: 44)
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text("同步")
                    .font(.appTitle3().weight(.bold))
                    .foregroundStyle(Color.appPrimaryText)
                Text("本地 AI Agent · 可操作 iPhone")
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.top, AppSpacing.xl)
        .padding(.bottom, AppSpacing.md)
    }

    private var sideMenuList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                SideMenuSection(title: "对话") {
                    SideMenuButton(icon: "plus", color: .pastelBlue, title: "新建对话") {
                        let id = store.newConversation()
                        path.removeLast(path.count)
                        path.append(ChatRoute.chat(id))
                        isPresented = false
                    }
                    if !store.sorted.isEmpty {
                        ForEach(store.sorted) { conversation in
                            SideMenuButton(icon: "bubble.left", color: .pastelPurple, title: conversation.title) {
                                path.append(ChatRoute.chat(conversation.id))
                                isPresented = false
                            }
                            if conversation.id != store.sorted.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    } else {
                        Text("暂无历史对话")
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.sm)
                    }
                }

                SideMenuSection(title: "效率") {
                    SideMenuButton(icon: "checkmark.square.fill", color: .pastelGreen, title: "待办 / 提醒") {
                        path.append(ChatRoute.reminders)
                        isPresented = false
                    }
                }

                SideMenuSection(title: "创作") {
                    SideMenuButton(icon: "folder.fill", color: .pastelOrange, title: "文件") {
                        path.append(ChatRoute.filesHistory)
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, AppSpacing.xl)
        }
    }

    private var sideMenuFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, AppSpacing.lg)
            Button {
                isPresented = false
                onSettings()
            } label: {
                HStack {
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                            .fill(Color.appInputFill)
                            .frame(width: 32, height: 32)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct SideMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
                .padding(.leading, AppSpacing.md)

            VStack(spacing: 0) {
                content
            }
            .padding(.vertical, AppSpacing.xs)
            .background(Color(hex: "2C2C2E"))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()
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
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(color.opacity(0.22))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.appSubheadline().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 生成文件历史

struct FilesHistoryView: View {
    @State private var files: [URL] = []
    @State private var previewURL: PreviewItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("文件")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                if files.isEmpty {
                    Text("还没有文件")
                        .font(.appSubheadline())
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(AppSpacing.xl)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .appCardShadow()
                } else {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: AppSpacing.md) {
                                Button {
                                    previewURL = PreviewItem(url: url)
                                } label: {
                                    HStack(spacing: AppSpacing.md) {
                                        Image(systemName: fileIcon(for: url))
                                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                                            .foregroundStyle(Color.brandAccent)
                                            .frame(width: 32, height: 32)
                                            .background(Color.brandAccent.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                            Text(url.lastPathComponent)
                                                .font(.appSubheadline().weight(.semibold))
                                                .foregroundStyle(Color.appPrimaryText)
                                                .lineLimit(1)
                                            Text(modifiedString(for: url))
                                                .font(.appCaption())
                                                .foregroundStyle(Color.appSecondaryText)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(Color.brandAccent)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.sm)
                            if url != files.last {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .appCardShadow()
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .navigationTitle("文件")
        .onAppear { scanFiles() }
        .sheet(item: $previewURL) { FilePreviewView(url: $0.url) }
    }

    private func scanFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let allowed = ["txt", "md", "markdown", "csv", "json", "html", "htm", "rtf", "log", "xml", "yaml", "yml",
                       "pdf", "pptx", "doc", "docx", "xls", "xlsx",
                       "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }
        files = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pptx": return "play.rectangle.fill"
        case "pdf": return "doc.fill"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        case "txt", "md", "log", "rtf": return "doc.plaintext.fill"
        case "json", "html", "xml", "yaml", "yml": return "curlybraces"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo.fill"
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
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .api: APISettingsView()
                    case .permissions: PermissionsView()
                    case .customPrompt: CustomPromptView()
                    case .legal(let type): LegalView(type: type)
                    case .about: AboutView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.brandAccent)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    Color.clear
                        .frame(width: 44)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 16)
                                .onChanged { _ in }
                                .onEnded { value in
                                    if value.translation.width > 50 {
                                        onBack()
                                    }
                                }
                        )
                }
        }
        .background(Color.appBackground)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                        .font(.appBody().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Color.brandAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                .padding()
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 30, x: 0, y: 10)
            .padding(.horizontal, 20)
        }
    }
}
