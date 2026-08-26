import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ChatView: View {
    let conversationId: UUID
    @Binding var path: NavigationPath
    @EnvironmentObject var store: ChatStore
    @StateObject private var voice = VoiceRecorder()
    @StateObject private var speech = SpeechRecognizer()
    @State private var input = ""
    @State private var isLoading = false
    @State private var selectedImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var errorText: String?
    @State private var scrollToBottom = false
    @State private var showMicError = false
    /// 语音识别结果是否“待落框”：用于避免识别结果在发送之后才回调时把文字回填输入框
    @State private var awaitingVoice = false
    /// 发送后强制 TextField 重建以读取空值（根治 iOS 多行 TextField 焦点下不清空的已知坑）
    @State private var inputID = UUID()

    // 文件附件（图片或任意本地文件）
    @State private var selectedFileURL: URL?
    @State private var selectedFileName: String?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var fileIsImage = false

    // v7.5 Skill 框架：当前消息命中的技能
    @State private var activeSkills: [Skill] = []

    var body: some View {
        VStack(spacing: 0) {
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

            // 已选附件
            if selectedImage != nil || selectedFileURL != nil {
                HStack(spacing: 10) {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else if let name = selectedFileName {
                        HStack(spacing: 6) {
                            Image(systemName: fileIcon)
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Button { clearAttachment() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // 已激活技能提示
            if !activeSkills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(activeSkills) { skill in
                        Label(skill.name, systemImage: skill.icon)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }

            // @技能 提示：输入以 @ 开头时列出可用技能
            if input.hasPrefix("@") {
                HStack(spacing: 6) {
                    Text("指定技能：")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(SkillRouter.shared.allSkills) { skill in
                        Text("@\(skill.name)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }

            // 输入栏
            HStack(spacing: 10) {
                Menu {
                    Button("图片") { showPhotoPicker = true }
                    Button("文件") { showFilePicker = true }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

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
                TextField("说点什么…（输入 @ 可指定技能）", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .id(inputID)

                    // 按住说话
                    VoiceButton(voice: voice,
                                onStart: {
                                    awaitingVoice = true
                                    Task { await voice.start() }
                                },
                                onFinish: { Task { await finishVoice() } })
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
            .overlay(alignment: .top) {
                Divider().opacity(0.3)
            }
        }
        .id(conversationId)
        .navigationTitle(store.selected?.title ?? "对话")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let id = store.newConversation()
                    path.removeLast(path.count)
                    path.append(ChatRoute.chat(id))
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
        }
        .alert("麦克风/语音识别未授权", isPresented: $showMicError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请在系统设置中为 同步 开启麦克风和语音识别权限。")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    clearAttachment()
                    selectedImage = image
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                let isImg = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
                    .flatMap { UTType($0)?.conforms(to: .image) } ?? false
                if isImg, let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                    clearAttachment()
                    selectedImage = img
                } else {
                    // 拷进 App 沙盒，避免安全作用域失效
                    let dst = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension((url.pathExtension.isEmpty ? "file" : url.pathExtension))
                    _ = try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                        clearAttachment()
                        selectedFileURL = dst
                        selectedFileName = name
                        fileIsImage = false
                    }
                }
            }
        }
        .onReceive(speech.$transcript) { text in
            if !text.isEmpty && awaitingVoice {
                self.input = text
            }
        }
    }

    private var fileIcon: String {
        guard let ext = selectedFileName?.components(separatedBy: ".").last?.lowercased() else { return "doc.fill" }
        switch ext {
        case "pdf": return "doc.fill"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        case "zip", "rar": return "archivebox.fill"
        case "mp3", "wav", "m4a": return "music.note"
        case "mp4", "mov": return "film.fill"
        default: return "doc.fill"
        }
    }

    private func clearAttachment() {
        selectedImage = nil
        selectedFileURL = nil
        selectedFileName = nil
        fileIsImage = false
        photoItem = nil
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

    private func finishVoice() async {
        guard let url = voice.stop() else { awaitingVoice = false; return }
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let text = try await AgentClient.shared.transcribe(audioURL: url)
            guard !text.isEmpty else {
                throw NSError(domain: "Voice", code: 0, userInfo: [NSLocalizedDescriptionKey: "未能识别到语音内容"])
            }
            if awaitingVoice { input = text }
            awaitingVoice = false
        } catch {
            // 服务端不可用则回退本地识别
            do {
                let text = try await speech.transcribeFile(url: url)
                if awaitingVoice { input = text }
                awaitingVoice = false
            } catch {
                errorText = "语音识别失败：\(error.localizedDescription)"
                showMicError = true
                awaitingVoice = false
            }
        }
    }

    private func send() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let explicit = SkillRouter.shared.matchExplicit(input: raw)
        let text: String
        if let skills = explicit {
            text = SkillRouter.shared.stripSkillPrefix(raw)
            activeSkills = skills
        } else {
            text = raw
            activeSkills = SkillRouter.shared.match(input: raw)
        }
        errorText = nil
        input = ""
        awaitingVoice = false
        inputID = UUID()
        voice.stop()

        guard !text.isEmpty else { return }

        var msgs = messages
        let imageToSend: UIImage? = selectedImage
        var fileNote: String?

        if let fileURL = selectedFileURL, let fileName = selectedFileName {
            // 文本类文件内联内容，便于模型理解；其它类型作为附件说明
            if let ext = fileName.components(separatedBy: ".").last?.lowercased(),
               ["txt", "md", "json", "csv", "html", "log"].contains(ext),
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                fileNote = "[已附加文件 \(fileName)：\n\(content.prefix(4000))]\n"
            } else {
                fileNote = "[用户附加了本地文件：\(fileName)，请在回复中说明已收到，文件可在聊天中分享]"
            }
        }

        let composed = (fileNote ?? "") + text
        msgs.append(StoredMessage(role: "user", content: composed, imageBase64: nil))
        store.update(conversationId, messages: msgs)

        isLoading = true
        selectedImage = nil
        selectedFileURL = nil
        selectedFileName = nil
        photoItem = nil

        Task {
            do {
                let (updated, _) = try await AgentClient.shared.run(
                    messages: msgs,
                    image: imageToSend,
                    tools: SettingsStore.shared.anyToolEnabled ? SystemTools.allTools : [],
                    activeSkills: activeSkills
                )
                store.update(conversationId, messages: updated)
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// 语音按钮独立成子视图，避免输入栏 HStack 表达式过大导致编译器无法在合理时间内类型检查
struct VoiceButton: View {
    @ObservedObject var voice: VoiceRecorder
    let onStart: () -> Void
    let onFinish: () -> Void

    var body: some View {
        Image(systemName: voice.isRecording ? "waveform.circle.fill" : "mic.fill")
            .font(.system(size: 18))
            .foregroundStyle(voice.isRecording ? .red : Color.accentColor)
            .padding(8)
            .background(voice.isRecording ? Color.red.opacity(0.12) : Color.accentColor.opacity(0.12))
            .clipShape(Circle())
            .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: { pressing in
                if pressing {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onStart()
                } else {
                    onFinish()
                }
            })
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
                    .foregroundStyle(message.role == "user" ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .circular)
                            .fill(bubbleBackground)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
                    .textSelection(.enabled)

                if message.role == "assistant" {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.caption2)
                        Text("同步")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }

                if let url = message.fileURL {
                    ShareLink(item: url) {
                        Label("分享文件", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.leading, 4)
                }

                if message.role == "tool" {
                    contextMenu
                }
            }
            .frame(maxWidth: 300, alignment: message.role == "user" ? .trailing : .leading)

            if message.role != "user" { Spacer(minLength: 28) }
        }
    }

    private var contextMenu: some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
