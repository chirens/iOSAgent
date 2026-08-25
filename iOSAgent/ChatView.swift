import SwiftUI

/// 对话页：多会话、支持截图视觉识别、并触发 agent 工具调用循环。
struct ChatView: View {
    @EnvironmentObject var store: ChatStore
    @State private var input = ""
    @State private var attachedImage: UIImage?
    @State private var isBusy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(displayMessages) { m in
                            row(m).id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.selected?.messages.count ?? 0) { _, _ in
                    if let last = displayMessages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if let img = attachedImage {
                HStack {
                    Image(uiImage: img).resizable().scaledToFit().frame(height: 80).cornerRadius(8)
                    Button("移除截图") { attachedImage = nil }
                    Spacer()
                }
                .padding(.horizontal)
            }

            Divider()

            HStack {
                AttachPhotoButton(image: $attachedImage)
                TextField("说点什么…（如：明早 8 点提醒我开会）", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button { send() } label: { Image(systemName: "paperplane.fill") }
                    .disabled(isBusy || input.isEmpty)
                if isBusy { ProgressView() }
            }
            .padding()

            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }
        }
        .navigationTitle(store.selected?.title ?? "对话")
    }

    /// 用于展示的消息：用户消息、以及有内容的助手消息；
    /// 助手"仅调用工具"的中间消息显示为一行工具提示；纯 tool 消息隐藏。
    private var displayMessages: [StoredMessage] {
        guard let msgs = store.selected?.messages else { return [] }
        return msgs.filter { m in
            if m.role == "user" { return true }
            if m.role == "assistant" { return !m.content.isEmpty || (m.toolCalls?.isEmpty == false) }
            return false
        }
    }

    @ViewBuilder
    private func row(_ m: StoredMessage) -> some View {
        if m.role == "user" {
            HStack {
                Spacer()
                Text(m.content).padding(10)
                    .background(Color.blue.opacity(0.18)).cornerRadius(12)
            }
        } else if let tcs = m.toolCalls, m.content.isEmpty {
            HStack {
                Text("🛠 调用工具：" + tcs.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            HStack {
                Text(m.content).padding(10)
                    .background(Color(.secondarySystemBackground)).cornerRadius(12)
                Spacer()
            }
        }
    }

    private func send() {
        guard let convId = store.selectedId else { return }
        let text = input
        guard !text.isEmpty else { return }
        input = ""
        let img = attachedImage
        var msgs = store.selected?.messages ?? []
        var userMsg = StoredMessage(role: "user", content: text)
        if let img, let jpeg = img.jpegData(compressionQuality: 0.8) {
            userMsg.imageBase64 = jpeg.base64EncodedString()
        }
        msgs.append(userMsg)
        isBusy = true
        errorText = nil
        let cid = convId
        Task {
            do {
                let tools = SystemTools.activeTools()
                let (newMsgs, _) = try await AgentClient.shared.run(messages: msgs, image: img, tools: tools)
                await MainActor.run {
                    store.update(cid, messages: newMsgs)
                    attachedImage = nil
                    isBusy = false
                }
            } catch {
                await MainActor.run { errorText = error.localizedDescription; isBusy = false }
            }
        }
    }
}
