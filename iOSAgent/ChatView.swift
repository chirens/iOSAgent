import SwiftUI
import PhotosUI

struct ChatView: View {
    let conversationId: UUID
    @EnvironmentObject var store: ChatStore
    @StateObject private var speech = SpeechRecognizer()
    @State private var input = ""
    @State private var isLoading = false
    @State private var selectedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var errorText: String?
    @State private var scrollToBottom = false
    @State private var showMicError = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航：更紧凑
            HStack(spacing: 12) {
                Text(store.selected?.title ?? "对话")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    _ = store.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if isLoading {
                            HStack(spacing: 6) {
                                Dot()
                                Dot(delay: 0.15)
                                Dot(delay: 0.3)
                            }
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("typing")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 14)
                }
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: isLoading) { _ in
                    scrollToBottom(proxy)
                }
            }

            if let error = errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // 输入栏：圆角胶囊、更灵动
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                .onChange(of: photoItem) { item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            selectedImage = image
                        }
                    }
                }

                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { self.selectedImage = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                        }
                }

                HStack(spacing: 8) {
                    TextField("说点什么…", text: $input, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    // 语音按钮
                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: speech.isRecording ? "waveform" : "mic.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(speech.isRecording ? .red : Color.accentColor)
                            .padding(8)
                            .background(speech.isRecording ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Color(.systemBackground))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(input.isEmpty ? .secondary : Color.accentColor)
                }
                .disabled(input.isEmpty || isLoading)
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .id(conversationId)
        .alert("麦克风/语音识别未授权", isPresented: $showMicError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请在系统设置中为 iOSAgent 开启麦克风和语音识别权限。")
        }
        .onReceive(speech.transcriptPublisher) { text in
            self.input = text
        }
    }

    private var messages: [StoredMessage] {
        store.conversations.first(where: { $0.id == conversationId })?.messages ?? []
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else if isLoading {
            withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
        }
    }

    private func toggleRecording() {
        if speech.isRecording {
            speech.stopRecording()
        } else {
            Task {
                do {
                    try await speech.startRecording()
                } catch {
                    showMicError = true
                }
            }
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorText = nil
        input = ""
        speech.stopRecording()

        var msgs = messages
        msgs.append(StoredMessage(role: "user", content: text, imageBase64: nil))
        store.update(conversationId, messages: msgs)

        isLoading = true
        let image = selectedImage
        selectedImage = nil
        photoItem = nil

        Task {
            do {
                let (updated, final) = try await AgentClient.shared.run(
                    messages: msgs,
                    image: image,
                    tools: SettingsStore.shared.anyToolEnabled ? SystemTools.allTools : []
                )
                store.update(conversationId, messages: updated)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

struct MessageBubble: View {
    let message: StoredMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 28) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 5) {
                if let toolName = message.toolName {
                    Label(toolName, systemImage: "hammer.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                }

                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleBackground)
                    .foregroundStyle(message.role == "user" ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: message.role == "user" ? 22 : 18, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                    }

                if message.role == "assistant" {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                        Text("iOSAgent")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
            }
            .frame(maxWidth: 300, alignment: message.role == "user" ? .trailing : .leading)

            if message.role != "user" { Spacer(minLength: 28) }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case "user":
            return Color.accentColor
        case "assistant":
            return Color(.secondarySystemBackground)
        default:
            return Color(.tertiarySystemBackground)
        }
    }
}

struct Dot: View {
    let delay: Double
    init(delay: Double = 0) { self.delay = delay }
    @State private var scale: CGFloat = 0.5
    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(delay)) {
                    scale = 1.0
                }
            }
    }
}
