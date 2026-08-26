import SwiftUI
import EventKit

// 首页 → 子页 状态机
enum Screen: Hashable {
    case home, chat, settings
}

// 首页卡片导航目标
enum HomeRoute: Hashable {
    case chat, settings
}

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @State private var screen: Screen = .home

    var body: some View {
        ZStack {
            HomeHubView(select: { screen = $0 })
                .opacity(screen == .home ? 1 : 0)
                .allowsHitTesting(screen == .home)
                .zIndex(0)

            if screen == .chat {
                ChatRootView(onBack: { screen = .home })
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
            if screen == .settings {
                SettingsRootView(onBack: { screen = .home })
                    .zIndex(1)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: screen)
        .overlay {
            if !settings.hasSeenWelcome {
                WelcomeOverlay {
                    withAnimation(.easeInOut) { settings.hasSeenWelcome = true }
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
    }
}

// MARK: - 首页 Hub（双玻璃卡片 + 动态渐变背景）

struct HomeHubView: View {
    let select: (Screen) -> Void
    @State private var appear = false

    var body: some View {
        ZStack {
            LiquidBackground()
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.tint)
                        Text("iOSAgent")
                            .font(.largeTitle.weight(.bold))
                        Text("本地 AI 助手 · 可操作你的 iPhone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 56)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 18)

                    HomeCard(icon: "bubble.left.and.bubble.right.fill",
                             title: "对话",
                             subtitle: "与 AI 助手聊天、生成文件与 PPT",
                             color: .accentColor,
                             delay: 0.06) { select(.chat) }

                    HomeCard(icon: "gearshape.fill",
                             title: "设置",
                             subtitle: "API、系统权限、关于",
                             color: .orange,
                             delay: 0.16) { select(.settings) }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appear = true } }
    }
}

struct HomeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let delay: Double
    let action: () -> Void

    @State private var appear = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [color, color.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .glassCard()
            .scaleEffect(pressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 28)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay), value: appear)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .onAppear { appear = true }
    }
}

// MARK: - 液态玻璃动态背景（iOS16 用模糊色块近似，非 iOS26 GlassEffect）

struct LiquidBackground: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: w * 0.75, height: w * 0.75)
                    .blur(70)
                    .offset(x: animate ? w * 0.22 : -w * 0.2, y: -h * 0.08)
                Circle()
                    .fill(Color.pink.opacity(0.22))
                    .frame(width: w * 0.6, height: w * 0.6)
                    .blur(70)
                    .offset(x: animate ? -w * 0.25 : w * 0.25, y: h * 0.28)
                Circle()
                    .fill(Color.indigo.opacity(0.2))
                    .frame(width: w * 0.55, height: w * 0.55)
                    .blur(70)
                    .offset(x: 0, y: animate ? h * 0.22 : -h * 0.22)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - 复用：玻璃卡片样式

extension View {
    func glassCard() -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 22, x: 0, y: 10)
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

// MARK: - 对话 Tab

struct ChatRootView: View {
    @EnvironmentObject var store: ChatStore
    let onBack: () -> Void
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ChatRootList(path: $path)
                .navigationTitle("对话")
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
