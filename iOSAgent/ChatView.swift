import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String  // "user" | "assistant"
    let text: String
}

/// 对话页：文本对话 + 相册截图视觉识别 + 调用云端模型。
/// 这是「看屏→识位」闭环的最小实现（截图由用户在系统/快捷指令截好后进相册，app 读取）。
struct ChatView: View {
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var attachedImage: UIImage?
    @State private var isBusy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let img = attachedImage {
                HStack {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 80)
                        .cornerRadius(8)
                    Button("移除截图") { attachedImage = nil }
                    Spacer()
                }
                .padding(.horizontal)
            }

            Divider()

            HStack {
                AttachPhotoButton(image: $attachedImage)
                TextField("说点什么…", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(isBusy || input.isEmpty)
            }
            .padding()

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("Agent 对话")
    }

    @ViewBuilder
    func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer() }
            Text(m.text)
                .padding(10)
                .background(m.role == "user" ? Color.blue.opacity(0.18) : Color(.secondarySystemBackground))
                .cornerRadius(12)
            if m.role == "assistant" { Spacer() }
        }
    }

    func send() {
        let text = input
        guard !text.isEmpty else { return }
        input = ""
        let img = attachedImage
        messages.append(ChatMessage(role: "user", text: text))
        isBusy = true
        errorText = nil
        Task {
            do {
                let reply = try await AgentClient.shared.ask(text, image: img)
                messages.append(ChatMessage(role: "assistant", text: reply))
                attachedImage = nil
            } catch {
                errorText = error.localizedDescription
            }
            isBusy = false
        }
    }
}
