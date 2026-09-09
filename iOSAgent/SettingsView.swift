import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

enum SettingsRoute: Hashable {
    case api
    case permissions
    case customPrompt
    case legal(LegalType)
    case about
    case skills
    case account
    case crashLog
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var showClearCacheAlert = false
    @State private var cacheSizeText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                Text("设置")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)
                    .padding(.horizontal, AppSpacing.lg)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("用户设置")
                        .font(.appCaption2().weight(.semibold))
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(.leading, AppSpacing.md)
                    accountTopCard
                }
                .padding(.horizontal, AppSpacing.lg)

                VStack(spacing: AppSpacing.md) {
                    SettingsSection(title: "核心设置") {
                        SettingsLinkRow(icon: "key.fill", color: .pastelBlue, title: "API 设置", destination: .api)
                        Divider().padding(.leading, 48)
                        SettingsLinkRow(icon: "lock.shield.fill", color: .pastelOrange, title: "系统权限", destination: .permissions)
                        Divider().padding(.leading, 48)
                        SettingsLinkRow(icon: "text.quote", color: .pastelPurple, title: "自定义系统提示", destination: .customPrompt)
                        Divider().padding(.leading, 48)
                        SettingsLinkRow(icon: "brain.fill", color: .pastelTeal, title: "技能中心", destination: .skills)
                    }

                    SettingsSection(title: "外观") {
                        HStack(spacing: AppSpacing.md) {
                            Text("主题模式")
                                .font(.appBody().weight(.semibold))
                                .foregroundStyle(Color.appPrimaryText)
                            Spacer(minLength: 0)
                            Picker("主题模式", selection: Binding(
                                get: { settings.colorSchemePreference },
                                set: { settings.appColorSchemeRaw = $0.rawValue }
                            )) {
                                ForEach(AppColorScheme.allCases) { scheme in
                                    Text(scheme.displayName).tag(scheme)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)

                        Divider().padding(.leading, AppSpacing.md)

                        Toggle(isOn: $settings.keepAwakeEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("使用期间保持屏幕常亮")
                                    .font(.appBody().weight(.semibold))
                                    .foregroundStyle(Color.appPrimaryText)
                                Text("息屏会挂起网络，导致 PPT / 图片 / 视频下载中断")
                                    .font(.appCaption())
                                    .foregroundStyle(Color.appSecondaryText)
                            }
                        }
                        .tint(Color.brandAccent)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.vertical, AppSpacing.sm)
                    }

                    SettingsSection(title: "应用") {
                        Button { showClearCacheAlert = true } label: {
                            SettingsLinkRow(icon: "trash.fill", color: .pastelPink, title: "清除缓存", showChevron: false)
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSection(title: "协议与声明") {
                        SettingsLinkRow(icon: "doc.text.fill", color: .pastelTeal, title: "用户协议", destination: .legal(.userAgreement))
                        Divider().padding(.leading, 48)
                        SettingsLinkRow(icon: "hand.raised.fill", color: .pastelGreen, title: "隐私政策", destination: .legal(.privacyPolicy))
                        Divider().padding(.leading, 48)
                        SettingsLinkRow(icon: "exclamationmark.shield.fill", color: .pastelGray, title: "免责声明", destination: .legal(.disclaimer))
                    }

                    SettingsSection(title: "关于") {
                        SettingsLinkRow(icon: "info.circle.fill", color: .pastelGray, title: "关于 Velos", destination: .about)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
            }
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .alert("清除缓存", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { clearCache() }
        } message: {
            Text("将删除所有生成的文件（文档 / 演示文稿 / 图片 / PDF 等）与临时附件，历史对话不会被删除。\n当前缓存：\(cacheSizeText)")
        }
        .onAppear { calculateCacheSize() }
    }

    // MARK: - Helpers

    private func calculateCacheSize() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles) else {
            cacheSizeText = "0 B"
            return
        }
        let total = urls.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + size
        }
        cacheSizeText = byteCount(total)
    }

    private func clearCache() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let removable = ["txt", "md", "markdown", "csv", "json", "html", "htm", "rtf", "log", "xml", "yaml", "yml",
                         "pdf", "pptx", "doc", "docx", "xls", "xlsx",
                         "png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        for url in urls {
            if removable.contains(url.pathExtension.lowercased()) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        calculateCacheSize()
    }

    private func byteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// 设置页最上方的账户卡：展示登录态，点击进入账户页。
    private var accountTopCard: some View {
        NavigationLink(value: SettingsRoute.account) {
            HStack(spacing: AppSpacing.md) {
                AccountAvatarView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    if settings.isLoggedIn {
                        HStack(spacing: 6) {
                            if settings.accountProvider == .wechat { WechatBadge(size: 15) }
                            Text(settings.authDisplayName.isEmpty ? settings.authEmail : settings.authDisplayName)
                                .font(.appSubheadline().weight(.semibold))
                                .foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                        }
                        Text(settings.accountProvider == .wechat ? "微信账号" : settings.authEmail)
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                            .lineLimit(1)
                    } else {
                        Text("未注册")
                            .font(.appSubheadline().weight(.semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        Text("点击登录 / 注册账户")
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondaryText)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Reusable Components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
                .padding(.leading, AppSpacing.md)

            VStack(spacing: 0) {
                content
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()
        }
    }
}

struct SettingsLinkRow: View {
    let icon: String
    let color: Color
    let title: String
    var showChevron: Bool = true
    var destination: SettingsRoute?

    var body: some View {
        if let destination = destination {
            NavigationLink(value: destination) {
                rowContent
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, AppSpacing.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            rowContent
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.md)
                .contentShape(Rectangle())
        }
    }

    private var rowContent: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(color.opacity(0.4))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.appBody().weight(.semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.appSecondaryText)
            }
        }
    }
}

// MARK: - API 设置

