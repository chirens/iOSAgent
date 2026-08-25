# iOSAgent —— 手机端 Agent IPA 架构设计与 MVP 路线图

> 定位：一款能装进 iPhone、**独立运行**、对标 OpenMinis 但更强的 Agent App。
> 分发：当前**自签/侧载**（你有证书），App Store 上架为后续选项。
> 大脑：MVP 用**云端 API**（OpenAI 兼容）快速验证；成熟后切**端侧模型**或**付费模式**。

---

## 一、产品定位与差异化

| 维度 | OpenMinis | iOSAgent（目标） |
|---|---|---|
| 大脑 | 纯云端 API key | 云端 API 起步 → 端侧模型（iOS 19 Foundation Models / Core AI）兜底，断网可用 |
| 视觉 | 仅自带浏览器内截图 | 端侧 VLM 读**相册截图**识位（离线闭环） |
| 跨 App 操作 | URL Scheme 打开 | URL Scheme + 主动消费他家 App 的 **App Intents** + 动态生成 **Shortcuts** |
| 系统入口 | 快捷指令定时触发 | 控制中心/锁屏控件 + Live Activity 状态面板 + Action Button + 灵动岛 |
| 权限深度 | 原生框架读写 | 同等 + 把自身能力**反向暴露给 Siri/系统**形成双向 |

核心差异化口号：**「看得见（相册截图+VLM）、动得了（URL Scheme/App Intents/Shortcuts）、离得开（端侧模型）」**。

---

## 二、技术选型

- **语言/框架**：Swift + SwiftUI（iOS 17 起步，后续升 19 用新 API）。
- **模型接入**：
  - MVP：`AgentClient` 直连 OpenAI 兼容 `/chat/completions`，支持 `image_url` 视觉多模态。
  - 下一阶段：在 `AgentClient` 内增加「端侧分支」——调用 iOS 19 `FoundationModels` 框架或 `Core AI` 载入 MLX 量化模型（如 Qwen2.5-VL-3B 4bit，已证明可在 iPhone 跑）。
- **跨 App 操作三通道**：
  1. `OpenAppIntent` —— URL Scheme 打开/传参。
  2. 消费他家 App 暴露的 App Intents（随生态增长而增强）。
  3. 动态生成/运行 Shortcuts（最强跨 App 编排）。
- **系统级入口**：App Intents 自动进「快捷指令」；后续加 `ControlConfigurationIntent`（控制中心/锁屏）、Live Activity（状态面板）。

---

## 三、模块架构

```
┌─────────────────────────────────────────────┐
│                  iOSAgent (App)              │
│                                               │
│  ContentView (TabView)                        │
│    ├─ ChatView ──────┐                        │
│    │   (对话 + 截图)  │                        │
│    └─ SettingsView ──┤                        │
│         (API 配置)   │                        │
│                      ▼                        │
│              AgentClient (网络层)             │
│        ┌────────────┴─────────────┐          │
│        │ 云端 API (/chat/completions)│        │
│        │ 后续: 端侧模型分支          │         │
│        └────────────┬─────────────┘          │
│                      │                        │
│  PhotoPicker ──► 相册截图 ──► VLM 视觉识别     │
│                                               │
│  AgentIntents (暴露给 Siri/快捷指令)           │
│    ├─ OpenAppIntent   (URL Scheme)            │
│    └─ AskAgentIntent  (问 Agent)              │
└─────────────────────────────────────────────┘
        │
        ▼
  Photos / Health / Contacts / Calendar / HomeKit / Location ...（原生框架权限）
  其他 App：URL Scheme / App Intents / Shortcuts（仅此三通道）
```

---

## 四、权限矩阵（iOS 现实边界，必须看清）

**能拿到的（手机本体，无沙盒限制，靠授权/entitlement）：**
Photos、HealthKit、Contacts、Calendar、Reminders、Location、Motion、HomeKit、Bluetooth、NFC、本地通知、Camera、Speech、剪贴板、文件。

**能「操作别的 App」的三条合法通道：**
- URL Scheme（打开+传参，零成本）
- App Intents（调用他家 App 暴露的动作）
- Shortcuts（动态编排多 App，最强）

