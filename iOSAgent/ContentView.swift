import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ChatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
        } detail: {
            NavigationStack {
                if store.selectedId != nil {
                    ChatView()
                } else {
                    Text("选择或新建一个对话")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ChatView().id(id)
            }
        }
    }
}

/// 侧栏：会话列表（可切换/归档）+ 新建 + 设置入口
private struct Sidebar: View {
    @EnvironmentObject var store: ChatStore

    var body: some View {
        List(selection: $store.selectedId) {
            Section {
                Button {
                    store.newConversation()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                }
            }

            Section("会话") {
                ForEach(store.sorted) { conv in
                    NavigationLink(value: conv.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conv.title.isEmpty ? "新对话" : conv.title)
                                .lineLimit(1)
                            Text(relative(conv.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            store.delete(conv.id)
                        } label: { Label("归档 / 删除", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("iOSAgent")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                SettingsView()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.bar)
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: d, relativeTo: Date())
    }
}