struct APISettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var draftName = ""
    @State private var draftBase = ""
    @State private var draftKey = ""
    @State private var draftModel = ""
    @State private var draftSTT = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("API 设置")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                VStack(spacing: AppSpacing.md) {
                    inputCard
                    actionCard
                    if !settings.profiles.isEmpty { profilesCard }
                }

                Text("兼容 OpenAI / DeepSeek 等任意 OpenAI 格式接口。注意：DeepSeek 不支持音频转写，语音输入请使用支持 /audio/transcriptions 的接口（如 OpenAI）。")
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .padding(.horizontal, AppSpacing.md)
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .onAppear { loadProfile(settings.activeProfile) }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader("当前编辑的配置")
            VStack(spacing: AppSpacing.md) {
                labeledField("配置名称") { AppTextField(placeholder: "如 DeepSeek / OpenAI", text: $draftName) }
                labeledField("API 地址") { AppTextField(placeholder: "https://api.deepseek.com", text: $draftBase, keyboard: .URL) }
                labeledField("API 密钥") { AppSecureField(placeholder: "sk-...", text: $draftKey) }
                labeledField("模型名称") { AppTextField(placeholder: "deepseek-chat", text: $draftModel) }
                labeledField("语音模型") { AppTextField(placeholder: "whisper-1", text: $draftSTT) }
            }
        }
        .padding(AppSpacing.md)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private func labeledField(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
            field()
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader("连接测试")

            if isTesting {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                    Text("正在测试连接…")
                        .font(.appSubheadline())
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.md)
            } else if let testResult {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: testResult.contains("OK") || testResult.contains("成功") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(testResult.contains("OK") || testResult.contains("成功") ? Color.appSuccess : Color.appError)
                    Text(testResult)
                        .font(.appSubheadline())
                        .foregroundStyle(Color.appSecondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.md)
            }

            HStack(spacing: AppSpacing.md) {
                Button { testConnection() } label: {
                    Text("测试连接")
                        .font(.appBody().weight(.semibold))
                        .foregroundStyle(Color.appPrimaryText)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.appInputFill)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                .disabled(isTesting || draftKey.isEmpty || draftBase.isEmpty)

                Button { saveProfile() } label: {
                    Text("保存")
                        .font(.appBody().weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isSaveDisabled ? Color.appSecondaryText.opacity(0.25) : Color.brandAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                }
                .disabled(isSaveDisabled)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.bottom, AppSpacing.md)
        }
        .padding(.top, AppSpacing.md)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private var isSaveDisabled: Bool {
        isTesting || draftKey.isEmpty || draftBase.isEmpty
    }

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            SectionHeader("已保存的配置")
            if settings.profiles.isEmpty {
                Text("还没有保存的配置")
                    .font(.appSubheadline())
                    .foregroundStyle(Color.appSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.md)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .appCardShadow()
            } else {
                List {
                    ForEach(Array(settings.profiles.enumerated()), id: \.element.id) { idx, p in
                        profileRow(p)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.appSurface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { settings.deleteProfile(p.id) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: max(CGFloat(settings.profiles.count) * 56, 1))
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                .appCardShadow()
            }
        }
    }

    private func profileRow(_ p: APIProfile) -> some View {
        Button {
            settings.setActiveProfile(p.id)
            loadProfile(p)
        } label: {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Text("\(settings.profiles.firstIndex(where: { $0.id == p.id }).map { String($0 + 1) } ?? "")")
                        .font(.appMicro())
                        .foregroundStyle(Color.brandAccent)
                }
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(p.name.isEmpty ? "未命名" : p.name)
                        .font(.appSubheadline().weight(.semibold))
                        .foregroundStyle(Color.appPrimaryText)
                    Text("\(p.modelName) · \(shortURL(p.baseURL))")
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                }
                Spacer(minLength: 0)
                if settings.activeProfile.id == p.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appSuccess)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortURL(_ s: String) -> String {
        s.trimmingCharacters(in: ["/"]).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func loadProfile(_ p: APIProfile) {
        draftName = p.name
        draftBase = p.baseURL
        draftKey = p.apiKey
        draftModel = p.modelName
        draftSTT = p.sttModelName
        testResult = nil
        saved = false
    }

    private func saveProfile() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let id: String
        if let active = settings.profiles.first(where: { $0.id == settings.activeProfile.id }),
           active.baseURL.trimmingCharacters(in: .whitespaces) == draftBase.trimmingCharacters(in: .whitespaces),
           active.apiKey.trimmingCharacters(in: .whitespaces) == draftKey.trimmingCharacters(in: .whitespaces) {
            id = active.id
        } else {
            id = UUID().uuidString
        }
        let p = APIProfile(id: id, name: name, baseURL: draftBase.trimmingCharacters(in: .whitespaces),
                           apiKey: draftKey, modelName: draftModel.trimmingCharacters(in: .whitespaces),
                           sttModelName: draftSTT.trimmingCharacters(in: .whitespaces))
        settings.saveProfile(p)
        settings.setActiveProfile(p.id)
        testResult = "已保存到本地"
        saved = true
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                _ = try await AgentClient.shared.testConnection(baseURL: draftBase, apiKey: draftKey, model: draftModel)
                testResult = "连接成功 / OK"
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

// MARK: - 系统权限

struct PermissionsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("系统权限")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                VStack(spacing: AppSpacing.md) {
                    SettingsSection(title: "系统能力") {
                        CapabilityToggleRow(key: "notifications", icon: "alarm.fill", color: .pastelOrange, title: "闹钟 / 计时器")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "reminders", icon: "checkmark.square.fill", color: .pastelBlue, title: "提醒事项")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "calendar", icon: "calendar.badge.plus", color: .pastelPink, title: "日历")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "health", icon: "heart.fill", color: .pastelPink, title: "健康")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "contacts", icon: "person.2.fill", color: .pastelGreen, title: "通讯录")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "location", icon: "location.fill", color: .pastelPurple, title: "位置")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "clipboard", icon: "doc.on.clipboard", color: .pastelOrange, title: "剪贴板")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "photos", icon: "photo.fill", color: .pastelPurple, title: "相册")
                        Divider().padding(.leading, 44)
                        CapabilityToggleRow(key: "device", icon: "iphone", color: .pastelGray, title: "设备信息")
                        Divider().padding(.leading, 44)
                        Button("刷新授权状态") { settings.refreshAuthStatuses() }
                            .font(.appSubheadline().weight(.semibold))
                            .foregroundStyle(Color.brandAccent)
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }

                    SettingsSection(title: "说明") {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Label("关于健康数据读取", systemImage: "heart.fill")
                                .font(.appSubheadline().weight(.semibold))
                                .foregroundStyle(Color.appPrimaryText)
                            Text("健康读取需要 App 以“包含 HealthKit 能力的描述文件”重新签名。免费 Apple ID 的侧载签名通常无法开启 HealthKit 能力，会导致授权失败。若需使用健康数据，请用付费开发者账号（$99/年）签名的描述文件重签本 IPA。")
                                .font(.appCaption())
                                .foregroundStyle(Color.appSecondaryText)
                                .lineLimit(nil)
                        }
                        .padding(AppSpacing.md)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
    }
}

// MARK: - 自定义系统提示

struct CustomPromptView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("自定义系统提示")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("自定义系统提示会追加在默认提示之后，用于塑造助手的角色、语气与回答偏好。例如：\n“你是一个简洁的中文助手，回答不超过三句话，多用分点。”")
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(nil)

                    TextEditor(text: $settings.systemPrompt)
                        .font(.appBody())
                        .foregroundStyle(Color.appPrimaryText)
                        .frame(minHeight: 200)
                        .padding(AppSpacing.md)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .appCardShadow()
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
    }
}

