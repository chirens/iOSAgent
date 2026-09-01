import SwiftUI
import PDFKit
import UIKit

/// 用于 sheet(item:) 的 Identifiable 包装：本工具链的 URL 不遵循 Identifiable，
/// 直接以 URL? 作为 sheet 的 item 会触发编译错误。
struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 极简 zip 读取器：仅支持 stored（未压缩）条目。
/// 本应用生成的 .pptx 即采用 stored 方式，因此可可靠解析其幻灯片文本。
/// 对采用 deflate 压缩的第三方文档（如 .docx），将无法读取，预览页会安全回退到“用其他 App 打开”。
struct ZipStoreReader {
    static func readStoredEntries(data: Data) -> [String: Data] {
        var result: [String: Data] = [:]
        let bytes = [UInt8](data)
        var pos = 0
        while pos + 4 <= bytes.count {
            if bytes[pos] == 0x50 && bytes[pos + 1] == 0x4b && bytes[pos + 2] == 0x03 && bytes[pos + 3] == 0x04 {
                guard pos + 30 <= bytes.count else { break }
                let method = Int(bytes[pos + 8]) | (Int(bytes[pos + 9]) << 8)
                let compSize = Int(bytes[pos + 18]) | (Int(bytes[pos + 19]) << 8)
                              | (Int(bytes[pos + 20]) << 16) | (Int(bytes[pos + 21]) << 24)
                let nameLen = Int(bytes[pos + 26]) | (Int(bytes[pos + 27]) << 8)
                let extraLen = Int(bytes[pos + 28]) | (Int(bytes[pos + 29]) << 8)
                let nameStart = pos + 30
                guard nameStart + nameLen <= bytes.count else { break }
                let nameData = bytes[nameStart ..< nameStart + nameLen]
                guard let name = String(bytes: nameData, encoding: .utf8) else { break }
                let dataStart = nameStart + nameLen + extraLen
                guard dataStart + compSize <= bytes.count else { break }
                if method == 0 {
                    result[name] = Data(bytes[dataStart ..< dataStart + compSize])
                }
                let next = dataStart + compSize
                pos = next > pos ? next : pos + 1
                continue
            } else {
                pos += 1
            }
        }
        return result
    }
}

struct PPTSlide {
    let title: String
    let bullets: [String]
}

struct FilePreviewView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var pptSlides: [PPTSlide] = []
    @State private var plainText: String = ""
    @State private var docxText: String = ""
    @State private var loadState: LoadState = .loading

    private enum LoadState { case loading, ready, unsupported }

    private var ext: String { url.pathExtension.lowercased() }

    private let imageExts = ["png", "jpg", "jpeg", "heic", "gif", "webp", "bmp", "tiff"]
    private let textExts = ["txt", "md", "markdown", "csv", "json", "html", "htm", "rtf", "log", "xml", "yaml", "yml"]

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .loading:
                    ProgressView("加载中…")
                case .ready:
                    readyContent
                case .unsupported:
                    unsupportedContent
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear { load() }
    }

    // MARK: - 内容分支

    @ViewBuilder
    private var readyContent: some View {
        if imageExts.contains(ext), let img = UIImage(contentsOfFile: url.path) {
            ScrollView {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
            .background(Color.appBackground)
        } else if ext == "pdf" {
            PDFKitPreview(url: url)
        } else if ext == "pptx" {
            pptContent
        } else if textExts.contains(ext) {
            ScrollView {
                Text(plainText.isEmpty ? "(空文件)" : plainText)
                    .font(.appBody().monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.appBackground)
        } else if ext == "docx", !docxText.isEmpty {
            ScrollView {
                Text(docxText)
                    .font(.appBody())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.appBackground)
        } else {
            unsupportedContent
        }
    }

    private var pptContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(pptSlides.enumerated()), id: \.offset) { idx, slide in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(idx + 1). \(slide.title)")
                            .font(.appTitle3().weight(.bold))
                            .foregroundStyle(.brandAccent)
                        if slide.bullets.isEmpty {
                            Text("（无要点）")
                                .font(.appSubheadline())
                                .foregroundStyle(.appSecondaryText)
                        } else {
                            ForEach(slide.bullets, id: \.self) { b in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•")
                                    Text(b)
                                        .font(.appSubheadline())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding()
        }
        .background(Color.appBackground)
    }

    private var unsupportedContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.fill")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .foregroundStyle(.appSecondaryText)
            Text("该格式暂不支持应用内预览")
                .font(.appTitle3().weight(.bold))
            Text("点击下方按钮用其他 App 打开")
                .font(.appSubheadline())
                .foregroundStyle(.appSecondaryText)
            ShareLink(item: url) {
                Label("用其他 App 打开", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.brandAccent)
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.appBackground)
    }

    // MARK: - 加载

    private func load() {
        if ext == "pptx" {
            let slides = Self.parsePPTX(url: url)
            if slides.isEmpty {
                loadState = .unsupported
            } else {
                pptSlides = slides
                loadState = .ready
            }
            return
        }
        if textExts.contains(ext) {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                plainText = s
                loadState = .ready
            } else if let s = try? String(contentsOf: url, encoding: .ascii) {
                plainText = s
                loadState = .ready
            } else {
                loadState = .unsupported
            }
            return
        }
        if ext == "docx" {
            if let s = Self.parseDocx(url: url), !s.isEmpty {
                docxText = s
                loadState = .ready
                return
            }
            loadState = .unsupported
            return
        }
        // 图片 / pdf / 其他：交给 readyContent 分支判定
        loadState = .ready
    }

    // MARK: - PPTX 解析

    static func parsePPTX(url: URL) -> [PPTSlide] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let entries = ZipStoreReader.readStoredEntries(data: data)
        let slideEntries = entries.keys
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideIndex($0) < slideIndex($1) }
        return slideEntries.compactMap { name in
            guard let xmlData = entries[name], let xml = String(data: xmlData, encoding: .utf8) else { return nil }
            let texts = extractTag(xml: xml, open: "<a:t>", close: "</a:t>")
            guard !texts.isEmpty else { return nil }
            return PPTSlide(title: texts[0], bullets: Array(texts.dropFirst()))
        }
    }

    static func parseDocx(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let entries = ZipStoreReader.readStoredEntries(data: data)
        guard let xmlData = entries["word/document.xml"], let xml = String(data: xmlData, encoding: .utf8) else { return nil }
        return extractTag(xml: xml, open: "<w:t", close: "</w:t>").joined(separator: "\n")
    }

    private static func slideIndex(_ name: String) -> Int {
        let parts = name.components(separatedBy: "slide")
        guard let last = parts.last else { return 0 }
        var digits = ""
        for c in last where c.isNumber { digits.append(c) }
        return Int(digits) ?? 0
    }

    private static func extractTag(xml: String, open: String, close: String) -> [String] {
        var result: [String] = []
        var searchStart = xml.startIndex
        while let openRange = xml.range(of: open, range: searchStart..<xml.endIndex) {
            // open 标签可能带属性，如 <w:t xml:space="preserve">，需找到 '>'
            let afterTag = xml[openRange.upperBound...]
            guard let gt = afterTag.firstIndex(of: ">") else { break }
            let textStart = xml.index(after: gt)
            guard let closeRange = xml.range(of: close, range: textStart..<xml.endIndex) else { break }
            let raw = String(xml[textStart..<closeRange.lowerBound])
            result.append(xmlUnescape(raw))
            searchStart = closeRange.upperBound
        }
        return result
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// PDFKit 预览封装
struct PDFKitPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
