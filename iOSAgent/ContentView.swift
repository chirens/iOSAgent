import SwiftUI

enum SidebarItem: Hashable {
    case conversation(UUID)
    case reminders
    case capabilities
    case settings
}

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @State private var selectedItem: SidebarItem? = .capabilities

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedItem: $selectedItem)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .conversation(let id):
            ChatView(conversationId: id)
        case .reminders:
            RemindersView()
        case .capabilities, .none:
            CapabilitiesView()
        case .settings:
            SettingsView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: ChatStore
    @Binding var selectedItem: SidebarItem?

    var body: some View {
        List(selection: $selectedItem) {
            // 更紧凑的新建对话按钮
            Section {
                Button {
                    let id = store.newConversation()
                    selectedItem = .conversation(id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("新建对话")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.accentColor.opacity(0.10))
                .tag(Optional<SidebarItem>(nil))
            }

            Section("对话") {
                ForEach(store.sorted) { c in
                    ConversationRow(conversation: c)
                        .tag(SidebarItem.conversation(c.id))
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { store.sorted[$0].id }
                    ids.forEach { store.delete($0) }
                }
            }

            Section("更多") {
                Label("能力", systemImage: "sparkles.rectangle.stack.fill")
                    .tag(SidebarItem.capabilities)
                Label("提醒 / 待办", systemImage: "checklist.checked")
                    .tag(SidebarItem.reminders)
                Label("设置", systemImage: "gear")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("iOSAgent")
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(lastPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    private var lastPreview: String {
        let last = conversation.messages.last { !$0.content.isEmpty }
        return last?.content ?? "无消息"
    }
}
