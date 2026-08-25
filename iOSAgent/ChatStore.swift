import Foundation
import Combine

/// 全局会话仓库：管理多会话、持久化到 Documents/conversations.json。
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published var conversations: [Conversation] = []
    @Published var selectedId: UUID?

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("conversations.json")
        load()
        if conversations.isEmpty {
            let c = Conversation()
            conversations = [c]
            selectedId = c.id
        } else if selectedId == nil {
            selectedId = conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = arr
    }

    func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    var selected: Conversation? {
        conversations.first(where: { $0.id == selectedId })
    }

    /// 新建会话并选中，返回其 id
    @discardableResult
    func newConversation() -> UUID {
        let c = Conversation()
        conversations.insert(c, at: 0)
        selectedId = c.id
        save()
        return c.id
    }

    /// 归档/删除会话（至少保留一个）
    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            conversations = [Conversation()]
        }
        if selectedId == id {
            selectedId = conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).first?.id
        }
        save()
    }

    /// 写回某会话的消息，并刷新标题/时间，置顶
    func update(_ id: UUID, messages: [StoredMessage]) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages = messages
        conversations[idx].updatedAt = Date()
        if conversations[idx].title == "新对话",
           let firstUser = messages.first(where: { $0.role == "user" && !$0.content.isEmpty }) {
            let t = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            conversations[idx].title = String(t.prefix(18))
        }
        let c = conversations.remove(at: idx)
        conversations.insert(c, at: 0)
        save()
    }

    /// 会话列表（按更新时间倒序）
    var sorted: [Conversation] {
        conversations.sorted(by: { $0.updatedAt > $1.updatedAt })
    }
}