// MARK: - 协议与声明

enum LegalType: String {
    case userAgreement = "用户协议"
    case privacyPolicy = "隐私政策"
    case disclaimer = "免责声明"
}

struct LegalView: View {
    let type: LegalType

    var body: some View {
        ScrollView {
            Text(legalText)
                .font(.appCaption())
                .lineSpacing(5)
                .foregroundStyle(Color.appPrimaryText)
                .padding(AppSpacing.lg)
        }
        .background(Color.appBackground)
        .navigationTitle(type.rawValue)
    }

    private var legalText: String {
        switch type {
        case .userAgreement:
            return """
            欢迎使用 Velos（以下简称"本应用"）。在使用本应用前，请您务必仔细阅读并充分理解本用户协议（以下简称"本协议"）的全部内容，特别是以加粗或下划线标识的免责与责任限制条款。当您下载、安装、启动或实际使用本应用时，即视为您已阅读、理解并同意接受本协议各项条款的约束。如您不同意本协议任何内容，请勿使用本应用。

            一、协议的接受与修订
            1.1 本协议是您与本应用开发者之间关于本应用使用所订立的协议。
            1.2 开发者有权根据法律法规变化、产品功能升级或运营需要，适时修订本协议。修订后的协议将在本应用内或通过其他方式公布，并自公布之日起生效。
            1.3 若您在本协议修订后继续使用本应用，即视为您接受修订后的协议。若您不同意修订内容，应停止使用本应用并卸载。

            二、账户、设备与安装
            2.1 本应用通过自签名侧载方式分发，您需自行使用合法取得的 Apple ID 或开发者证书完成安装与重签名。
            2.2 您理解并同意，侧载安装受 iOS 系统版本、描述文件能力（如 HealthKit）、企业或个人证书有效性等因素影响，部分功能可能无法在所有设备上完整运行。
            2.3 您应当妥善保管自己的设备与签名证书，因证书过期、撤销或设备丢失导致的问题由您自行承担。

            三、API 配置与第三方服务
            3.1 本应用本身不提供大模型能力，所有 AI 对话、语音转写、文件生成等功能均依赖您自行配置的第三方云端 API（如 OpenAI、DeepSeek 等）。
            3.2 您需自行向第三方服务商申请 API Key，并自行承担由此产生的费用、配额与合规责任。
            3.3 您配置的 Base URL、API Key、模型名称等仅存储于您设备的本地沙盒，不会上传至开发者服务器，但您与第三方 API 之间的通信受该第三方服务条款与隐私政策约束。
            3.4 开发者不对第三方 API 的可用性、稳定性、准确性、安全性、计费或内容审核策略承担责任。

            四、知识产权
            4.1 本应用自身的软件、界面、文档、名称（"Velos"）及相关商誉的知识产权归开发者所有或已获合法授权。
            4.2 您在使用本应用过程中输入的内容、以及由 AI 生成并经您确认保存的文件，其知识产权按您与相应内容来源或第三方的约定处理；开发者不因提供工具而取得上述内容的所有权。
            4.3 您不得对本应用进行反向工程、反编译、破解、二次打包分发，或去除其版权标识，但法律明文允许的除外。

            五、用户行为规范
            5.1 您承诺不利用本应用从事任何违反中华人民共和国法律法规及所在司法辖区法律的行为。
            5.2 您不得生成、传播或处理任何侵权、诽谤、色情、暴力、恐怖、诈骗、赌博、侵犯隐私、危害国家安全或违反公序良俗的内容。
            5.3 您不得利用本应用干扰、攻击、侵入任何第三方系统或网络，或滥用系统能力影响设备正常运行。
            5.4 因您的内容或行为导致的任何第三方索赔、行政处罚或刑事追究，均由您自行承担，与开发者无关。

            六、免责与责任限制
            6.1 本应用按"现状"提供，开发者不保证其永不停机、不出错、满足您的特定需求或与原先描述完全一致。
            6.2 在适用法律允许的最大范围内，开发者不对因使用或无法使用本应用所造成的任何间接、偶然、特殊或后果性损害承担责任。
            6.3 开发者对 AI 生成内容的正确性、合法性、完整性不作任何明示或默示担保。

            七、协议终止
            7.1 您可随时卸载本应用以终止使用。
            7.2 若您违反本协议，开发者有权在不通知的情况下限制或终止您对本应用的使用。
            7.3 协议终止后，本应用中关于知识产权、免责、责任限制的条款继续有效。

            八、法律适用与争议解决
            8.1 本协议的订立、效力、解释、履行及争议解决均适用中华人民共和国法律。
            8.2 因本协议产生的争议，双方应友好协商解决；协商不成的，提交开发者所在地有管辖权的人民法院诉讼解决。

            九、联系我们
            9.1 如您对本协议有任何疑问，可通过本应用"关于"页中的网站（https://chen.cm）与我们联系。
            """
        case .privacyPolicy:
            return """
            本隐私政策旨在向您说明：当您使用 Velos（以下简称"本应用"）时，我们如何处理与您相关的信息。我们高度重视您的隐私，并遵循"最小必要、本地优先"的原则设计本应用。

            一、我们收集的信息
            1.1 本应用不要求您注册账户，也不向开发者服务器上传您的对话内容、文件或任何个人身份信息。
            1.2 为提供系统能力，本应用会在您明确授权后，于本地读取以下数据：提醒事项、日历、健康（步数、心率、睡眠等）、通讯录、相册、位置、剪贴板、设备信息。上述读取均在您的设备上完成。
            1.3 您主动输入的文本、上传的图片或文件，以及您配置的 API 地址与密钥，仅保存在本机沙盒目录。

            二、信息的使用
            2.1 我们仅在为完成您下达的指令（如生成提醒、读取健康数据、调用 AI 对话）时，于本地使用上述信息。
            2.2 我们不会将您的对话内容、文件或敏感数据用于广告推送、用户画像或任何商业分析。
            2.3 与第三方大模型 API 的交互中，您输入的内容会按您所选 API 的配置发送给对应服务商，该过程由您主动发起。

            三、信息的存储与本地处理
            3.1 所有用户数据默认存储在 iOS 沙盒内，其他应用无法访问。
            3.2 您可通过"设置 → 清除缓存"删除本应用生成的文件；历史对话存储于本地，卸载应用即随之删除。
            3.3 我们不在服务器端维护任何用户数据库。

            四、第三方服务与数据共享
            4.1 本应用的 AI 能力依赖您自配的第三方 API。当您发起对话时，相关内容会传输至您指定的服务商，受其隐私政策约束。
            4.2 除您主动配置的 API 及您主动触发的"打开链接"等系统能力外，本应用不会与任何第三方共享数据。
            4.3 我们建议在选择 API 服务商时，阅读并理解其隐私政策与数据处理方式。

            五、敏感数据处理
            5.1 健康、通讯录、位置属于敏感个人信息。本应用仅在您逐项授权后于本地使用，不会上传。
            5.2 部分能力（如 HealthKit）需要以包含相应权利的描述文件重签 IPA；免费 Apple ID 侧载通常无法开启，属系统限制。
            5.3 若您不同意授权某项能力，可随时在系统设置或本应用内关闭，关闭后相关功能将不可用，但不影响其他功能。

            六、儿童隐私
            6.1 本应用不面向未满 14 周岁的儿童，我们不会故意收集儿童的个人信息。如您发现误用，请联系我们处理。

            七、数据安全
            7.1 我们采取符合行业惯例的本地安全措施保护您的数据，但请您知悉，任何本地存储均无法保证绝对安全。
            7.2 请您妥善保管设备锁屏密码与签名证书，避免他人物理接触您的设备后访问数据。

            八、您的权利
            8.1 您有权随时查看、删除本地保存的内容与文件，撤销已授予的系统权限。
            8.2 如您希望进一步了解或行使相关权利，可通过"关于"页中的网站联系我们。

            九、政策的变更
            9.1 我们可能不时更新本政策，更新后将在应用内公布并自公布之日起生效。
            9.2 继续使用本应用即视为您接受更新后的隐私政策。

            十、联系我们
            10.1 隐私相关问题请联系：https://chen.cm。
            """
        case .disclaimer:
            return """
            本免责声明（以下简称"声明"）就 Velos（以下简称"本应用"）的服务性质、能力边界与风险作出说明。使用本应用即表示您已阅读并理解本声明全部内容。

            一、服务性质
            1.1 本应用是一款运行于 iPhone/iPad 的本地的 AI 助手工具，通过调用 iOS 系统能力与您自配的第三方大模型 API 提供辅助功能。
            1.2 本应用并非医疗、法律、金融、投资或任何专业服务机构，其输出不构成专业意见。

            二、AI 生成内容的不保证
            2.1 本应用中的回答、总结、文件、代码等内容由人工智能模型生成，可能存在事实错误、逻辑偏差、时效失真或不符合您预期的情况。
            2.2 开发者不对 AI 生成内容的准确性、完整性、适用性、合法性或安全性作出任何明示或默示担保。
            2.3 您在依据本应用内容作出任何决策前，应自行核实，并自行承担由此产生的后果。

            三、文件与系统操作风险
            3.1 文件生成（文本、演示文稿等）由内置生成器或第三方模型产出，其格式兼容性与内容正确性无法保证，重要文件请自行备份。
            3.2 提醒、日历、闹钟等系统操作依赖 iOS 本地能力，可能因权限、系统版本或证书限制而失败，重要事项请勿单纯依赖本应用。
            3.3 本应用对您设备系统状态所作的变更，均由您主动触发，相关风险由您承担。

            四、第三方服务
            4.1 本应用依赖的第三方 API（如 OpenAI、DeepSeek 等）由您自行配置，其可用性、稳定性、计费、内容审核与数据安全由对应服务商负责。
            4.2 因第三方服务中断、涨价、政策变更、内容违规或数据泄露导致的损失，开发者不承担责任。

            五、健康数据
            5.1 健康数据读取受 iOS 权限与签名能力限制，数据仅供参考，不构成任何健康或医疗建议。
            5.2 如有健康问题，请及时咨询具备资质的医疗专业人员。

            六、专业建议排除
            6.1 本应用输出不得作为医疗、法律、税务、投资、交易等决策的唯一或主要依据。
            6.2 若您基于本应用内容进行实际交易、投资或法律行为，相关风险与责任完全由您自行承担。

            七、责任限制
            7.1 在适用法律允许的最大范围内，开发者不对因使用或无法使用本应用所导致的任何直接、间接、偶然、特殊或后果性损失承担责任。
            7.2 开发者对因网络、设备、证书、第三方服务或不可抗力导致的服务中断不承担责任。

            八、不可抗力
            8.1 因自然灾害、政府行为、网络基础设施故障、Apple 政策变更等不可抗力导致本应用无法使用的，开发者不承担责任。

            九、其他
            9.1 本声明未尽事宜，以用户协议及适用法律为准。
            9.2 本声明与用户协议冲突时，以对用户更为明确提示的条款为准。
            """
        }
    }
}

