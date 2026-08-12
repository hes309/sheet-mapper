import Foundation
import ZIPFoundation

final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var values: [String] = []
    private var insideItem = false
    private var insideText = false
    private var current = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "si" { insideItem = true; current = "" }
        if name == "t" && insideItem { insideText = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if insideText { current += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "t" { insideText = false }
        if name == "si" { values.append(current); insideItem = false }
    }
}

final class WorksheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private let maxRows: Int
    private let maxColumns: Int
    private(set) var cells: [String: String] = [:]
    private(set) var merges: [String] = []
    private var address = ""
    private var type = ""
    private var content = ""
    private var readingValue = false
    private let stopAfterRow: Int?
    private(set) var stoppedAtPreviewLimit = false
    init(shared: [String], maxRows: Int, maxColumns: Int, stopAfterRow: Int? = nil) {
        self.shared = shared
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.stopAfterRow = stopAfterRow
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String : String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "row", let stopAfterRow, let row = Int(a["r"] ?? ""), row > stopAfterRow {
            stoppedAtPreviewLimit = true
            parser.abortParsing()
            return
        }
        if name == "c" { address = a["r"] ?? ""; type = a["t"] ?? ""; content = "" }
        if name == "v" || name == "t" { readingValue = true }
        if name == "mergeCell", let ref = a["ref"] { merges.append(ref) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingValue { content += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "v" || name == "t" { readingValue = false }
        if name == "c", !address.isEmpty {
            let value: String
            if type == "s", let index = Int(content), shared.indices.contains(index) { value = shared[index] }
            else { value = content }
            // 仅保存有效值；空白样式单元格由最终使用范围按需补齐，避免产生海量空字符串。
            if !value.isEmpty, let point = XLSXReader.cellPoint(address), point.row < maxRows, point.column < maxColumns {
                cells[address] = value
            }
        }
    }
}

enum XLSXReader {
    static func index(_ url: URL) throws -> WorkbookIndex {
        let workbook = try String(data: entryData(url, path: "xl/workbook.xml"), encoding: .utf8).unwrap(L10n.text("error.workbookCorrupt"))
        let relationships = try String(data: entryData(url, path: "xl/_rels/workbook.xml.rels"), encoding: .utf8).unwrap(L10n.text("error.relationshipsCorrupt"))
        let relMap = relationshipMap(relationships)
        let sheets = workbookSheets(workbook).compactMap { entry -> SheetIndex? in
            guard let target = relMap[entry.rid] else { return nil }
            return SheetIndex(name: entry.name, path: normalizedPart(target))
        }
        let shared = (try? entryData(url, path: "xl/sharedStrings.xml")).map(parseSharedStrings) ?? []
        return WorkbookIndex(url: url, sheets: sheets, sharedStrings: shared)
    }

    static func preview(_ index: WorkbookIndex, sheet: SheetIndex, maxRows: Int = 50, maxColumns: Int = 200) throws -> SheetPreview {
        try readSheet(index: index, sheet: sheet, maxRows: maxRows, maxColumns: maxColumns, stopAfterRow: maxRows)
    }

    static func fullSheet(_ index: WorkbookIndex, sheet: SheetIndex, maxRows: Int = 10_000, maxColumns: Int = 200) throws -> FullSheetData {
        FullSheetData(sheet: try readSheet(index: index, sheet: sheet, maxRows: maxRows, maxColumns: maxColumns, stopAfterRow: nil))
    }

    private static func readSheet(index: WorkbookIndex, sheet: SheetIndex, maxRows: Int, maxColumns: Int, stopAfterRow: Int?) throws -> SheetPreview {
        let data = try entryData(index.url, path: sheet.path)
        let parser = WorksheetParser(shared: index.sharedStrings, maxRows: maxRows, maxColumns: maxColumns, stopAfterRow: stopAfterRow)
        let xml = XMLParser(data: data); xml.delegate = parser; _ = xml.parse()
        return makePreview(name: sheet.name, path: sheet.path, parser: parser, maxRows: maxRows, maxColumns: maxColumns)
    }

    static func preview(_ url: URL, maxRows: Int = 80, maxColumns: Int = 80) throws -> WorkbookPreview {
        let folder = try ProcessRunner.temporaryDirectory(prefix: "xlsx-read")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProcessRunner.unzip(url, to: folder)
        let shared = parseSharedStrings(folder.appendingPathComponent("xl/sharedStrings.xml"))
        let workbook = try String(contentsOf: folder.appendingPathComponent("xl/workbook.xml"), encoding: .utf8)
        let relationships = try String(contentsOf: folder.appendingPathComponent("xl/_rels/workbook.xml.rels"), encoding: .utf8)
        let relMap = relationshipMap(relationships)
        let sheets = workbookSheets(workbook).compactMap { entry -> SheetPreview? in
            guard let target = relMap[entry.rid] else { return nil }
            let part = normalizedPart(target)
            let sheetURL = folder.appendingPathComponent(part)
            guard let data = try? Data(contentsOf: sheetURL) else { return nil }
            let parser = WorksheetParser(shared: shared, maxRows: maxRows, maxColumns: maxColumns)
            let xml = XMLParser(data: data); xml.delegate = parser; xml.parse()
            return makePreview(name: entry.name, path: part, parser: parser, maxRows: maxRows, maxColumns: maxColumns)
        }
        return WorkbookPreview(url: url, sheets: sheets)
    }

    static func parseSharedStrings(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parseSharedStrings(data)
    }

    static func parseSharedStrings(_ data: Data) -> [String] {
        let delegate = SharedStringsParser(); let parser = XMLParser(data: data); parser.delegate = delegate; parser.parse()
        return delegate.values
    }

    private static func makePreview(name: String, path: String, parser: WorksheetParser, maxRows: Int, maxColumns: Int) -> SheetPreview {
        var lastRow = -1, lastColumn = -1
        for address in parser.cells.keys { if let point = cellPoint(address) { lastRow = max(lastRow, point.row); lastColumn = max(lastColumn, point.column) } }
        for merge in parser.merges { for address in merge.split(separator: ":") { if let point = cellPoint(String(address)), point.row < maxRows, point.column < maxColumns { lastRow = max(lastRow, point.row); lastColumn = max(lastColumn, point.column) } } }
        let rowCount = min(maxRows, max(1, lastRow + 1)), columnCount = min(maxColumns, max(1, lastColumn + 1))
        var rows = Array(repeating: Array(repeating: "", count: columnCount), count: rowCount)
        for (address, value) in parser.cells { if let point = cellPoint(address), point.row < rowCount, point.column < columnCount { rows[point.row][point.column] = value } }
        return SheetPreview(name: name, path: path, rows: rows, merges: parser.merges)
    }

    private static func entryData(_ url: URL, path: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else { throw MapperError.message(L10n.format("error.workbookPartMissing", path)) }
        var data = Data(); data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    static func relationshipMap(_ xml: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: tags("Relationship", xml).compactMap { tag in
            guard let id = attribute("Id", tag), let target = attribute("Target", tag) else { return nil }
            return (id, target)
        })
    }

    static func workbookSheets(_ xml: String) -> [(name: String, sheetID: Int, rid: String)] {
        tags("sheet", xml).compactMap { tag in
            guard let name = attribute("name", tag), let idText = attribute("sheetId", tag), let id = Int(idText), let rid = attribute("r:id", tag) else { return nil }
            return (xmlUnescape(name), id, rid)
        }
    }

    static func tags(_ name: String, _ xml: String) -> [String] { matches(#"<(?:(?:\w+):)?\#(name)\b[^>]*>"#, xml).compactMap(\.first) }
    static func attribute(_ name: String, _ tag: String) -> String? { matches(#"\b\#(NSRegularExpression.escapedPattern(for: name))="([^"]*)""#, tag).first.flatMap { $0.count > 1 ? $0[1] : nil } }

    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let r = match.range(at: index)
                guard r.location != NSNotFound, let swift = Range(r, in: text) else { return "" }
                return String(text[swift])
            }
        }
    }

    static func normalizedPart(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        if target.hasPrefix("xl/") { return target }
        return "xl/" + target.replacingOccurrences(of: "./", with: "")
    }

    static func cellPoint(_ address: String) -> (column: Int, row: Int)? {
        let letters = address.prefix { $0.isLetter }
        let digits = address.dropFirst(letters.count)
        guard !letters.isEmpty, let row = Int(digits), row > 0 else { return nil }
        var column = 0
        for scalar in letters.uppercased().unicodeScalars { column = column * 26 + Int(scalar.value - 64) }
        return (column - 1, row - 1)
    }

    static func xmlUnescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private extension Optional where Wrapped == String {
    func unwrap(_ message: String) throws -> String { guard let self else { throw MapperError.message(message) }; return self }
}
