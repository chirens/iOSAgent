import Foundation
import UIKit

/// 云端 API 客户端（OpenAI 兼容 /chat/completions，支持视觉多模态）。
/// MVP 用云端 API 快速验证；后续在此处增加「端侧模型路径」分支即可。
final class AgentClient {
    static let shared = AgentClient()
    private let session = URLSession.shared

    private init() {}

    /// 发送一条用户消息，可选附带一张图片（截图）走视觉通道。
    func ask(_ text: String, image: UIImage? = nil) async throws -> String {
        let defaults = UserDefaults.standard
        let base = (defaults.string(forKey: "baseURL") ?? "https://api.openai.com/v1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = defaults.string(forKey: "apiKey") ?? ""
        let model = (defaults.string(forKey: "model") ?? "gpt-4o-mini")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelFinal = model.isEmpty ? "gpt-4o-mini" : model

        guard !key.isEmpty else { throw AgentError.missingAPIKey }

        var messages: [[String: Any]] = [
            ["role": "system",
             "content": "你是一个运行在 iPhone 上的本地 agent 助手，帮助用户理解屏幕截图并操作手机与 App。请用简洁中文回答。"]
        ]

        if let image, let jpeg = image.jpegData(compressionQuality: 0.8) {
            let b64 = jpeg.base64EncodedString()
            let dataURL = "data:image/jpeg;base64,\(b64)"
            let content: [[String: Any]] = [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]
            messages.append(["role": "user", "content": content])
        } else {
            messages.append(["role": "user", "content": text])
        }

        let body: [String: Any] = [
            "model": modelFinal,
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.7
        ]

        guard let url = URL(string: base.trimmingCharacters(in: ["/"]) + "/chat/completions") else {
            throw AgentError.invalidResponse
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AgentError.http(http.statusCode, msg)
        }
        return try decode(data)
    }

    private func decode(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw AgentError.invalidResponse
        }
        return content
    }

    enum AgentError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "请先在「设置」中填写 API Key"
            case .invalidResponse: return "接口返回格式异常"
            case .http(let code, let msg): return "HTTP \(code): \(String(msg.prefix(200)))"
            }
        }
    }
}