// MARK: - 关于

struct AboutView: View {
    @State private var hasCrashRecord = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("关于")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                VStack(spacing: AppSpacing.md) {
                    SettingsSection(title: "版本信息") {
                        InfoRow(title: "名称", value: "Velos - 移动AI Agent客户端")

                        Divider().padding(.leading, AppSpacing.md)

                        InfoRow(title: "版本", value: appVersion)

                        Divider().padding(.leading, AppSpacing.md)

                        LinkRow(title: "网站", value: "https://chen.cm", url: "https://chen.cm")

                        Divider().padding(.leading, AppSpacing.md)

                        LinkRow(title: "仓库", value: "https://github.com/chirens/iOSAgent", url: "https://github.com/chirens/iOSAgent")
                    }

                    SettingsSection(title: "诊断") {
                        NavigationLink(value: SettingsRoute.crashLog) {
                            HStack(spacing: AppSpacing.md) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                        .fill(Color.pastelOrange.opacity(0.22))
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.pastelOrange)
                                }

                                Text("崩溃日志")
                                    .font(.appBody().weight(.semibold))
                                    .foregroundStyle(Color.appPrimaryText)

                                Spacer(minLength: 0)

                                if hasCrashRecord {
                                    Circle()
                                        .fill(Color.appError)
                                        .frame(width: 8, height: 8)
                                    Text("有记录")
                                        .font(.appMicro())
                                        .foregroundStyle(Color.appError)
                                } else {
                                    Text("无")
                                        .font(.appMicro())
                                        .foregroundStyle(Color.appSecondaryText)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.appSecondaryText)
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // 公众号「忘仙」二维码 — 居中固定，跟仓库行之间留出明确间距
                    VStack(spacing: AppSpacing.md) {
                        Text("关注公众号「忘仙」")
                            .font(.appBody().weight(.semibold))
                            .foregroundStyle(Color.appPrimaryText)
                        Image("WeChatQRCode")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: 180, height: 180)
                            .padding(AppSpacing.sm)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                                    .strokeBorder(Color.appSeparator, lineWidth: 0.5)
                            )
                        Text("「忘却红尘三千事，自在人间第一仙」")
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.xl)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .appCardShadow()
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .onAppear { hasCrashRecord = CrashDiagnostic.hasAnyRecord }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "8.0"
    }
}

// MARK: - 崩溃诊断（v9.0.8：从设置页顶卡迁入「关于 → 崩溃日志」独立页面）

