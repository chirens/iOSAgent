import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

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
    // 观察技能路由，安装/删除用户技能后实时刷新
    @ObservedObject private var skillRouter = SkillRouter.shared

    // v7.8 + 号附件面板：图片/文件/技能/模型
    @State private var showAttachmentSheet = false
    @State private var pinnedSkillID: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(messages) { msg in
                            MessageBubble(
                                message: msg,
                                onResend: msg.role == "user" ? { resendMessage(msg) } : nil,
                                onRegenerate: msg.role == "assistant" ? { regenerate(from: msg) } : nil
                            )
                            .id(msg.id)
                        }
                        if isLoading {
                            HStack(spacing: 6) {
                                Dot()
                                Dot(delay: 0.15)
                                Dot(delay: 0.3)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("typing")
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.md)
                }
                .onChange(of: messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: messages.last?.content) { _ in
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
                                .background(Color.brandAccent.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.xs)
            }

            // @技能 提示：输入以 @ 开头时可点选插入技能名
            if input.hasPrefix("@") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("指定技能：")
                            .font(.appCaption2())
                            .foregroundStyle(Color.appSecondaryText)
                        ForEach(skillRouter.allSkills) { skill in
                            Button {
                                input = "@\(skill.name) "
                            } label: {
                                Text("@\(skill.name)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.brandAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.brandAccent.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppSpacing.md)
                }
                .padding(.top, AppSpacing.xs)
            }

            // 输入栏
            HStack(spacing: 10) {
                Button {
                    showAttachmentSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.brandAccent)
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
                    TextField("说点什么…", text: $input, axis: .vertical)
                        .font(.appBody())
                        .foregroundStyle(Color.appPrimaryText)
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
                .background(Color.appInputFill)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(input.isEmpty ? Color.appSecondaryText : Color.brandAccent)
                }
                .disabled(input.isEmpty || isLoading)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.appBackground)
            .overlay(alignment: .top) {
                Divider().background(Color.appSeparator).opacity(0.5)
            }
        }
        .id(conversationId)
        .navigationTitle(store.selected?.title ?? "对话")
        .background(Color.appBackground)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
            Text("请在系统设置中为 velos 开启麦克风和语音识别权限。")
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
        .sheet(isPresented: $showAttachmentSheet) {
            AttachmentSheetView(
                onPhoto: { showPhotoPicker = true; showAttachmentSheet = false },
                onFile: { showFilePicker = true; showAttachmentSheet = false },
                onSkill: { skill in
                    pinnedSkillID = skill.id
                    activeSkills = [skill]
                    showAttachmentSheet = false
                },
                onModel: { profile in
                    settings.setActiveProfile(profile.id)
                    showAttachmentSheet = false
                }
            )
        }
        .onReceive(speech.$transcript) { text in
            if !text.isEmpty && awaitingVoice {
                self.input = text
            }
        }
    }

    // MARK: - 添加到对话面板

    struct AttachmentSheetView: View {
        @Environment(\.dismiss) private var dismiss
        @EnvironmentObject private var settings: SettingsStore
        @ObservedObject private var skillRouter = SkillRouter.shared

        enum Mode { case root, skills, models }
        @State private var mode: Mode = .root

        let onPhoto: () -> Void
        let onFile: () -> Void
        let onSkill: (Skill) -> Void
        let onModel: (APIProfile) -> Void

        var body: some View {
            NavigationStack {
                List {
                    switch mode {
                    case .root:
                        Section("文件与媒体") {
                            Button {
                                dismiss()
                                onPhoto()
                            } label: {
                                rowLabel(icon: "photo.fill", title: "照片")
                            }
                            Button {
                                dismiss()
                                onFile()
                            } label: {
                                rowLabel(icon: "doc.fill", title: "本地文件")
                            }
                        }
                        Section("工具") {
                            Button {
                                mode = .skills
                            } label: {
                                rowLabel(icon: "sparkles", title: "技能", chevron: true)
                            }
                        }
                        Section("模型") {
                            Button {
                                mode = .models
                            } label: {
                                rowLabel(icon: "cpu", title: "切换模型", chevron: true)
                            }
                        }
                    case .skills:
                        if skillRouter.allSkills.isEmpty {
                            Text("暂无可用技能")
                                .font(.appCaption())
                                .foregroundStyle(Color.appSecondaryText)
                        }
                        ForEach(skillRouter.allSkills) { skill in
                            Button {
                                dismiss()
                                onSkill(skill)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: skill.icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.brandAccent)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.appPrimaryText)
                                        Text(skill.description)
                                            .font(.appCaption2())
                                            .foregroundStyle(Color.appSecondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    case .models:
                        if settings.profiles.isEmpty {
                            Text("还没有保存的配置，请到 设置 → API 设置 添加")
                                .font(.appCaption())
                                .foregroundStyle(Color.appSecondaryText)
                        }
                        ForEach(settings.profiles) { p in
                            Button {
                                dismiss()
                                onModel(p)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(settings.activeProfile.id == p.id ? Color.brandAccent : Color.appSecondaryText)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name.isEmpty ? "未命名" : p.name)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.appPrimaryText)
                                        Text("\(p.modelName) · \(shortURL(p.baseURL))")
                                            .font(.appCaption2())
                                            .foregroundStyle(Color.appSecondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if settings.activeProfile.id == p.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.brandAccent)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(mode == .root ? "添加到对话" : (mode == .skills ? "选择技能" : "切换模型"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                            .foregroundStyle(Color.brandAccent)
                    }
                    if mode != .root {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("返回") { mode = .root }
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }
                .background(Color.appBackground)
            }
            .preferredColorScheme(.dark)
        }

        private func rowLabel(icon: String, title: String, chevron: Bool = false) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 28)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
        }

        private func shortURL(_ s: String) -> String {
            s.trimmingCharacters(in: ["/"]).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
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

    private func resendMessage(_ msg: StoredMessage) {
        input = msg.content
        inputID = UUID()
    }

    private func regenerate(from assistantMsg: StoredMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantMsg.id }) else { return }
        var trimmed = Array(messages.prefix(idx))
        guard let lastUser = trimmed.last(where: { $0.role == "user" }) else { return }
        if let userIdx = trimmed.firstIndex(where: { $0.id == lastUser.id }) {
            trimmed = Array(trimmed.prefix(through: userIdx))
        }
        activeSkills = skillRouter.match(input: lastUser.content)
        store.update(conversationId, messages: trimmed)

        Task {
            do {
                isLoading = true
                let (updated, _) = try await AgentClient.shared.run(
                    messages: trimmed,
                    image: nil,
                    tools: SystemTools.activeTools,
                    activeSkills: activeSkills
                ) { partial in
                    store.update(conversationId, messages: partial)
                }
                store.update(conversationId, messages: updated)
            } catch {
                errorText = error.localizedDescription
                var finalMsgs = messages
                if let idx = finalMsgs.indices.last,
                   finalMsgs[idx].role == "assistant",
                   finalMsgs[idx].isStreaming {
                    finalMsgs[idx].isStreaming = false
                    finalMsgs[idx].status = nil
                    if finalMsgs[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalMsgs.remove(at: idx)
                    }
                }
                store.update(conversationId, messages: finalMsgs)
            }
            isLoading = false
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
                    errorText = "语音识别需要授权：请在系统设置中为「velos」开启“语音识别”权限。另外，当前云端 API（如 DeepSeek）通常不支持音频转写，建议改用支持 /audio/transcriptions 的接口（如 OpenAI）以获得更好效果。"
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

        let explicit = skillRouter.matchExplicit(input: raw)
        let text: String
        var skills: [Skill]
        if let e = explicit {
            text = skillRouter.stripSkillPrefix(raw)
            skills = e
        } else if let pid = pinnedSkillID,
                  let pinned = skillRouter.allSkills.first(where: { $0.id == pid }) {
            text = raw
            skills = [pinned]
        } else {
            text = raw
            skills = skillRouter.match(input: raw)
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
                    tools: SystemTools.activeTools,
                    activeSkills: activeSkills
                ) { partial in
                    store.update(conversationId, messages: partial)
                }
                store.update(conversationId, messages: updated)
            } catch {
                errorText = error.localizedDescription
                // 失败时清理占位流式消息：保留已生成内容，仅停止流式状态。
                var finalMsgs = messages
                if let idx = finalMsgs.indices.last,
                   finalMsgs[idx].role == "assistant",
                   finalMsgs[idx].isStreaming {
                    finalMsgs[idx].isStreaming = false
                    finalMsgs[idx].status = nil
                    if finalMsgs[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalMsgs.remove(at: idx)
                    }
                }
                store.update(conversationId, messages: finalMsgs)
            }
            isLoading = false
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
    let onResend: (() -> Void)?
    let onRegenerate: (() -> Void)?
    @State private var previewURL: PreviewItem?
    @State private var showShareSheet = false
    @ObservedObject private var speaker = SpeechSynthesizer.shared

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

                if message.isStreaming && message.content.isEmpty, let status = message.status {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text(status)
                            .font(.appBody())
                            .foregroundStyle(Color.appPrimaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .circular)
                            .fill(bubbleBackground)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                } else {
                    Text(message.content)
                        .font(.appBody())
                        .foregroundStyle(message.role == "user" ? .white : Color.appPrimaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .circular)
                                .fill(bubbleBackground)
                        )
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                        .textSelection(.enabled)
                }

                if message.role == "assistant" && !message.isStreaming {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.appCaption2())
                        Text("velos")
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

                if !message.isStreaming {
                    actionButtons
                }
            }
            .frame(maxWidth: 300, alignment: message.role == "user" ? .trailing : .leading)

            if message.role != "user" { Spacer(minLength: 28) }
        }
        .sheet(item: $previewURL) { FilePreviewView(url: $0.url) }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [message.content])
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 14) {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
            }

            if message.role == "user" {
                if let onResend {
                    Button(action: onResend) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            } else if message.role == "assistant" {
                if let onRegenerate {
                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }

            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
            }

            Button {
                if speaker.speakingMessageID == message.id {
                    speaker.stop()
                } else {
                    speaker.speak(message.content, id: message.id)
                }
            } label: {
                Image(systemName: speaker.speakingMessageID == message.id ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(Color.appSecondaryText)
        .padding(.leading, 4)
        .padding(.top, 2)
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

// MARK: - 语音朗读

import AVFoundation

@MainActor
final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate, ObservableObject {
    static let shared = SpeechSynthesizer()
    private let synthesizer = AVSpeechSynthesizer()
    @Published var speakingMessageID: UUID?
    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, id: UUID) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageID = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingMessageID = nil
        }
    }
}

// MARK: - 系统分享 Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
