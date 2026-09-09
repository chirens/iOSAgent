import SwiftUI
import UIKit
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
    @AppStorage("appColorScheme") private var appColorSchemeRaw: String = AppColorScheme.dark.rawValue
    @State private var showSideMenu = false
    @State private var showSettings = false
    @State private var showAccount = false
    @State private var path = NavigationPath()

    private var preferredScheme: ColorScheme? {
        switch AppColorScheme(rawValue: appColorSchemeRaw) ?? .dark {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// 使用期间禁止自动锁屏：息屏会让 iOS 挂起网络请求，导致 PPT/大文件下载中断。
    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepAwakeEnabled
    }

    var body: some View {
        ZStack {
            ChatRootView(onMenu: { withAnimation(.spring()) { showSideMenu = true } }, path: $path)

            if showSettings {
                SettingsRootView(onBack: { withAnimation(.spring()) { showSettings = false } })
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            }

            if showAccount {
                AccountRootView(onBack: { withAnimation(.spring()) { showAccount = false } })
                    .zIndex(2)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showSettings)
        .preferredColorScheme(preferredScheme)
        .onAppear { applyIdleTimer() }
        .onChange(of: settings.keepAwakeEnabled) { _ in applyIdleTimer() }
        .overlay {
            if showSideMenu {
                SideMenuOverlay(isPresented: $showSideMenu, path: $path, onSettings: { showSettings = true }, onAccount: { showAccount = true; showSideMenu = false })
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
    @Environment(\.colorScheme) private var colorScheme
    let onMenu: () -> Void
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            ChatRootList(path: $path)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
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
        // v9.0.12：删除 .toolbarBackground + .toolbarColorScheme，让 AppDelegate 全权负责
    }
}

struct ChatRootList: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @Binding var path: NavigationPath
    @State private var reminders: [EKReminder] = []
    @State private var loadingReminders = false
    @State private var reminderExpanded = false
    @State private var searchText = ""
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var shareText = ""
    @State private var shareFileURL: URL?
    @State private var showShare = false
    @State private var swipeExpandedID: UUID? = nil

    private var filteredConversations: [Conversation] {
        let nonempty = store.sorted.filter { !($0.title == "新对话" && $0.messages.isEmpty) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nonempty }
        return nonempty.filter { c in
            c.title.lowercased().contains(query) || c.messages.contains { $0.content.lowercased().contains(query) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                searchBar
                newConversationCard
                conversationsCard
                sectionDivider
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
        .sheet(isPresented: $showShare) {
            // 同时传文件 URL + 纯文本，让系统分享面板自适应：微信/邮件 → 文件；剪贴板/笔记 → 文本
            let items: [Any] = shareFileURL.map { [$0 as Any, shareText] } ?? [shareText]
            ShareSheet(activityItems: items)
        }
        .alert("重命名对话", isPresented: $showRename) {
            TextField("对话名称", text: $renameText)
            Button("保存") {
                if let id = renameTargetID {
                    store.rename(id, to: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入新的对话名称")
        }
    }

    private func exportConversation(_ c: Conversation) -> String {
        var lines = ["# \(c.title)", ""]
        lines.append("> 由 Velos 导出 · \(Self.shareDateFmt.string(from: Date()))")
        lines.append("")
        for m in c.messages where m.role != "tool" {
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let who = m.role == "user" ? "🧑 我" : "✨ Velos"
            lines.append("**\(who)**：")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 把 Markdown 字符串落盘到 Documents/ 目录，返回 URL；ShareSheet 同时拿到 fileURL 和 markdown 字符串，
    /// 系统会自动选最佳展示：微信/笔记 → 文件预览；剪贴板 → 纯文本；邮件 → 同时附文件 + 正文。
    private func exportConversationAsMarkdownFile(_ c: Conversation) -> URL {
        let md = exportConversation(c)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = c.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
        let fileName = "Velos对话_\(safe.isEmpty ? "未命名" : String(safe.prefix(30)))_\(Int(Date().timeIntervalSince1970)).md"
        let url = docs.appendingPathComponent(fileName)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let shareDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var searchBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appSecondaryText)
            TextField("搜索历史对话", text: $searchText)
                .font(.appBody())
                .foregroundStyle(Color.appPrimaryText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.appSecondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
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
            HStack {
                Text("历史对话")
                    .font(.appSubheadline().weight(.semibold))
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
                if !searchText.isEmpty {
                    Text("找到 \(filteredConversations.count) 条")
                        .font(.appCaption2())
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            .padding(.leading, AppSpacing.md)
            .padding(.trailing, AppSpacing.md)

            VStack(spacing: 0) {
                if filteredConversations.isEmpty {
                    Text(searchText.isEmpty ? "暂无历史对话" : "没有匹配到对话")
                        .font(.appSubheadline())
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.md)
                } else {
                    ForEach(filteredConversations) { conversation in
                        SwipeActionRow(
                            rowID: conversation.id,
                            expandedID: $swipeExpandedID,
                            onDelete: { store.delete(conversation.id) },
                            onRename: {
                                renameTargetID = conversation.id
                                renameText = conversation.title == "新对话" ? "" : conversation.title
                                showRename = true
                            },
                            onShare: {
                                shareText = exportConversation(conversation)
                                shareFileURL = exportConversationAsMarkdownFile(conversation)
                                showShare = true
                            }
                        ) {
                            Button {
                                path.append(ChatRoute.chat(conversation.id))
                            } label: {
                                ConversationRow(conversation: conversation)
                            }
                            .buttonStyle(.plain)
                        }
                        if conversation.id != filteredConversations.last?.id {
                            Divider().padding(.leading, AppSpacing.md)
                        }
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
                        .font(.appSubheadline().weight(.semibold))
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

    private var sectionDivider: some View {
        Divider()
            .background(Color.appSeparator)
            .padding(.vertical, AppSpacing.sm)
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

/// 自定义左滑操作行：`.swipeActions` 只在 `List` 里生效，首页历史对话是卡片式布局（VStack），
/// 故手动实现左滑露出「重命名 / 分享 / 删除」按钮。
/// 用父级 `expandedID` binding 实现多 row 互斥（一行展开时自动收起其他行），
/// 用 `highPriorityGesture` 让水平拖拽优先于 Button tap，避免误触发进入对话。
struct SwipeActionRow<Content: View>: View {
    let rowID: UUID
    @Binding var expandedID: UUID?
    let onDelete: () -> Void
    let onRename: () -> Void
    let onShare: () -> Void
    @State private var dragOffset: CGFloat = 0

    init(rowID: UUID,
         expandedID: Binding<UUID?>,
         onDelete: @escaping () -> Void,
         onRename: @escaping () -> Void,
         onShare: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.rowID = rowID
        self._expandedID = expandedID
        self.onDelete = onDelete
        self.onRename = onRename
        self.onShare = onShare
        self.content = content()
    }

    private let content: Content
    private let buttonWidth: CGFloat = 68
    private var actionWidth: CGFloat { buttonWidth * 3 }
    private var isExpanded: Bool { expandedID == rowID }
    private var displayOffset: CGFloat { (isExpanded ? -actionWidth : 0) + dragOffset }

    var body: some View {
        ZStack {
            // 透明点击层：展开时点击空白处收起
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isExpanded {
                        withAnimation(.easeOut(duration: 0.2)) { expandedID = nil }
                    }
                }
            // 背景操作按钮（右侧，左滑露出）
            HStack(spacing: 0) {
                Spacer()
                actionButton("重命名", systemImage: "pencil", color: Color.blue, action: onRename)
                actionButton("分享", systemImage: "square.and.arrow.up", color: Color.green, action: onShare)
                actionButton("删除", systemImage: "trash", color: Color.red, action: onDelete)
            }
            // 前景内容
            content
                .frame(maxWidth: .infinity)
                .background(Color.appSurface)
                .offset(x: displayOffset)
                .allowsHitTesting(!isExpanded)
        }
        .clipped()
        .highPriorityGesture(dragGesture)
    }

    private func actionButton(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: buttonWidth, height: 52)
            .background(color)
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dx = value.translation.width
                if isExpanded {
                    // 已展开：允许右滑关闭（dx > 0 → dragOffset 从 0 向 +actionWidth）
                    dragOffset = min(actionWidth, max(dx, -actionWidth))
                } else {
                    // 未展开：只允许左滑展开
                    if dx < 0 { dragOffset = max(dx, -actionWidth) }
                }
            }
            .onEnded { value in
                withAnimation(.easeOut(duration: 0.2)) {
                    if isExpanded {
                        // 已展开：右滑距离足够则收起，否则保持展开
                        if value.translation.width > 30 { expandedID = nil }
                    } else {
                        // 未展开：左滑距离足够则展开
                        if value.translation.width < -40 { expandedID = rowID }
                    }
                    dragOffset = 0
                }
            }
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
    var onAccount: () -> Void
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var shareText = ""
    @State private var shareFileURL: URL?
    @State private var showShare = false

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
                    // v9.0.12 完全去掉侧边栏阴影：Apple HIG 的 grouped 布局完全靠颜色差（#F2F2F7 vs #FFFFFF），
                    // 加阴影反而像浮起的铁板。这里保留 0.02/3px 极弱投影作为视觉收尾。
                    .shadow(color: Color.black.opacity(0.02), radius: 3, x: 2, y: 0)

                    Spacer(minLength: 0)
                }
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.width > 60 || value.translation.width < -60 {
                            isPresented = false
                        }
                    }
            )
        }
        .sheet(isPresented: $showShare) {
            // 同时传文件 URL + 纯文本，让系统分享面板自适应：微信/邮件 → 文件；剪贴板/笔记 → 文本
            let items: [Any] = shareFileURL.map { [$0 as Any, shareText] } ?? [shareText]
            ShareSheet(activityItems: items)
        }
        .alert("重命名对话", isPresented: $showRename) {
            TextField("对话名称", text: $renameText)
            Button("保存") {
                if let id = renameTargetID {
                    store.rename(id, to: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入新的对话名称")
        }
    }

    private func exportConversation(_ c: Conversation) -> String {
        var lines = ["# \(c.title)", ""]
        lines.append("> 由 Velos 导出 · \(Self.shareDateFmt.string(from: Date()))")
        lines.append("")
        for m in c.messages where m.role != "tool" {
            let text = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let who = m.role == "user" ? "🧑 我" : "✨ Velos"
            lines.append("**\(who)**：")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("> \(line)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 把 Markdown 字符串落盘到 Documents/ 目录，返回 URL；ShareSheet 同时拿到 fileURL 和 markdown 字符串，
    /// 系统会自动选最佳展示：微信/笔记 → 文件预览；剪贴板 → 纯文本；邮件 → 同时附文件 + 正文。
    private func exportConversationAsMarkdownFile(_ c: Conversation) -> URL {
        let md = exportConversation(c)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = c.title.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
        let fileName = "Velos对话_\(safe.isEmpty ? "未命名" : String(safe.prefix(30)))_\(Int(Date().timeIntervalSince1970)).md"
        let url = docs.appendingPathComponent(fileName)
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let shareDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var sideMenuHeader: some View {
        Button {
            onAccount()
        } label: {
            HStack(alignment: .center, spacing: AppSpacing.md) {
                AccountAvatarView(size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    if settings.isLoggedIn {
                        HStack(spacing: 6) {
                            if settings.accountProvider == .wechat { WechatBadge(size: 15) }
                            Text(settings.authDisplayName.isEmpty ? settings.authEmail : settings.authDisplayName)
                                .font(.appTitle3().weight(.bold))
                                .foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                        }
                    } else {
                        Text("未注册")
                            .font(.appTitle3().weight(.bold))
                            .foregroundStyle(Color.appPrimaryText)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondaryText)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarConversations: [Conversation] {
        store.sorted.filter { !($0.title == "新对话" && $0.messages.isEmpty) }
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
                    if !sidebarConversations.isEmpty {
                        ForEach(sidebarConversations) { conversation in
                            SideMenuButton(icon: "bubble.left", color: .pastelPurple, title: conversation.title) {
                                path.append(ChatRoute.chat(conversation.id))
                                isPresented = false
                            }
                            .contextMenu {
                                Button {
                                    renameTargetID = conversation.id
                                    renameText = conversation.title == "新对话" ? "" : conversation.title
                                    showRename = true
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button {
                                    shareText = exportConversation(conversation)
                                    showShare = true
                                } label: {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    store.delete(conversation.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            if conversation.id != sidebarConversations.last?.id {
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
            .background(Color.appSurface)
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
                // v9.0.12 同上：底色块改 tertiarySystemFill，icon 用饱和系统色 + hierarchical 渲染
                ZStack {
                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .symbolRenderingMode(.hierarchical)
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
    @Environment(\.colorScheme) private var colorScheme
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
                    case .skills: SkillsView()
                    case .account: AccountView()
                    case .crashLog: CrashLogView()
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
        // v9.0.12：删除 .toolbarBackground + .toolbarColorScheme，让 AppDelegate 全权负责
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