enum CrashDiagnostic {
    static var crashLogText: String {
        (try? String(contentsOf: CrashGuard.crashLogURL, encoding: .utf8)) ?? ""
    }
    static var breadcrumbText: String { CrashGuard.lastBreadcrumb ?? "" }
    static var hasAnyRecord: Bool { !crashLogText.isEmpty || !breadcrumbText.isEmpty }

    /// 复制 / 分享用的完整文本（日志 + 面包屑）
    static var fullText: String {
        var parts: [String] = []
        let log = crashLogText
        let crumb = breadcrumbText
        if !log.isEmpty { parts.append(log) }
        if !crumb.isEmpty { parts.append("[最后操作] " + crumb) }
        return parts.joined(separator: "\n\n")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: CrashGuard.crashLogURL)
        try? FileManager.default.removeItem(at: CrashGuard.breadcrumbURL)
    }
}

struct CrashLogView: View {
    @State private var logText = ""
    @State private var breadcrumb = ""
    @State private var showShare = false
    @State private var copied = false
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("崩溃日志")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                if logText.isEmpty && breadcrumb.isEmpty {
                    emptyState
                } else {
                    if !breadcrumb.isEmpty { breadcrumbCard }
                    if !logText.isEmpty { logCard }
                    actionBar
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .onAppear(perform: reload)
        // v9.0.9.2: 纯文本分享在微信里不能直接发送（微信会把 [String] 当作纯文本让用户长按复制），
        // 改为同时传文件 URL + 文本：微信会展示"文件"选项直接发，剪贴板/邮件则用文本。
        .sheet(isPresented: $showShare) {
            let url = exportCrashLogAsFile()
            ShareSheet(activityItems: url.map { [$0 as Any, CrashDiagnostic.fullText] } ?? [CrashDiagnostic.fullText])
        }
        .alert("清除崩溃日志？", isPresented: $showClearConfirm) {
            Button("清除", role: .destructive) {
                CrashDiagnostic.clear()
                reload()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除本机保存的崩溃记录与面包屑，此操作不可恢复。")
        }
    }

    private func reload() {
        logText = CrashDiagnostic.crashLogText
        breadcrumb = CrashDiagnostic.breadcrumbText
    }

    /// v9.0.9.2: 把崩溃日志 + 面包屑写到一个 .txt 文件返回 URL，方便微信直接以"文件"形式发送。
    private func exportCrashLogAsFile() -> URL? {
        let text = CrashDiagnostic.fullText
        guard !text.isEmpty else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        let url = docs.appendingPathComponent("Velos崩溃日志_\(stamp).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.appSuccess)
            Text("暂无崩溃记录")
                .font(.appBody().weight(.semibold))
                .foregroundStyle(Color.appPrimaryText)
            Text("如果 App 发生崩溃，日志会自动保存在这里，可一键复制发给开发者。")
                .font(.appCaption())
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xl)
        .padding(.horizontal, AppSpacing.md)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private var breadcrumbCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("崩溃前最后操作")
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
            Text(breadcrumb)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appError)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("崩溃记录")
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
            Text(logText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appPrimaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private var actionBar: some View {
        HStack(spacing: AppSpacing.sm) {
            actionButton(title: copied ? "已复制" : "复制", icon: "doc.on.doc", filled: true) {
                UIPasteboard.general.string = CrashDiagnostic.fullText
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            actionButton(title: "分享", icon: "square.and.arrow.up", filled: false) { showShare = true }
            actionButton(title: "清除", icon: "trash", filled: false, danger: true) { showClearConfirm = true }
        }
    }

    private func actionButton(title: String, icon: String, filled: Bool, danger: Bool = false,
                              action: @escaping () -> Void) -> some View {
        let fg: Color = filled ? Color.white : (danger ? Color.appError : Color.appPrimaryText)
        let stroke: Color = filled ? Color.clear : (danger ? Color.appError : Color.appSeparator)
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(title)
                    .font(.appCaption().weight(.semibold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(filled ? Color.brandAccent : Color.appSurface)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.appBody().weight(.semibold))
                .foregroundStyle(Color.appPrimaryText)
            Spacer()
            Text(value)
                .font(.appCaption())
                .foregroundStyle(Color.appSecondaryText)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
    }
}

struct LinkRow: View {
    let title: String
    let value: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(.appBody().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
                Text(value)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.brandAccent)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 技能中心（搜索 + 从 GitHub 安装 + 删除）

struct SkillsView: View {
    @ObservedObject private var router = SkillRouter.shared
    @EnvironmentObject var settings: SettingsStore
    /// 统一输入：既可以是搜索关键词，也可以是 GitHub 链接
    @State private var input = ""
    @State private var installing = false
    @State private var message: String?
    @State private var errorText: String?

    // GitHub 搜索状态
    @State private var ghResults: [SkillGitHubSearchResult] = []
    @State private var ghLoading = false
    @State private var ghError: String?
    @State private var hasSearched = false
    @State private var installingIDs: Set<String> = []
    @State private var searchCache: [String: [SkillGitHubSearchResult]] = [:]
    // 限流防护：冷却截止时间（令牌直接绑定 settings.githubToken）
    @State private var ghCooldownUntil: Date = .distantPast

    /// 输入内容是否为链接 → 决定主按钮是「安装」还是「搜索」
    private var isURLInput: Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("github.com")
    }

    private var canSubmit: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Text("技能中心")
                    .font(.appTitle1())
                    .foregroundStyle(Color.appPrimaryText)

                searchCard

                aiGenerationCard

                if hasSearched {
                    githubResultsSection
                }

                installedSection
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
    }

    // MARK: - 统一输入卡（搜索关键词 / 粘贴 GitHub 链接）

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: isURLInput ? "link" : "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appSecondaryText)
                TextField("搜索关键词 或 粘贴 GitHub 链接", text: $input)
                    .font(.appBody())
                    .foregroundStyle(Color.appPrimaryText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if ghLoading || installing {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                Button(action: submitTapped) {
                    Text(isURLInput ? "安装" : "搜索")
                        .font(.appBody().weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, AppSpacing.md)
                        .frame(height: 34)
                        .background(canSubmit ? Color.brandAccent : Color.appSeparator)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                }
                .disabled(!canSubmit || ghLoading || installing)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.appInputFill)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

            Text(isURLInput ? "识别到链接，点「安装」直接安装该 skill" : "输入关键词后点「搜索」，在 GitHub 上找 skill")
                .font(.appMicro())
                .foregroundStyle(Color.appSecondaryText)
                .padding(.leading, AppSpacing.md)

            if let message {
                Text(message)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSuccess)
                    .padding(.leading, AppSpacing.md)
            }
            if let errorText {
                Text(errorText)
                    .font(.appCaption())
                    .foregroundStyle(Color.appError)
                    .padding(.leading, AppSpacing.md)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    private func submitTapped() {
        if isURLInput { installTapped() } else { performSearch() }
    }

    private func performSearch() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        hasSearched = true
        message = nil
        errorText = nil
        ghError = nil

        if Date() < ghCooldownUntil {
            ghError = "GitHub 限流中，请稍后再试"
            ghResults = []
            return
        }
        if let cached = searchCache[q] {
            ghResults = cached
            return
        }

        ghResults = []
        ghLoading = true
        Task {
            defer { ghLoading = false }
            do {
                let results = try await SkillInstaller.searchGitHub(query: q)
                searchCache[q] = results
                ghResults = results
            } catch is CancellationError {
                return
            } catch {
                if let err = error as? SkillInstallError, case .rateLimited(let sec) = err {
                    ghCooldownUntil = Date().addingTimeInterval(Double(max(sec, 10)))
                    ghError = err.errorDescription
                } else {
                    ghError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: - AI 生成（原设置页「图片生成」区块）

    private var aiGenerationCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appSuccess)
                Text("AI 生成 · 已默认配置")
                    .font(.appCaption2().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.md)

            Text("开箱即用，对话里直接说「画一张…」即可生成图片。密钥仅在本机与请求头中保存，不参与聊天内容。")
                .font(.appCaption2())
                .foregroundStyle(Color.appSecondaryText)
                .lineLimit(nil)
                .padding(.horizontal, AppSpacing.md)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    HStack(spacing: AppSpacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appSecondaryText)
                        Text("SiliconFlow API Key（高级）")
                            .font(.appCaption2().weight(.semibold))
                            .foregroundStyle(Color.appSecondaryText)
                        Spacer(minLength: 0)
                        if !settings.mediaProviderKey.isEmpty {
                            Text("已配置")
                                .font(.appMicro())
                                .foregroundStyle(Color.appSuccess)
                        }
                    }
                    .padding(.leading, AppSpacing.md)
                    AppSecureField(placeholder: "sk-xxx",
                                   text: Binding(get: { settings.mediaProviderKey },
                                                set: { settings.mediaProviderKey = $0 }))
                        .padding(.horizontal, AppSpacing.md)
                    Text("填入后优先使用你自己的额度（更高画质 / 自定义尺寸）。留空即可，不影响基础使用。")
                        .font(.appMicro())
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(nil)
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.bottom, AppSpacing.sm)
                }
            } label: {
                Text("高级：自带 Key")
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.bottom, AppSpacing.sm)
        }
        .padding(.vertical, AppSpacing.sm)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .appCardShadow()
    }

