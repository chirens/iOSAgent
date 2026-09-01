import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

enum PlusMenuState: Equatable {
    case closed
    case root
    case skills
    case models
}

struct ChatView: View {
    let conversationId: UUID
    @Binding var path: NavigationPath
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
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

    // v7.8 + 号紧凑菜单：图片/文件/技能/模型
    @State private var plusMenu: PlusMenuState = .closed
    @State private var pinnedSkillID: String?

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
                .font(.appCaption())
                .foregroundStyle(Color.appError)
                .padding(.horizontal)
            }

            // 已选附件
            attachmentRow

            // 已激活技能提示（点按清除）
            if !activeSkills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(activeSkills) { skill in
                        Button {
                            pinnedSkillID = nil
                            activeSkills = []
                        } label: {
                            Label(skill.name, systemImage: skill.icon)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.brandAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.brandAccent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }

            // @技能 提示：输入以 @ 开头时可点选插入技能名
            if input.hasPrefix("@") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("指定技能：")
                            .font(.appCaption2())
                            .foregroundStyle(Color.appSecondaryText)
                        ForEach(SkillRouter.shared.allSkills) { skill in
                            Button {
                                input = "@\(skill.name) "
                            } label: {
                                Text("@\(skill.name)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.brandAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.brandAccent.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 4)
            }

            // + 号紧凑菜单面板（位于输入栏上方）
            if plusMenu != .closed {
                plusMenuPanel
                    .padding(.horizontal)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
            }

            // 输入栏
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        plusMenu = plusMenu == .closed ? .root : .closed
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.brandAccent)
                        .rotationEffect(.degrees(plusMenu != .closed ? 45 : 0))
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
                                    .font(.appCaption())
                                    .foregroundStyle(.white)
                            }
                        }
                }

                HStack(spacing: 8) {
                TextField("说点什么…（输入 @ 可指定技能）", text: $input, axis: .vertical)
                    .font(.appBody())
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
                .background(Color.appSurface)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(input.isEmpty ? Color.appSecondaryText : Color.brandAccent)
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
                        .foregroundStyle(Color.brandAccent)
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

    // MARK: - + 号紧凑菜单面板

    private var plusMenuPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch plusMenu {
            case .root:
                plusRow(icon: "photo.fill", title: "图片", chevron: false) {
                    showPhotoPicker = true
                    closePlus()
                }
                Divider()
                plusRow(icon: "doc.fill", title: "文件", chevron: false) {
                    showFilePicker = true
                    closePlus()
                }
                Divider()
                plusRow(icon: "sparkles", title: "技能", chevron: true) {
                    plusMenu = .skills
                }
                Divider()
                plusRow(icon: "cpu", title: "模型", chevron: true) {
                    plusMenu = .models
                }
            case .skills:
                plusBackRow
                Divider()
                ForEach(SkillRouter.shared.allSkills) { skill in
                    Button {
                        pinnedSkillID = skill.id
                        activeSkills = [skill]
                        closePlus()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: skill.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.brandAccent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name).font(.subheadline.weight(.medium))
                                Text(skill.description).font(.appCaption2()).foregroundStyle(Color.appSecondaryText)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    if skill.id != SkillRouter.shared.allSkills.last?.id { Divider() }
                }
            case .models:
                plusBackRow
                Divider()
                if settings.profiles.isEmpty {
                    Text("还没有保存的配置，请到 设置 → API 设置 添加")
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(.vertical, 8)
                }
                ForEach(settings.profiles) { p in
                    Button {
                        settings.setActiveProfile(p.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appSecondaryText)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name.isEmpty ? "未命名" : p.name).font(.subheadline.weight(.medium))
                                Text("\(p.modelName) · \(shortURL(p.baseURL))").font(.appCaption2()).foregroundStyle(Color.appSecondaryText)
                            }
                            Spacer()
                            if settings.activeProfile.id == p.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    if p.id != settings.profiles.last?.id { Divider() }
                }
            case .closed:
                EmptyView()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        )
    }

    private var plusBackRow: some View {
        Button {
            plusMenu = .root
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                Text("返回")
                Spacer()
            }
                .font(.appSubheadline())
                .foregroundStyle(Color.brandAccent)
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func plusRow(icon: String, title: String, chevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 26)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func closePlus() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            plusMenu = .closed
        }
    }

    private func shortURL(_ s: String) -> String {
        s.trimmingCharacters(in: ["/"]).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
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
            // 云端转写失败 → 回退本机语音识别
            do {
                let text = try await speech.transcribeFile(url: url)
                if awaitingVoice { input = text }
                awaitingVoice = false
            } catch {
                if speech.authorizationStatus != .authorized {
                    showMicError = true
                    errorText = "语音识别需要授权：请在系统设置中为「同步」开启“语音识别”权限。另外，当前云端 API（如 DeepSeek）通常不支持音频转写，建议改用支持 /audio/transcriptions 的接口（如 OpenAI）以获得更好效果。"
                } else {
                    errorText = "语音识别失败：\(error.localizedDescription)"
                }
                awaitingVoice = false
            }
        }
    }

    private func send() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let explicit = SkillRouter.shared.matchExplicit(input: raw)
        let text: String
        var skills: [Skill]
        if let e = explicit {
            text = SkillRouter.shared.stripSkillPrefix(raw)
            skills = e
        } else if let pid = pinnedSkillID,
                  let pinned = SkillRouter.shared.allSkills.first(where: { $0.id == pid }) {
            text = raw
            skills = [pinned]
        } else {
            text = raw
            skills = SkillRouter.shared.match(input: raw)
        }
        activeSkills = skills
        pinnedSkillID = nil
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
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(voice.isRecording ? Color.appError : Color.brandAccent)
            .padding(8)
            .background(voice.isRecording ? Color.appError.opacity(0.12) : Color.brandAccent.opacity(0.12))
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
    @State private var previewURL: PreviewItem?

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 28) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 5) {
                if let toolName = message.toolName {
                    Label(toolName, systemImage: "hammer.fill")
                        .font(.appCaption2().weight(.medium))
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(.horizontal, 14)
                }

                Text(message.content)
                    .font(.appBody())
                    .foregroundStyle(message.role == "user" ? .white : Color.appPrimaryText)
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
                            .font(.appCaption2())
                        Text("同步")
                            .font(.appCaption2().weight(.medium))
                    }
                    .foregroundStyle(Color.appSecondaryText)
                    .padding(.leading, 4)
                }

                if let url = message.fileURL {
                    Button {
                        previewURL = PreviewItem(url: url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.viewfinder")
                            Text("打开文件")
                        }
                        .font(.appCaption().weight(.medium))
                        .foregroundStyle(Color.brandAccent)
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
        .sheet(item: $previewURL) { FilePreviewView(url: $0.url) }
    }

    private var contextMenu: some View {
        HStack(spacing: 8) {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case "user":
            return Color.brandAccent
        case "assistant":
            return Color.appSurface
        default:
            return Color.appInputFill
        }
    }

    private var attachmentRow: some View {
        Group {
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
                                .foregroundStyle(Color.appSecondaryText)
                            Text(name)
                                .font(.appCaption())
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.appInputFill)
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
