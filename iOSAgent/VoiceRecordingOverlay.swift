import SwiftUI

/// 语音录制结束后的处理方式
enum VoiceFinishMode {
    case send       // 直接发送语音转写结果
    case transcribe // 转成文字填入输入框，不切发送
    case cancel     // 取消，不上屏
}

/// 录音时手指所处的功能区域
enum VoiceDragZone {
    case none       // 中间正常区域，松开发送
    case cancel     // 左侧，松开取消
    case transcribe // 右侧，松开后转文字
}

/// 录音时的全屏微信式提示：中间绿色大泡泡 + 底部左右"取消"/"转文字"胶囊
struct VoiceRecordingOverlay: View {
    @Binding var zone: VoiceDragZone
    @State private var wavePhase: Double = 0

    private let bubbleColor = Color(hex: "#3AC26B")

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                bubbleView

                promptTextView
                    .padding(.top, 28)
                    .padding(.bottom, 46)

                bottomButtons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                wavePhase = 1
            }
        }
    }

    private var bubbleView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(fillColor)
                .frame(width: 130, height: 110)
                .shadow(color: fillColor.opacity(0.35), radius: 20, x: 0, y: 10)

            VStack(spacing: 6) {
                waveBars
                    .frame(height: 36)

                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }

            SpeechBubbleTail()
                .fill(fillColor)
                .frame(width: 24, height: 18)
                .rotationEffect(.degrees(180))
                .offset(y: 64)
        }
    }

    private var waveBars: some View {
        HStack(spacing: 4) {
            ForEach(0..<7) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 4, height: waveHeight(for: i))
                    .animation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true).delay(Double(i) * 0.04), value: wavePhase)
            }
        }
    }

    private var promptTextView: some View {
        Text(promptText)
            .font(.appBody().weight(.medium))
            .foregroundStyle(.white)
    }

    private var bottomButtons: some View {
        HStack(spacing: 0) {
            bottomCapsule(title: "取消", icon: "xmark", isActive: zone == .cancel, alignment: .leading)
            Spacer(minLength: 0)
            bottomCapsule(title: "滑到这里 转文字", icon: "text.bubble.fill", isActive: zone == .transcribe, alignment: .trailing)
        }
    }

    private var fillColor: Color {
        zone == .cancel ? Color.appError : bubbleColor
    }

    private var promptText: String {
        switch zone {
        case .cancel: return "松开手指，取消发送"
        case .transcribe: return "松开手指，转为文字"
        case .none: return "松开 发语音"
        }
    }

    private var iconName: String {
        switch zone {
        case .cancel: return "xmark"
        case .transcribe: return "text.bubble.fill"
        case .none: return "mic.fill"
        }
    }

    private func waveHeight(for index: Int) -> CGFloat {
        let base: CGFloat = 10
        let range: CGFloat = 14
        let angle = wavePhase * .pi * 2 + Double(index) * 0.6
        return base + range * CGFloat((sin(angle) + 1) / 2)
    }

    private func bottomCapsule(title: String, icon: String, isActive: Bool, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 8) {
            if alignment == .trailing { Spacer(minLength: 0) }
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .foregroundStyle(isActive ? .white : .white.opacity(0.7))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(isActive ? Color.white.opacity(0.22) : Color.white.opacity(0.12))
                .overlay(
                    Capsule()
                        .stroke(isActive ? Color.white.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
        .scaleEffect(isActive ? 1.08 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

/// 语音气泡小尾巴
private struct SpeechBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