**拿不到的（除非越狱）：**
- 读取任意 App 的 UI 树/屏幕像素
- 系统级截图（截别的 App）
- 程序化坐标点击注入

> 结论：「截图识位后操作 App」在本产品里的正确形态是——**用户截图→落相册→端侧 VLM 读图→识别是哪个 App/什么状态→生成对应的 URL Scheme / App Intent / Shortcuts 动作**（而非点坐标）。iOS 19 的「屏幕感知」归 Siri/系统，你的 App 只能通过暴露 Intent 间接参与。

---

## 五、当前 MVP 已实现（v0.1）

工程位置：`iOSAgent/`（Xcode 工程 + 7 个 Swift 源文件）

1. **云端 API 配置**：设置页填 Base URL / API Key / 模型名，存 `UserDefaults`（后续迁 Keychain）。
2. **连接测试**：一键发 `ping` 验证 Key 可用。
3. **对话 + 视觉**：对话页可附一张相册截图，走 `image_url` 多模态发给模型，实现「看图识物/识界面」。
4. **App Intents 暴露**：
   - `OpenAppIntent`：用 URL Scheme 打开其他 App（如 `maps://`、`tel://`）。
   - `AskAgentIntent`：让 Siri/快捷指令直接问 Agent 并取回答。
5. **自签 entitlements**：`get-task-allow`，配合你的证书侧载。

---

## 六、分阶段路线图

- **v0.1（本版）**：云端 API + 对话 + 相册截图视觉 + 基础 App Intents。✅ 已完成骨架。
- **v0.2 端侧大脑**：`AgentClient` 增加端侧分支，iOS 19 `FoundationModels` / `Core AI` 跑本地模型，断网可用、零成本。
- **v0.3 视觉闭环增强**：截图→VLM 识别后，**自动映射到 URL Scheme / 调起对应 App 的 Intent**（而非只对话），形成「看→想→动」。
- **v0.4 跨 App 编排**：动态生成/运行 Shortcuts；消费他家 App 的 App Intents；建立常用 App 的「动作字典」。
- **v0.5 系统级入口**：控制中心/锁屏控件（`ControlConfigurationIntent`）、Live Activity 状态面板、Action Button、灵动岛。
- **v0.6 权限加深 + 付费化**：Health/HomeKit/Location 深度联动；可选付费云端模型（回本 API 成本）；Keychain 存 Key；考虑 App Store 合规化改造。

---

## 六之二、v2.0 已交付（2026-08-25，对标 OpenMinis 强化系统能力）

把 1.0 的「纯聊天壳」升级为真正能「动手」的 agent：

**1. Agent 工具调用循环（核心）**
- `AgentClient.run()` 改为带 `tool_calling` 的循环：发消息 → 若模型返回 `tool_calls` → 在 Swift 里执行 → 结果回灌模型 → 直到模型给出最终自然语言回复（最多 6 轮）。
- 模型用 DeepSeek（默认 `deepseek-chat`，支持 function calling）。你在对话里说「明早 8 点提醒我开会」，模型自动调用 `create_reminder` 工具，app 用 EventKit 真实写入「提醒事项」App。

**2. 与 OpenMinis 的对比（它怎么做的 / 我们怎么做的）**
| 能力 | OpenMinis 实现方式 | iOSAgent 2.0 实现方式 |
|---|---|---|
| 提醒 / 日历 | iSH(Alpine) 里写 CLI 桥接 EventKit | 直接在 Swift 调 EventKit（同等效果，更轻更稳） |
| 健康数据 | iSH + HealthKit CLI | 直接在 Swift 调 HealthKit |
| 闹钟 | 本地通知 / 日历提醒（非系统时钟） | `UNUserNotificationCenter` 本地通知（同样非系统时钟） |
| 权限控制 | App 内细粒度开关 | 设置里逐项开关 + 按需弹系统授权 |