    // MARK: - 已安装技能

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("已安装技能（\(router.allSkills.count)）")
                .font(.appCaption2().weight(.semibold))
                .foregroundStyle(Color.appSecondaryText)
                .padding(.leading, AppSpacing.md)

            if router.allSkills.isEmpty {
                Text("暂无已安装技能")
                    .font(.appSubheadline())
                    .foregroundStyle(Color.appSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AppSpacing.md)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    .appCardShadow()
            } else {
                List {
                    ForEach(router.allSkills) { skill in
                        skillRow(skill)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.appSurface)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !skill.isBuiltIn {
                                    Button(role: .destructive) { deleteSkill(skill) } label: { Label("删除", systemImage: "trash") }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: max(CGFloat(router.allSkills.count) * 72, 1))
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                .appCardShadow()
            }
        }
    }

    private var githubResultsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("GitHub 搜索结果")
                    .font(.appCaption2().weight(.semibold))
                    .foregroundStyle(Color.appSecondaryText)
                Spacer()
                if ghLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, AppSpacing.md)

            if let ghError {
                HStack(spacing: AppSpacing.sm) {
                    Text(ghError)
                        .font(.appCaption())
                        .foregroundStyle(Color.appError)
                    Spacer(minLength: 0)
                    Button("重试") {
                        searchCache.removeValue(forKey: input.trimmingCharacters(in: .whitespacesAndNewlines))
                        performSearch()
                    }
                    .font(.appCaption().weight(.semibold))
                    .foregroundStyle(Color.brandAccent)
                }
                .padding(.horizontal, AppSpacing.md)
            }

            VStack(spacing: 0) {
                if ghResults.isEmpty && !ghLoading && ghError == nil {
                    Text("未找到匹配的 skill 文件")
                        .font(.appSubheadline())
                        .foregroundStyle(Color.appSecondaryText)
                        .padding(AppSpacing.md)
                } else {
                    ForEach(ghResults) { result in
                        githubResultRow(result)
                        if result.id != ghResults.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()
        }
    }

    private func githubResultRow(_ result: SkillGitHubSearchResult) -> some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(Color.brandAccent.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.brandAccent)
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(result.fullName)
                    .font(.appSubheadline().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                Text(result.path)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                installSearchResult(result)
            } label: {
                if installingIDs.contains(result.id.uuidString) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 56, height: 32)
                } else {
                    Text("安装")
                        .font(.appCaption().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Color.brandAccent)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                }
            }
            .disabled(installingIDs.contains(result.id.uuidString))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .contentShape(Rectangle())
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(Color.brandAccent.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: skill.icon.isEmpty ? "sparkles" : skill.icon)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.brandAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.appSubheadline().weight(.semibold))
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)
                    if !skill.isBuiltIn {
                        Text("用户")
                            .font(.appMicro())
                            .foregroundStyle(Color.appSecondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appInputFill)
                            .clipShape(Capsule())
                    }
                }
                Text(skill.description)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .contentShape(Rectangle())
    }

    private func installTapped() {
        let url = input
        installing = true
        errorText = nil
        message = nil
        Task {
            do {
                let installed = try await router.install(from: url)
                message = "已安装 \(installed.count) 个技能：\(installed.map { $0.name }.joined(separator: "、"))"
                input = ""
            } catch is CancellationError {
                installing = false
                return
            } catch {
                if let err = error as? SkillInstallError, case .rateLimited(let sec) = err {
                    ghCooldownUntil = Date().addingTimeInterval(Double(max(sec, 10)))
                    errorText = err.errorDescription
                } else {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            installing = false
        }
    }

    private func installSearchResult(_ result: SkillGitHubSearchResult) {
        let id = result.id.uuidString
        installingIDs.insert(id)
        message = nil
        errorText = nil
        Task {
            do {
                let installed = try await router.install(from: result.htmlURL)
                message = "已安装 \(installed.count) 个技能：\(installed.map { $0.name }.joined(separator: "、"))"
            } catch {
                if let err = error as? SkillInstallError, case .rateLimited(let sec) = err {
                    ghCooldownUntil = Date().addingTimeInterval(Double(max(sec, 10)))
                    errorText = err.errorDescription
                } else {
                    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            installingIDs.remove(id)
        }
    }

    private func deleteSkill(_ skill: Skill) {
        try? router.remove(userSkillID: skill.id)
    }
}

// MARK: - Capability Toggle Row

struct CapabilityToggleRow: View {
    @EnvironmentObject var settings: SettingsStore
    let key: String
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(color.opacity(0.4))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.appBody().weight(.semibold))
                .foregroundStyle(Color.appPrimaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { settings.isEnabled(key) },
                set: { newValue in
                    settings.setEnabled(key, newValue)
                    if newValue {
                        Task {
                            let status = await settings.requestAuth(for: key)
                            if status != .authorized && status != .limited {
                                settings.setEnabled(key, false)
                            }
                        }
                    }
                }
            ))
            .labelsHidden()
            .tint(Color.brandAccent)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
    }
}

