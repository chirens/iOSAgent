import Foundation

/// 一次工具调用（OpenAI function-calling 格式）
struct StoredToolCall: Codable {
    var id: String
    var name: String
    var arguments: String  // JSON 字符串
}

/// 一条对话消息，结构对齐 OpenAI 消息格式，便于直接序列化发往 API。
struct StoredMessage: Codable, Identifiable {
    var id = UUID()
    var role: String            // user | assistant | tool | system
    var content: String
    var toolCalls: [StoredToolCall]? = nil   // assistant 含工具调用时
    var toolCallId: String? = nil            // tool 消息对应
    var toolName: String? = nil
    var imageBase64: String? = nil           // 仅 user 消息可携带一张截图
    var fileURL: URL? = nil                  // 工具生成的本地文件
    var isStreaming: Bool = false            // 正在流式生成中
    var status: String? = nil                // 当前处理状态（如“模型思考中…”）
    var timestamp: Date = Date()             // 消息显示时间

    init(role: String, content: String, toolCalls: [StoredToolCall]? = nil,
         toolCallId: String? = nil, toolName: String? = nil, imageBase64: String? = nil, fileURL: URL? = nil,
         isStreaming: Bool = false, status: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.imageBase64 = imageBase64
        self.fileURL = fileURL
        self.isStreaming = isStreaming
        self.status = status
    }
}

/// 一个会话（可归档、可新建多个）
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredMessage]

    init(title: String = "新对话", messages: [StoredMessage] = []) {
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = messages
    }
}