> 结论：**两者底层都只能用苹果开放的框架（EventKit/HealthKit/通知），都不能写系统「时钟」App 的闹钟、不能读别的 App 界面/系统截图**——这是 iOS 沙盒硬墙。Minis 的"16 个闹钟"本质是循环创建本地通知/日历提醒。我们走同效但更直接的路线，不塞一个 Linux 进 App。

**3. 已接入的系统工具（随设置开关启用）**
`create_reminder` / `list_reminders` / `create_calendar_event` / `schedule_alarm`（本地通知）/ `read_health`（步数/心率/睡眠/活动能量/体重）。

**4. 多会话 + 归档**
- `ChatStore` 全局管理多个会话，持久化到 `Documents/conversations.json`。
- 侧栏可「新建对话」「归档/删除（左滑或长按）」，打开即不再是单一对话框。
- 会话按更新时间排序、自动置顶、首条用户消息自动生成标题。

**5. 设置页增强**
- API 配置（Base URL / Key / 模型）+ 连接测试（保留）。
- **系统能力开关**：提醒事项 / 日历 / 健康数据 / 闹钟·本地提醒 / 通讯录（预留），开关打开时即时请求系统授权并展示授权状态。
- 内置说明：解释 iOSAgent 与 Minis 的差异，以及"闹钟=本地通知"的限制。

**6. 版本与权限**
- `MARKETING_VERSION = 2.0`。
- `Info.plist` 新增：提醒/日历/健康(读+写预留)/通讯录 的用途描述。
- `entitlements` 加入 `com.apple.developer.healthkit`。

> ⚠️ **侧载安装注意**：HealthKit 是特殊 entitlement，需要描述文件（mobileprovision）为该 App ID 启用 HealthKit 才能安装。若你用 Feather/ESign 自签时**安装报错提到 healthkit entitlement**，二选一：① 确认你的描述文件已为 `com.chen.iOSAgent` 启用 HealthKit（Xcode 自动签名/付费账号最稳）；② 临时删除 `iOSAgent.entitlements` 里的 `<key>com.apple.developer.healthkit</key><true/>` 这行并重新云编译，健康开关会失效但其余功能正常安装。

---

## 七、自签 / 侧载构建步骤

> 你在 Mac + Xcode 上操作（本机 Windows 只负责产出源码）。

方式一（推荐，直接用本工程）：
1. 把 `iOSAgent/` 整个文件夹拷到 Mac。
2. 双击 `iOSAgent.xcodeproj` 打开（若工程文件报错，见下方兜底）。
3. 选中 Target → Signing & Capabilities → 选你的 Team（证书），Bundle ID 改成你自己的（如 `com.你的名.iOSAgent`）。
4. 真机连接 → 信任开发者 → Build & Run。

方式二（兜底，工程文件打不开时）：
1. Xcode → New → Project → iOS App（Interface: SwiftUI，Language: Swift）。
2. 把 `iOSAgent/iOSAgent/*.swift` 7 个文件拖进新工程（替换默认 ContentView/App）。
3. 在 Target → Info 加 `NSPhotoLibraryUsageDescription`（值：需要读取相册截图以进行视觉识别）。
4. 照方式一第 3、4 步签名运行。

> 注意：`AgentIntents.swift` 用了 `AppIntents` 框架，编译后 Intent 会自动出现在「快捷指令」App 里，可直接用或让 Siri 调用。

---

## 八、风险与天花板（务必记住）

1. **iOS 沙盒硬墙**：第三方 App 不能看/点别的 App 界面、不能系统截图。所有「操作别的 App」只能走 URL Scheme / App Intents / Shortcuts。真正的 UI 级控制只有越狱，而越狱 = 无法上架 + 安全风险，是另一条产品线。
2. **API Key 安全**：MVP 存 `UserDefaults` 明文，仅自测可用；正式版必须 Keychain。
3. **审核风险（若上架）**：强调「自动操作别家 App」易撞 4.1/自动化条款，需话术规避（包装成「隐私 AI 助手/自动化」）。
4. **端侧模型体积**：Qwen2.5-VL-3B 4bit 约 2.2GB，需按需下载，考虑流量/存储与 A 系列芯片门槛（建议 iPhone 15 Pro+/16 起）。