// MARK: - Shared Form Components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.appCaption2().weight(.semibold))
            .foregroundStyle(Color.appSecondaryText)
            .padding(.horizontal, AppSpacing.md)
    }
}

struct AppTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.appBody())
            .foregroundStyle(Color.appPrimaryText)
            .autocapitalization(.none)
            .keyboardType(keyboard)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .background(Color.appInputFill)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

struct AppSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .font(.appBody())
            .foregroundStyle(Color.appPrimaryText)
            .autocapitalization(.none)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.md)
            .background(Color.appInputFill)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

// MARK: - 账户页（醒目入口：侧边栏头像 / 设置顶卡片均可进入）

/// 头像视图：优先显示已保存头像，无头像时显示 App Logo，最后 fallback 到人形占位。
struct AccountAvatarView: View {
    let size: CGFloat
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        avatarBody
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.appSeparator, lineWidth: 1))
    }

    private var appLogoImage: Image? {
        if let ui = UIImage(named: "AppLogo") { return Image(uiImage: ui) }
        return nil
    }

    @ViewBuilder
    private var avatarBody: some View {
        if !settings.authAvatarData.isEmpty, let img = UIImage(data: settings.authAvatarData) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let logo = appLogoImage {
            logo
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFill()
                .foregroundStyle(Color.appSecondaryText)
                .background(Color.appInputFill)
        }
    }
}

// MARK: - 微信标识 / 登录输入组件

