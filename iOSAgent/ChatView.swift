import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct ChatView: View {
    let conversationId: UUID
    @Binding var path: NavigationPath
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
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

    // v9.0.5 图片附件加载状态： PhotosPicker / FileImporter 读取大图时展示进度，避免用户以为没点中
    @State private var isLoadingAttachment = false

    // v9.0 对话内 skill 链接一键安装
    @State private var skillInstallStatus: String?
    @State private var isInstallingSkill = false
    @AppStorage("skillInstallIgnoredURLs") private var ignoredSkillURLsData = "[]"

    /// 已点「不再提示」的 skill 链接集合
    private var ignoredSkillURLs: Set<String> {
        get {
            guard let data = ignoredSkillURLsData.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(Array(newValue)),
               let s = String(data: data, encoding: .utf8) {
                ignoredSkillURLsData = s
            }
        }
    }

    private func dismissSkillBanner(_ url: String) {
        var s = ignoredSkillURLs
        s.insert(url)
        ignoredSkillURLs = s
    }

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
                        // 始终存在的底部锚点：scrollTo 一定命中（LazyVStack 首帧未实例化的元素 id 找不到）
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.md)
                }
                .onAppear {
                    // 打开对话时主动滚到底（onChange 只在内容变化时触发，历史会话进入时 count 不变 → 不会滚）
                    scheduleJumpToBottom(proxy, animated: false, retries: 6)
                }
                .onChange(of: messages.count) { _ in
                    scheduleJumpToBottom(proxy, animated: true, retries: 4)
                }
                .onChange(of: messages.last?.content) { _ in
                    scheduleJumpToBottom(proxy, animated: true, retries: 4)
                }
                .onChange(of: isLoading) { _ in
                    scheduleJumpToBottom(proxy, animated: true, retries: 4)
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

            // v9.0 对话内 skill 链接一键安装提示
            if let url = detectedSkillURL {
                skillInstallBanner(url: url)
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

                if isLoadingAttachment {
                    ProgressView()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let selectedImage {
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
        .navigationTitle(conversationTitle)
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
            Text("请在系统设置中为 Velos 开启麦克风和语音识别权限。")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                isLoadingAttachment = true
                defer { isLoadingAttachment = false }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        clearAttachment()
                        selectedImage = image
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                isLoadingAttachment = true
                Task {
                    defer { isLoadingAttachment = false }
                    let secured = url.startAccessingSecurityScopedResource()
                    defer { if secured { url.stopAccessingSecurityScopedResource() } }
                    let name = url.lastPathComponent
                    let isImg = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
                        .flatMap { UTType($0)?.conforms(to: .image) } ?? false
                    if isImg, let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        await MainActor.run {
                            clearAttachment()
                            selectedImage = img
                        }
                    } else {
                        // 拷进 App 沙盒，避免安全作用域失效
                        let dst = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension((url.pathExtension.isEmpty ? "file" : url.pathExtension))
                        _ = try? FileManager.default.removeItem(at: dst)
                        if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                            await MainActor.run {
                                clearAttachment()
                                selectedFileURL = dst
                                selectedFileName = name
                                fileIsImage = false
                            }
                        }
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

    /// 当前模型是否可能支持图片/视觉理解。
    ///
    /// ⚠️ v9.0.6 起改为**黑名单**（已知纯文本模型才判否），不再用白名单。
    /// 原因：白名单漏掉 kimi / moonshot / 各家新模型，会误伤 —— 尤其「生图」这类需求
    /// 走的是服务端 generate_image 工具，**根本不需要模型能看图**，白名单一刀切直接把功能堵死了。
    /// 现在未知模型一律放行；即便判断为不支持也只给软提示，不阻断发送。
    private var modelSupportsVision: Bool {
        let m = settings.activeProfile.modelName.lowercased()
        let nonVision = [
            "deepseek-chat", "deepseek-reasoner", "deepseek-coder",
            "deepseek-v3", "deepseek-r1", "deepseek-distill",
            "qwen-turbo", "qwen-plus", "qwen-max", "qwen2.5-", "qwen3-",
            "glm-4-air", "glm-4-flash", "glm-4-plus", "glm-4-9b",
            "yi-34b", "yi-large", "mixtral", "llama-3-8b", "llama-2",
            "text-davinci", "babbage", "curie", "o1-mini"
        ]
        return !nonVision.contains { m.contains($0) }
    }

    /// 对 UI 可见的消息：过滤掉工具中间结果的气泡文本，只保留带文件附件的工具卡片。
    /// 注意：原始消息仍保存在 store 中并发给模型，这里只是不在界面上渲染噪声。
    private var messages: [StoredMessage] {
        let all = store.conversations.first(where: { $0.id == conversationId })?.messages ?? []
        return all.filter { $0.role != "tool" || $0.fileURL != nil }
    }

    /// 顶部标题必须绑定到当前 conversationId，避免共享 store.selected 导致多个对话互相串标题
    private var conversationTitle: String {
        store.conversations.first(where: { $0.id == conversationId })?.title ?? "对话"
    }

    /// 从最近一条用户或 assistant 消息中提取 GitHub 仓库/技能链接
    private var detectedSkillURL: String? {
        let all = store.conversations.first(where: { $0.id == conversationId })?.messages ?? []
        let pattern = "https?://(www\\.)?github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[^\\s]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        for msg in all.reversed() {
            let text = msg.content
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let r = Range(match.range, in: text) {
                let url = String(text[r])
                if !ignoredSkillURLs.contains(url) { return url }
            }
        }
        return nil
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let jump = { (anim: Bool) in
            if anim { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("bottom-anchor", anchor: .bottom) } }
            else { proxy.scrollTo("bottom-anchor", anchor: .bottom) }
        }
        jump(animated)
        // 多次延迟重试覆盖 LazyVStack 首帧 / 元素虚拟化 / onAppear 时序不确定
        let delays: [Double] = animated ? [0.06, 0.18, 0.4, 0.8] : [0.05, 0.12, 0.25, 0.5, 1.0]
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { jump(animated) }
        }
    }

    private func scheduleJumpToBottom(_ proxy: ScrollViewProxy, animated: Bool, retries: Int) {
        let delays: [Double] = [0.0, 0.05, 0.15, 0.35, 0.6, 1.0, 1.6]
        for i in 0..<min(retries, delays.count) {
            let d = delays[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                if animated { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo("bottom-anchor", anchor: .bottom) } }
                else { proxy.scrollTo("bottom-anchor", anchor: .bottom) }
            }
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

    /// 对话内 skill 链接一键安装提示条
    @ViewBuilder
    private func skillInstallBanner(url: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到技能链接")
                    .font(.appCaption().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Text(url)
                    .font(.appCaption2())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isInstallingSkill {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("一键安装") {
                    installSkill(from: url)
                }
                .font(.appCaption().weight(.semibold))
                .foregroundStyle(Color.brandAccent)
                .buttonStyle(.plain)
                Button("不再提示") {
                    dismissSkillBanner(url)
                }
                .font(.appCaption2())
                .foregroundStyle(Color.appSecondaryText)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.xs)

        if let status = skillInstallStatus {
            Text(status)
                .font(.appCaption2())
                .foregroundStyle(status.contains("失败") || status.contains("无法") ? Color.appError : Color.brandAccent)
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, 2)
        }
    }

    private func installSkill(from url: String) {
        isInstallingSkill = true
        skillInstallStatus = nil
        Task {
            do {
                let installed = try await SkillRouter.shared.install(from: url)
                skillInstallStatus = installed.isEmpty ? "安装完成" : "已安装：\(installed.map(\.name).joined(separator: "、"))"
            } catch {
                skillInstallStatus = "安装失败：\(error.localizedDescription)"
            }
            isInstallingSkill = false
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
                    errorText = "语音识别需要授权：请在系统设置中为「Velos」开启“语音识别”权限。另外，当前云端 API（如 DeepSeek）通常不支持音频转写，建议改用支持 /audio/transcriptions 的接口（如 OpenAI）以获得更好效果。"
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

        // v9.0.6：模型可能不支持看图时只给软提示，**不阻断发送**。
        // 之前硬 return 会误伤「发图 → 让服务端生图/处理」这类走工具的诉求（kimi 等被误判）。
        if imageToSend != nil, !modelSupportsVision {
            var finalMsgs = msgs
            let hint = StoredMessage(
                role: "assistant",
                content: "⚠️ 当前模型「\(settings.activeProfile.modelName)」可能不支持看图，已继续发送，但图片内容理解可能不准确。如需准确识别图片，请轻点左下角「+」→「切换模型」，选择带视觉能力的模型（如 gpt-4o / claude / gemini / qwen-vl / kimi-vision）。",
                isStreaming: false
            )
            finalMsgs.append(hint)
            store.update(conversationId, messages: finalMsgs)
            // 注意：这里刻意不 return，继续走下面的正常发送流程
        }

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
    @State private var fullscreenImage: FullscreenImage?
    @State private var showShareSheet = false
    @State private var saveStatus: String?
    @ObservedObject private var speaker = SpeechSynthesizer.shared

    /// 是否是图片型文件（生成图 / 用户图附件 / 工具返回的 image/*）。仅用于 inline 渲染判断。
    private var isImageFile: Bool {
        guard let url = message.fileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ["png","jpg","jpeg","gif","webp","heic"].contains(ext) || message.imageBase64 != nil
    }

    /// 当前 bubble 内可 inline 显示的图片：优先 fileURL（生成图）；其次 imageBase64（用户附件）。
    private var inlineImage: InlineImage? {
        if let url = message.fileURL, isImageFile { return .url(url) }
        if let b64 = message.imageBase64, !b64.isEmpty { return .base64(b64) }
        return nil
    }

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 28) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 5) {
                if message.role == "tool" {
                    // 工具结果：图片 inline 显示；其它文件走"打开文件"卡片
                    if isImageFile {
                        toolImageCard
                    } else {
                        toolFileCard
                    }
                } else {
                    if let toolName = message.toolName {
                        Label(toolName, systemImage: "hammer.fill")
                            .font(.appCaption2().weight(.medium))
                            .foregroundStyle(Color.appSecondaryText)
                            .padding(.horizontal, 14)
                    }

                    // 用户消息 / assistant 文本里的 inline 图片（生成图若作为 assistant 气泡附在文字上方）
                    if let img = inlineImage, !(message.role == "tool") {
                        chatImageView(img)
                    }

                    // 流式占位：模型思考/工具执行中但尚未输出文字时显示动态心跳，避免空矩形。
                    // 工具执行阶段 isStreaming 会被置 false、但 status 仍保留心跳文字，故条件需同时覆盖 status。
                    // 用 trimming 判断，防止模型只返回换行/空格时误判为非空。
                    if message.role == "assistant" && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (message.isStreaming || message.status != nil) && inlineImage == nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                            Text(heartbeatText)
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
                    } else if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

                    if message.role == "assistant" && !message.isStreaming && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkle")
                                .font(.appCaption2())
                            Text("Velos")
                                .font(.appCaption2().weight(.medium))
                        }
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(.leading, 4)
                    }

                    // 非图片型 fileURL：保留"打开文件"按钮
                    if let url = message.fileURL, !isImageFile {
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

                    if let status = saveStatus {
                        Text(status)
                            .font(.appCaption2())
                            .foregroundStyle(Color.appSecondaryText)
                            .padding(.leading, 4)
                    }

                    if !message.isStreaming && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        actionButtons
                    }
                }
            }
            .frame(maxWidth: 300, alignment: message.role == "user" ? .trailing : .leading)

            if message.role != "user" { Spacer(minLength: 28) }
        }
        .sheet(item: $previewURL) { FilePreviewView(url: $0.url) }
        .sheet(item: $fullscreenImage) { fs in
            FullscreenImageView(image: fs.image)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItemsForThisMessage())
        }
    }

    /// 聊天气泡里 inline 图片：圆角缩略图，点击全屏，长按弹出保存菜单。
    @ViewBuilder
    private func chatImageView(_ img: InlineImage) -> some View {
        Group {
            if let ui = img.uiImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        fullscreenImage = FullscreenImage(image: ui)
                    }
                    .contextMenu {
                        Button {
                            fullscreenImage = FullscreenImage(image: ui)
                        } label: { Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right") }
                        Button {
                            Task { await saveToPhotos(ui) }
                        } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                        if case .url(let u) = img.source {
                            Button {
                                previewURL = PreviewItem(url: u)
                            } label: { Label("用 QuickLook 打开", systemImage: "doc.text.viewfinder") }
                        }
                    }
            }
        }
    }

    /// tool 结果里的图片卡片（生成图场景）：和 chatImageView 类似但放在工具标签下方独立显示。
    @ViewBuilder
    private var toolImageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.appCaption())
                Text(message.toolName ?? "图片")
                    .font(.appCaption().weight(.medium))
            }
            .foregroundStyle(Color.appSecondaryText)
            if let img = inlineImage, let ui = img.uiImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .onTapGesture {
                        fullscreenImage = FullscreenImage(image: ui)
                    }
                    .contextMenu {
                        Button {
                            fullscreenImage = FullscreenImage(image: ui)
                        } label: { Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right") }
                        Button {
                            Task { await saveToPhotos(ui) }
                        } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
                    }
            }
            if let status = saveStatus {
                Text(status)
                    .font(.appCaption2())
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
    }

    /// 保存到相册：先请求相册权限，UIImage → JPEG → PHPhotoLibrary save。
    private func saveToPhotos(_ ui: UIImage) async {
        let granted = await PhotoSaveHelper.requestAuth()
        guard granted else {
            saveStatus = "保存失败：未获得相册权限"
            return
        }
        let ok = await PhotoSaveHelper.save(ui)
        saveStatus = ok ? "已保存到相册" : "保存失败"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            saveStatus = nil
        }
    }

    /// 分享按钮用：本条消息的友好导出。
    /// - 文本消息：仅分享内容（保留向后兼容）
    /// - 图片型消息：分享图片 UIImage（微信能直接看到图）
    /// - 带文件附件：分享文件 URL（系统会自动选 App）
    private func shareItemsForThisMessage() -> [Any] {
        if let img = inlineImage, let ui = img.uiImage {
            return [ui]
        }
        if let url = message.fileURL {
            return [url]
        }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? ["（空消息）"] : [text]
    }

    /// 工具结果文件卡片：非图片文件走"打开文件"入口，图片已走 toolImageCard 不重复。
    @ViewBuilder
    private var toolFileCard: some View {
        if let url = message.fileURL {
            Button {
                previewURL = PreviewItem(url: url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.viewfinder")
                        .font(.appBody().weight(.medium))
                    Text("打开文件")
                        .font(.appBody().weight(.medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.appCaption2())
                }
                .foregroundStyle(Color.brandAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .circular)
                        .fill(Color.appSurface)
                )
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        } else {
            // 无文件的工具结果：完全不渲染（messages 已过滤，此处为防御）
            EmptyView()
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

    /// 流式占位心跳文字：按 status → toolCalls → 默认兜底 的优先级显示
    private var heartbeatText: String {
        if let status = message.status, !status.isEmpty { return status }
        if let calls = message.toolCalls, !calls.isEmpty {
            let names = calls.map { $0.name }
            if names.contains("generate_image") { return "服务器正在生成图片…" }
            if names.contains("generate_speech") { return "服务器正在合成语音…" }
            if names.contains("generate_video") { return "服务器正在渲染视频…" }
            return "正在执行：\(names.joined(separator: "、"))…"
        }
        return "正在处理中…"
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

// MARK: - 图片 inline / 全屏 / 保存

/// 聊天气泡内可渲染的图片数据源。优先用 fileURL（生成图），其次用 imageBase64（用户附件）。
/// 解析后的 UIImage 走 .uiImage 缓存给 Image 直接绑定，避免每帧重新解压。
struct InlineImage {
    enum Source { case url(URL), base64(String) }
    let source: Source
    let uiImage: UIImage?

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        self.source = .url(fileURL)
        self.uiImage = UIImage(data: data)
    }

    init?(base64: String) {
        guard let data = Data(base64Encoded: base64), let img = UIImage(data: data) else { return nil }
        self.source = .base64(base64)
        self.uiImage = img
    }

    static func url(_ u: URL) -> InlineImage? { InlineImage(fileURL: u) }
    static func base64(_ s: String) -> InlineImage? { InlineImage(base64: s) }
}

/// 全屏图片预览的 Sheet 容器。
struct FullscreenImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 全屏图片视图：双指缩放 + 单击关闭 + 长按保存到相册。
struct FullscreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var saveStatus: String?
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { v in scale = max(1.0, min(lastScale * v, 4.0)) }
                            .onEnded { _ in lastScale = scale; if scale < 1.05 { withAnimation(.spring) { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } } },
                        DragGesture()
                            .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) }
                            .onEnded { _ in lastOffset = offset }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring) {
                        if scale > 1.0 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2; lastScale = 2 }
                    }
                }
                .onTapGesture { dismiss() }
            VStack {
                Spacer()
                if let status = saveStatus {
                    Text(status)
                        .font(.appBody().weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(.bottom, 36)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.trailing, 16)
                            .padding(.top, 16)
                    }
                }
                Spacer()
            }
        }
        .contextMenu {
            Button {
                Task { await save() }
            } label: { Label("保存到相册", systemImage: "square.and.arrow.down") }
        }
    }

    private func save() async {
        let granted = await PhotoSaveHelper.requestAuth()
        guard granted else { saveStatus = "未授权相册"; return }
        let ok = await PhotoSaveHelper.save(image)
        saveStatus = ok ? "已保存" : "保存失败"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            saveStatus = nil
        }
    }
}

/// 相册保存助手：请求权限 + 写图。避免在 MessageBubble 里堆权限逻辑。
enum PhotoSaveHelper {
    static func requestAuth() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                    c.resume(returning: s == .authorized || s == .limited)
                }
            }
        default: return false
        }
    }

    static func save(_ image: UIImage) async -> Bool {
        await withCheckedContinuation { c in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { ok, _ in
                c.resume(returning: ok)
            })
        }
    }
}
