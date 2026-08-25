import SwiftUI

struct CapabilityCard: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let title: String
    let desc: String
    let example: String
}

struct CapabilitiesView: View {
    let cards: [CapabilityCard] = [
        CapabilityCard(icon: "alarm.fill", color: .orange, title: "闹钟 & 提醒", desc: "设置一次性闹钟、倒计时，到点响铃弹窗", example: "“5分钟后叫我”"),
        CapabilityCard(icon: "checklist.checked", color: .blue, title: "提醒事项", desc: "写入系统提醒事项 App，可列出/完成", example: "“提醒我明天交报告”"),
        CapabilityCard(icon: "calendar.badge.plus", color: .red, title: "日历日程", desc: "创建和查询日历事件", example: "“下周一下午3点开会”"),
        CapabilityCard(icon: "heart.fill", color: .pink, title: "健康数据", desc: "读取步数、心率、睡眠、活动能量", example: "“我最近一周走了多少步”"),
        CapabilityCard(icon: "person.2.fill", color: .green, title: "通讯录", desc: "搜索联系人姓名、电话、邮箱", example: "“查一下张三是哪个号码”"),
        CapabilityCard(icon: "location.fill", color: .indigo, title: "当前位置", desc: "获取经纬度和粗略城市", example: "“我现在在哪”"),
        CapabilityCard(icon: "doc.on.clipboard", color: .yellow, title: "剪贴板", desc: "读取/写入剪贴板文本", example: "“把这段文字复制到剪贴板”"),
        CapabilityCard(icon: "photo.fill", color: .purple, title: "相册", desc: "枚举最近照片并在对话中查看", example: "“发一下最近3张照片”"),
        CapabilityCard(icon: "iphone", color: .gray, title: "设备信息", desc: "型号、系统版本、电量、存储", example: "“我手机电量多少”"),
        CapabilityCard(icon: "arrow.up.forward.app.fill", color: .teal, title: "打开 App / URL", desc: "跳转指定 URL Scheme 或网页", example: "“打开微信”"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("iOSAgent 能做什么")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal)

                Text("所有能力均通过 iOS 原生框架直接调用，无需越狱，无需借助其他 App。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(card.color.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Image(systemName: card.icon)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(card.color)
                            }
                            Text(card.title)
                                .font(.headline)
                            Text(card.desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Text(card.example)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(card.color.opacity(0.9))
                                .clipShape(Capsule())
                        }
                        .frame(height: 170)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
    }
}