/// 微信标识小图标（Assets: WechatMark，缺失时回落到 SF 双气泡）
struct WechatBadge: View {
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let ui = UIImage(named: "WechatMark") {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.appWechat)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 带左侧图标的输入行（密码支持明文切换）
struct AuthIconField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appSecondaryText)
                .frame(width: 20)

            Group {
                if isSecure && !revealed {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .keyboardType(keyboard)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .font(.appBody())
            .foregroundStyle(Color.appPrimaryText)

            if isSecure {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appSecondaryText)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 13)
        .background(Color.appInputFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

struct AccountView: View {
    @EnvironmentObject var settings: SettingsStore

    // 邮箱登录 / 注册
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var agreed = false
    @State private var mode: Int = 0          // 0 登录, 1 注册
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false

    // 已登录
    @State private var draftName = ""
    @State private var showNameEditor = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showDeleteConfirm = false
    @State private var deleting = false

    // 微信授权登录
    @State private var wechatState = ""
    @State private var wechatWaiting = false
    @State private var wechatPolling = false
    @State private var wechatMsg: String?

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                if settings.isLoggedIn { profileSection } else { authSection }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(Color.appBackground)
        .onAppear {
            draftName = settings.authDisplayName.isEmpty
                ? (settings.authUser.isEmpty ? settings.authEmail : settings.authUser)
                : settings.authDisplayName
        }
        // 从 Safari/微信授权页返回时自动确认一次（iOS 16 兼容写法，不用 onChange(of:)）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if wechatWaiting { pollWechat() }
        }
        .alert("修改用户名", isPresented: $showNameEditor) {
            TextField("1–8 个字符", text: $draftName)
            Button("取消", role: .cancel) {
                draftName = settings.authDisplayName
            }
            Button("保存") { saveName() }
        } message: {
            Text("用户名最长 8 个字符，保存后会同步到服务器。")
        }
        .alert("注销账号", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("注销", role: .destructive) { deleteAccount() }
        } message: {
            Text("注销后将永久删除服务器上的账号与该文件，且无法恢复。确定继续吗？")
        }
    }

    // MARK: 已登录 —— 头像居中 + 用户名 / 邮箱 / 注销账号 + 红色退出登录

    private var profileSection: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: 0) {
                PhotosPicker(selection: Binding(
                    get: { photoItem },
                    set: { newItem in
                        photoItem = newItem
                        if let newItem {
                            Task {
                                if let data = await loadImageData(newItem) {
                                    await MainActor.run { settings.authAvatarData = data }
                                }
                            }
                        }
                    }
                ), matching: .images) {
                    AccountAvatarView(size: 96)
                        .overlay(alignment: .bottomTrailing) {
                            ZStack {
                                Circle()
                                    .fill(Color.appSurface)
                                    .frame(width: 30, height: 30)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.brandAccent)
                            }
                            .offset(x: 2, y: 2)
                        }
                }
                .buttonStyle(.plain)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.lg)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                profileRow(
                    title: "用户名",
                    value: settings.authDisplayName.isEmpty ? settings.authUser : settings.authDisplayName,
                    showWechat: settings.accountProvider == .wechat,
                    chevron: true
                ) { showNameEditor = true }

                Divider().padding(.leading, AppSpacing.md)

                profileRow(
                    title: "邮箱",
                    value: settings.accountProvider == .wechat ? "未绑定邮箱" : settings.authEmail,
                    showWechat: false,
                    chevron: false
                ) {}

                Divider().padding(.leading, AppSpacing.md)

                Button { showDeleteConfirm = true } label: {
                    HStack(spacing: AppSpacing.sm) {
                        Text("注销账号")
                            .font(.appBody().weight(.semibold))
                            .foregroundStyle(Color.appError)
                        Spacer(minLength: 0)
                        if deleting { ProgressView().scaleEffect(0.8) }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(deleting)
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .appCardShadow()

            if let message {
                Text(message)
                    .font(.appCaption())
                    .foregroundStyle(messageIsError ? Color.appError : Color.appSuccess)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button { settings.logoutAccount() } label: {
                HStack {
                    Spacer()
                    Text("退出登录")
                        .font(.appBody().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 13)
                    Spacer()
                }
                .background(Color.appError)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func profileRow(title: String, value: String, showWechat: Bool, chevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(.appBody().weight(.semibold))
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
                if showWechat { WechatBadge(size: 15) }
                Text(value.isEmpty ? "未设置" : value)
                    .font(.appSubheadline())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chevron)
    }

    // MARK: 未登录 —— 大厂风格注册 / 登录页

    private var authSection: some View {
        VStack(spacing: AppSpacing.lg) {
            VStack(spacing: 10) {
                Group {
                    if let ui = UIImage(named: "AppLogo") {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "app.badge.checkmark")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.brandAccent)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text(mode == 0 ? "登录 Velos" : "创建 Velos 账号")
                    .font(.appTitle1().weight(.bold))
                    .foregroundStyle(Color.appPrimaryText)

                Text(mode == 0 ? "登录后可同步账号、调用远程渲染与文件生成" : "邮箱 + 密码，30 秒完成注册")
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, AppSpacing.sm)

            Picker("", selection: $mode) {
                Text("邮箱登录").tag(0)
                Text("邮箱注册").tag(1)
            }
            .pickerStyle(.segmented)
            .tint(Color.brandAccent)

            VStack(spacing: AppSpacing.sm) {
                AuthIconField(icon: "envelope.fill", placeholder: "邮箱", text: $email, keyboard: .emailAddress)
                if mode == 1 {
                    AuthIconField(icon: "person.fill", placeholder: "用户名（1–8 个字符）", text: $displayName)
                }
                AuthIconField(icon: "lock.fill", placeholder: "密码（至少 6 位）", text: $password, isSecure: true)
            }

            if mode == 1 {
                Button { agreed.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: agreed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(agreed ? Color.brandAccent : Color.appSecondaryText)
                        Text("我已阅读并同意《用户协议》与《隐私政策》")
                            .font(.appCaption())
                            .foregroundStyle(Color.appSecondaryText)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let message {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: messageIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(message)
                        .lineLimit(nil)
                    Spacer(minLength: 0)
                }
                .font(.appCaption())
                .foregroundStyle(messageIsError ? Color.appError : Color.appSuccess)
            }

            Button { submit() } label: {
                ZStack {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Text(mode == 0 ? "登录" : "注册并登录")
                            .font(.appBody().weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(canSubmit ? Color.brandAccent : Color.appSecondaryText.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy || !canSubmit)

            HStack(spacing: AppSpacing.sm) {
                Rectangle().fill(Color.appSeparator).frame(height: 1)
                Text("其他登录方式")
                    .font(.appCaption2())
                    .foregroundStyle(Color.appSecondaryText)
                Rectangle().fill(Color.appSeparator).frame(height: 1)
            }

            Button { startWechatLogin() } label: {
                HStack(spacing: 8) {
                    WechatBadge(size: 20)
                    Text("微信登录")
                        .font(.appBody().weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.appWechat)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            if wechatWaiting {
                VStack(spacing: 8) {
                    Text("已在浏览器中打开微信授权，完成授权后返回本页即可自动登录。")
                        .font(.appCaption())
                        .foregroundStyle(Color.appSecondaryText)
                        .multilineTextAlignment(.center)
                    Button { pollWechat() } label: {
                        Text(wechatPolling ? "正在确认…" : "我已完成授权")
                            .font(.appSubheadline().weight(.semibold))
                            .foregroundStyle(Color.brandAccent)
                    }
                    .disabled(wechatPolling)
                }
            }

            if let wechatMsg {
                Text(wechatMsg)
                    .font(.appCaption())
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(nil)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canSubmit: Bool {
        let mailOK = email.trimmingCharacters(in: .whitespaces).contains("@")
        let pwOK = password.count >= 6
        guard mode == 1 else { return mailOK && pwOK }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        return mailOK && pwOK && !name.isEmpty && name.count <= 8 && agreed
    }

    // MARK: 动作

    private func submit() {
        busy = true
        message = nil
        Task {
            let err = await settings.accountAuth(
                endpoint: settings.connectorEndpoint,
                email: email,
                password: password,
                displayName: displayName,
                mode: mode == 0 ? .login : .register
            )
            await MainActor.run {
                busy = false
                if let err {
                    message = err
                    messageIsError = true
                } else {
                    message = mode == 0 ? "登录成功" : "注册成功"
                    messageIsError = false
                    password = ""
                }
            }
        }
    }

    private func saveName() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 8 else {
            message = "用户名需为 1–8 个字符"
            messageIsError = true
            return
        }
        Task {
            let err = await settings.updateAccountProfile(displayName: name)
            await MainActor.run {
                if let err {
                    message = err
                    messageIsError = true
                } else {
                    message = "用户名已更新"
                    messageIsError = false
                }
            }
        }
    }

    private func deleteAccount() {
        deleting = true
        Task {
            let err = await settings.deleteAccount()
            await MainActor.run {
                deleting = false
                if let err {
                    message = err
                    messageIsError = true
                } else {
                    message = "账号已注销"
                    messageIsError = false
                }
            }
        }
    }

    private func startWechatLogin() {
        wechatMsg = nil
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        wechatState = state
        Task {
            let r = await settings.wechatStart(state: state)
            await MainActor.run {
                if r.configured, let url = r.url {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    wechatWaiting = true
                } else {
                    wechatMsg = r.message ?? "微信登录暂不可用，请稍后再试。"
                }
            }
        }
    }

    private func pollWechat() {
        guard !wechatState.isEmpty, !wechatPolling else { return }
        wechatPolling = true
        let state = wechatState
        Task {
            let r = await settings.wechatPoll(state: state)
            if r.ok, let token = r.token {
                await settings.applyWechatLogin(token: token,
                                                email: r.email ?? "",
                                                username: r.username ?? "微信用户",
                                                avatarURL: r.avatar)
                await MainActor.run {
                    wechatWaiting = false
                    wechatMsg = nil
                }
            } else {
                await MainActor.run {
                    wechatMsg = "尚未检测到授权结果，请在浏览器中完成微信授权后返回本页。"
                }
            }
            await MainActor.run { wechatPolling = false }
        }
    }

    /// 从 PhotosPickerItem 读取图片 Data（iOS 16 安全：走 loadTransferable，Data 符合 Transferable）。
    private func loadImageData(_ item: PhotosPickerItem) async -> Data? {
        try? await item.loadTransferable(type: Data.self)
    }
}

struct AccountRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onBack: () -> Void
    var body: some View {
        NavigationStack {
            AccountView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.brandAccent)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                    }
                }
                // AccountRootView 是从侧边栏覆盖进来的（不是 push 出来的），
                // NavigationStack 根视图没有"上一层"可 pop，右滑默认失效。
                // 显式追加一个左缘右滑手势来关闭覆盖层，与 SettingsRootView 行为一致。
                .overlay(alignment: .leading) {
                    Color.clear
                        .frame(width: 44)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 16)
                                .onChanged { _ in }
                                .onEnded { value in
                                    if value.translation.width > 50 {
                                        onBack()
                                    }
                                }
                        )
                }
        }
        .background(Color.appBackground)
        .toolbarBackground(Color.appBackground, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
    }
}
