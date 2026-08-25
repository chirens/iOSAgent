import SwiftUI

enum SidebarItem: Hashable {
    case conversation(UUID)
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
            Section {
                Button {
                    let id = store.newConversation()
                    selectedItem = .conversation(id)
                } label: {
                    Label("新建对话", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .listRowBackground(Color.accentColor)
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
                .font(.headline)
                .lineLimit(1)
            Text(lastPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var lastPreview: String {
        let last = conversation.messages.last { !$0.content.isEmpty }
        return last?.content ?? "无消息"
    }
}
