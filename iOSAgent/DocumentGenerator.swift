import Foundation
import UIKit

/// 轻量级本地文档生成器：支持文本文件与极简 .pptx。
enum DocumentGenerator {

    // MARK: - 文本文件

    static func generateTextFile(filename: String, content: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - PPTX

    static func generatePPTX(title: String, slides: [(title: String, bullets: [String])]) throws -> URL {
        guard !slides.isEmpty else {
            throw GeneratorError.noSlides
        }

        var zip = ZipArchiveWriter()

        // 1. [Content_Types].xml：追加 slide 覆盖
        var contentTypes = PPTXTemplate.p_Content_Types_xml
        var slideOverrides = ""
        for i in 1...slides.count {
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        contentTypes = contentTypes.replacingOccurrences(of: "</Types>", with: slideOverrides + "</Types>")
        zip.add(Data(contentTypes.utf8), name: "[Content_Types].xml")

        // 2. 包关系（去掉缩略图）
        zip.add(Data(PPTXTemplate.p__rels__rels.utf8), name: "_rels/.rels")

        // 3. 文档属性
        zip.add(Data(PPTXTemplate.p_docProps_core_xml.utf8), name: "docProps/core.xml")
        zip.add(Data(PPTXTemplate.p_docProps_app_xml.utf8), name: "docProps/app.xml")

        // 4. 静态 ppt 部件
        zip.add(Data(PPTXTemplate.p_ppt_presProps_xml.utf8), name: "ppt/presProps.xml")
        zip.add(Data(PPTXTemplate.p_ppt_viewProps_xml.utf8), name: "ppt/viewProps.xml")
        zip.add(Data(PPTXTemplate.p_ppt_theme_theme1_xml.utf8), name: "ppt/theme/theme1.xml")
        zip.add(Data(PPTXTemplate.p_ppt_tableStyles_xml.utf8), name: "ppt/tableStyles.xml")
        zip.add(Data(PPTXTemplate.p_ppt_slideMasters_slideMaster1_xml.utf8), name: "ppt/slideMasters/slideMaster1.xml")
        zip.add(Data(PPTXTemplate.p_ppt_slideMasters__rels_slideMaster1_xml_rels.utf8), name: "ppt/slideMasters/_rels/slideMaster1.xml.rels")

        for (i, layoutXML) in PPTXTemplate.slideLayoutXMLs.enumerated() {
            zip.add(Data(layoutXML.utf8), name: "ppt/slideLayouts/slideLayout\(i + 1).xml")
        }
        for (i, relsXML) in PPTXTemplate.slideLayoutRels.enumerated() {
            zip.add(Data(relsXML.utf8), name: "ppt/slideLayouts/_rels/slideLayout\(i + 1).xml.rels")
        }

        // 5. 动态幻灯片
        for (i, slide) in slides.enumerated() {
            let index = i + 1
            let slideXML = buildSlideXML(idBase: index * 10, title: slide.title, bullets: slide.bullets)
            zip.add(Data(slideXML.utf8), name: "ppt/slides/slide\(index).xml")
            let slideRels = """
            <?xml version='1.0' encoding='UTF-8' standalone='yes'?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout7.xml"/></Relationships>
            """
            zip.add(Data(slideRels.utf8), name: "ppt/slides/_rels/slide\(index).xml.rels")
        }

        // 6. presentation.xml：替换 sldIdLst
        var presentation = PPTXTemplate.p_ppt_presentation_xml
        let sldIdLst = slides.enumerated()
            .map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"rId\(5 + $0.offset + 1)\"/>" }
            .joined()
        presentation = presentation.replacingOccurrences(
            of: "<p:sldIdLst>.*?</p:sldIdLst>",
            with: "<p:sldIdLst>\(sldIdLst)</p:sldIdLst>",
            options: .regularExpression,
            range: nil
        )
        zip.add(Data(presentation.utf8), name: "ppt/presentation.xml")

        // 7. presentation.xml.rels：按顺序生成
        var rels = "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        rels += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        rels += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps\" Target=\"presProps.xml\"/>"
        rels += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps\" Target=\"viewProps.xml\"/>"
        rels += "<Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        rels += "<Relationship Id=\"rId5\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles\" Target=\"tableStyles.xml\"/>"
        for i in 1...slides.count {
            rels += "<Relationship Id=\"rId\(5 + i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        rels += "</Relationships>"
        zip.add(Data(rels.utf8), name: "ppt/_rels/presentation.xml.rels")

        // 8. 写出
        let safeName = title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(safeName).pptx")
        try zip.write(to: url)
        return url
    }

    // MARK: - Slide XML

    private static func buildSlideXML(idBase: Int, title: String, bullets: [String]) -> String {
        let titleShape = textShapeXML(
            id: idBase + 2, name: "Title",
            x: 457_200, y: 274_638, cx: 8_229_600, cy: 1_143_000,
            fontSize: 4_400, bold: true,
            paragraphs: [title]
        )
        let bodyShape = textShapeXML(
            id: idBase + 3, name: "Body",
            x: 457_200, y: 1_600_200, cx: 8_229_600, cy: 4_525_963,
            fontSize: 2_400, bold: false,
            paragraphs: bullets
        )
        return """
        <?xml version='1.0' encoding='UTF-8' standalone='yes'?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:cSld>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr/>
              \(titleShape)
              \(bodyShape)
            </p:spTree>
          </p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func textShapeXML(id: Int, name: String, x: Int, y: Int, cx: Int, cy: Int,
                                     fontSize: Int, bold: Bool, paragraphs: [String]) -> String {
        let boldAttr = bold ? " b=\"1\"" : ""
        let paraXML = paragraphs.map { text in
            let escaped = xmlEscape(text)
            return "<a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"\(fontSize)\"\(boldAttr)/><a:t>\(escaped)</a:t></a:r></a:p>"
        }.joined()
        return """
        <p:sp>
          <p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
          <p:txBody><a:bodyPr/><a:lstStyle/>\(paraXML)</p:txBody>
        </p:sp>
        """
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    enum GeneratorError: Error, LocalizedError {
        case noSlides
        var errorDescription: String? {
            switch self {
            case .noSlides: return "幻灯片不能为空"
            }
        }
    }
}

// MARK: - 极简 ZIP 写入器（仅存储，无压缩）

struct ZipArchiveWriter {
    private var entries: [(name: String, data: Data)] = []

    mutating func add(_ data: Data, name: String) {
        entries.append((name, data))
    }

    func write(to url: URL) throws {
        var local = Data()
        var central = Data()
        var offset: UInt32 = 0

        for (index, entry) in entries.enumerated() {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            let localHeader = buildLocalHeader(name: nameData, crc: crc, size: size)
            local.append(localHeader)
            local.append(entry.data)

            let cdHeader = buildCentralHeader(index: index, name: nameData, crc: crc, size: size, offset: offset)
            central.append(cdHeader)

            offset += UInt32(localHeader.count) + size
        }

        var output = Data()
        output.append(local)
        output.append(central)
        output.append(buildEOCD(count: UInt16(entries.count), size: UInt32(central.count), offset: offset))
        try output.write(to: url)
    }

    private func buildLocalHeader(name: Data, crc: UInt32, size: UInt32) -> Data {
        var d = Data()
        d.append(0x50, 0x4b, 0x03, 0x04)         // local file header signature
        d.appendLE(UInt16(20))                    // version needed
        d.appendLE(UInt16(0x0800))                // general purpose bit flag: UTF-8
        d.appendLE(UInt16(0))                     // compression method: stored
        d.appendLE(UInt16(0))                     // mod time
        d.appendLE(UInt16(0))                     // mod date
        d.appendLE(crc)
        d.appendLE(size)                          // compressed size
        d.appendLE(size)                          // uncompressed size
        d.appendLE(UInt16(name.count))
        d.appendLE(UInt16(0))                     // extra field length
        d.append(name)
        return d
    }

    private func buildCentralHeader(index: Int, name: Data, crc: UInt32, size: UInt32, offset: UInt32) -> Data {
        var d = Data()
        d.append(0x50, 0x4b, 0x01, 0x02)          // central directory signature
        d.appendLE(UInt16(0x031e))                // version made by (Unix + 3.0)
        d.appendLE(UInt16(20))                    // version needed
        d.appendLE(UInt16(0x0800))                // general purpose bit flag
        d.appendLE(UInt16(0))                     // compression method
        d.appendLE(UInt16(0))                     // mod time
        d.appendLE(UInt16(0))                     // mod date
        d.appendLE(crc)
        d.appendLE(size)
        d.appendLE(size)
        d.appendLE(UInt16(name.count))
        d.appendLE(UInt16(0))                     // extra length
        d.appendLE(UInt16(0))                     // comment length
        d.appendLE(UInt16(0))                     // disk number start
        d.appendLE(UInt16(0))                     // internal file attributes
        d.appendLE(UInt32(0))                     // external file attributes
        d.appendLE(offset)
        d.append(name)
        return d
    }

    private func buildEOCD(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var d = Data()
        d.append(0x50, 0x4b, 0x05, 0x06)          // EOCD signature
        d.appendLE(UInt16(0))                     // disk number
        d.appendLE(UInt16(0))                     // disk with CD
        d.appendLE(count)
        d.appendLE(count)
        d.appendLE(size)
        d.appendLE(offset)
        d.appendLE(UInt16(0))                     // comment length
        return d
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func append(_ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8) {
        append(contentsOf: [b1, b2, b3, b4])
    }

    mutating func appendLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}

// MARK: - CRC32

private func crc32(_ data: Data) -> UInt32 {
    let table = crc32Table
    var crc: UInt32 = 0xffffffff
    for byte in data {
        let idx = UInt8(crc & 0xff) ^ byte
        crc = (crc >> 8) ^ table[Int(idx)]
    }
    return crc ^ 0xffffffff
}

private let crc32Table: [UInt32] = {
    let polynomial: UInt32 = 0xedb88320
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
        }
        table[i] = c
    }
    return table
}()
