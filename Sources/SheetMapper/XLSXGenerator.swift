import Foundation

enum XLSXGenerator {
    struct Record { let values: [String]; let sourceRow: Int; let key: String }

    static func generate(source: WorkbookPreview, sourceSheet: SheetPreview, template: WorkbookPreview, templateSheet: SheetPreview,
                         headerRow: Int, dataStartRow: Int, mappings: [FieldMapping], keyField: String,
                         sheetsPerWorkbook: Int, outputMode: OutputMode = .combined, destination: URL,
                         progress: ((GenerationStage, Int, Int) -> Void)? = nil,
                         isCancelled: (() -> Bool)? = nil) throws -> GenerationSummary {
        func checkCancellation() throws { if isCancelled?() == true { throw CancellationError() } }
        guard !mappings.isEmpty else { throw MapperError.message(L10n.text("error.mappingRequired")) }
        guard sourceSheet.rows.indices.contains(headerRow - 1) else { throw MapperError.message(L10n.text("error.headerOutOfRange")) }
        let headers = sourceSheet.rows[headerRow - 1].map(clean)
        var headerMap: [String: Int] = [:]
        for (index, header) in headers.enumerated() where !header.isEmpty && headerMap[header] == nil { headerMap[header] = index }
        guard let keyIndex = headerMap[clean(keyField)] else { throw MapperError.message(L10n.format("error.keyFieldMissing", keyField)) }
        for mapping in mappings where !mapping.source.hasPrefix("__") {
            guard headerMap[clean(mapping.source)] != nil else { throw MapperError.message(L10n.format("error.sourceFieldMissing", mapping.source)) }
            guard !targets(mapping.target).isEmpty, targets(mapping.target).allSatisfy({ XLSXReader.cellPoint($0) != nil }) else { throw MapperError.message(L10n.format("error.targetInvalid", mapping.target)) }
        }
        var records: [Record] = []
        var errorRows: [[String]] = []
        progress?(.validating, 0, max(0, sourceSheet.rows.count - max(dataStartRow - 1, 0)))
        for index in max(dataStartRow - 1, 0)..<sourceSheet.rows.count {
            try checkCancellation()
            let row = sourceSheet.rows[index]
            let validated = index - max(dataStartRow - 1, 0) + 1
            let validationTotal = max(0, sourceSheet.rows.count - max(dataStartRow - 1, 0))
            if validated == validationTotal || validated.isMultiple(of: 100) { progress?(.validating, validated, validationTotal) }
            let hasMappedData = mappings.contains { mapping in
                guard let col = headerMap[clean(mapping.source)], row.indices.contains(col) else { return false }
                return !clean(row[col]).isEmpty
            }
            if !hasMappedData { continue }
            let key = row.indices.contains(keyIndex) ? clean(row[keyIndex]) : ""
            var reasons: [String] = []
            if key.isEmpty || key == "0" { reasons.append("主键字段为空") }
            for mapping in mappings where mapping.required {
                if let col = headerMap[clean(mapping.source)], (!row.indices.contains(col) || clean(row[col]).isEmpty) { reasons.append("必填字段“\(mapping.source)”为空") }
            }
            if reasons.isEmpty { records.append(Record(values: row, sourceRow: index + 1, key: key)) }
            else { errorRows.append([String(index + 1), key, reasons.joined(separator: "；")]) }
        }
        guard !records.isEmpty else { throw MapperError.message(L10n.text("error.noRecords")) }
        let workspace = try ProcessRunner.temporaryDirectory(prefix: "swift-result")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let batchSize = min(200, max(1, sheetsPerWorkbook))
        var outputFiles: [URL] = []
        let expectedOutputs = outputMode == .combined ? Int(ceil(Double(records.count) / Double(batchSize))) : records.count
        progress?(.generating, 0, expectedOutputs)
        if outputMode == .combined {
            for offset in stride(from: 0, to: records.count, by: batchSize) {
                try checkCancellation()
                let end = min(offset + batchSize, records.count)
                let file = workspace.appendingPathComponent(String(format: "通用映射_第%03d批_第%d-%d条.xlsx", offset / batchSize + 1, offset + 1, end))
                try buildBatch(records: Array(records[offset..<end]), startNumber: offset + 1, template: template.url,
                               templateSheet: templateSheet, mappings: mappings, headerMap: headerMap, output: file)
                outputFiles.append(file)
                progress?(.generating, outputFiles.count, expectedOutputs)
            }
        } else {
            for (index, record) in records.enumerated() {
                try checkCancellation()
                let batch = index / batchSize + 1
                let folder = workspace.appendingPathComponent(String(format: "第%03d批", batch), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(String(format: "%04d_%@.xlsx", index + 1, safeFilePart(record.key)))
                try buildBatch(records: [record], startNumber: index + 1, template: template.url,
                               templateSheet: templateSheet, mappings: mappings, headerMap: headerMap, output: file)
                outputFiles.append(file)
                progress?(.generating, outputFiles.count, expectedOutputs)
            }
        }
        try checkCancellation()
        progress?(.writing, 0, 1)
        try writeCSV([["来源行", "主键", "异常原因"]] + errorRows, to: workspace.appendingPathComponent("数据校验异常.csv"))
        let configData = try JSONEncoder.pretty.encode(mappings)
        try configData.write(to: workspace.appendingPathComponent("映射配置.json"))
        let stagedArchive = FileManager.default.temporaryDirectory.appendingPathComponent("mapping-result-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: stagedArchive) }
        try ProcessRunner.zipContents(of: workspace, to: stagedArchive)
        try checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagedArchive) }
        else { try FileManager.default.moveItem(at: stagedArchive, to: destination) }
        progress?(.writing, 1, 1)
        let batches = outputMode == .combined ? outputFiles.count : Int(ceil(Double(records.count) / Double(batchSize)))
        return GenerationSummary(total: records.count + errorRows.count, success: records.count, errors: errorRows.count, batches: batches, output: destination)
    }

    private static func buildBatch(records: [Record], startNumber: Int, template: URL, templateSheet: SheetPreview,
                                   mappings: [FieldMapping], headerMap: [String: Int], output: URL) throws {
        let folder = try ProcessRunner.temporaryDirectory(prefix: "swift-batch")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ProcessRunner.unzip(template, to: folder)
        let templateURL = folder.appendingPathComponent(templateSheet.path)
        let templateXML = try String(contentsOf: templateURL, encoding: .utf8)
        let workbookURL = folder.appendingPathComponent("xl/workbook.xml")
        let relsURL = folder.appendingPathComponent("xl/_rels/workbook.xml.rels")
        let typesURL = folder.appendingPathComponent("[Content_Types].xml")
        var workbook = try String(contentsOf: workbookURL, encoding: .utf8)
        var rels = try String(contentsOf: relsURL, encoding: .utf8)
        var types = try String(contentsOf: typesURL, encoding: .utf8)
        let originalSheets = XLSXReader.workbookSheets(workbook)
        let originalRels = XLSXReader.relationshipMap(rels)
        guard let selected = originalSheets.first(where: { $0.name == templateSheet.name }) else { throw MapperError.message(L10n.text("error.templateSheetMissing")) }
        let selectedRID = selected.rid
        let existingSheetIDs = originalSheets.map(\.sheetID)
        let relationIDs = XLSXReader.matches(#"Id="rId(\d+)""#, rels).compactMap { Int($0[1]) }
        var nextSheetID = (existingSheetIDs.max() ?? 0) + 1
        var nextRID = (relationIDs.max() ?? 0) + 1
        let worksheetFolder = folder.appendingPathComponent("xl/worksheets")
        let worksheetRelsFolder = worksheetFolder.appendingPathComponent("_rels")
        let templateRelsURL = worksheetRelsFolder.appendingPathComponent(templateURL.lastPathComponent + ".rels")
        let hasTemplateRelationships = FileManager.default.fileExists(atPath: templateRelsURL.path)
        let existingParts = (try? FileManager.default.contentsOfDirectory(at: worksheetFolder, includingPropertiesForKeys: nil)) ?? []
        var nextPartNumber = existingParts.compactMap { Int($0.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "sheet", with: "")) }.max() ?? 0
        var created: [(name: String, part: String, rid: String, sheetID: Int, record: Record, seq: Int)] = []
        for (index, record) in records.enumerated() {
            var xml = templateXML
            for mapping in mappings {
                let raw: String
                if mapping.source == "__rowNumber" { raw = String(record.sourceRow) }
                else if let column = headerMap[clean(mapping.source)], record.values.indices.contains(column) { raw = record.values[column] }
                else { raw = "" }
                let converted = transform(raw, mapping.transform)
                for target in targets(mapping.target) { xml = setCell(xml, address: target, value: converted.value, numeric: converted.numeric) }
            }
            nextPartNumber += 1
            let part = "xl/worksheets/sheet\(nextPartNumber).xml"
            try xml.write(to: folder.appendingPathComponent(part), atomically: true, encoding: .utf8)
            if hasTemplateRelationships {
                try FileManager.default.createDirectory(at: worksheetRelsFolder, withIntermediateDirectories: true)
                let destination = worksheetRelsFolder.appendingPathComponent("sheet\(nextPartNumber).xml.rels")
                try FileManager.default.copyItem(at: templateRelsURL, to: destination)
            }
            let seq = startNumber + index
            let name = safeSheetName(String(format: "%03d_%@", seq, record.key))
            created.append((name, part, "rId\(nextRID)", nextSheetID, record, seq))
            nextRID += 1; nextSheetID += 1
        }
        nextPartNumber += 1
        let directoryPart = "xl/worksheets/sheet\(nextPartNumber).xml"
        let directoryRows = [["序号", "来源行", "主键", "Sheet名称"]] + created.map { [String($0.seq), String($0.record.sourceRow), $0.record.key, $0.name] }
        try directoryXML(directoryRows).write(to: folder.appendingPathComponent(directoryPart), atomically: true, encoding: .utf8)
        let directoryRID = "rId\(nextRID)"
        let newSheets = created.map { #"<sheet name="\#(xmlEscape($0.name))" sheetId="\#($0.sheetID)" r:id="\#($0.rid)"/>"# }.joined()
            + #"<sheet name="生成目录" sheetId="\#(nextSheetID)" r:id="\#(directoryRID)"/>"#
        workbook = replaceFirst(workbook, pattern: #"<(?:(?:\w+):)?sheets\b[^>]*>[\s\S]*?</(?:(?:\w+):)?sheets>"#, with: "<sheets>\(newSheets)</sheets>")
        for relation in originalRels where relation.value.lowercased().contains("worksheet") == false { _ = relation }
        rels = replacing(rels, pattern: #"<Relationship\b[^>]*Type="[^"]*/worksheet"[^>]*/>"#, with: "")
        let newRelationships = created.map { #"<Relationship Id="\#($0.rid)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/\#($0.part)"/>"# }.joined()
            + #"<Relationship Id="\#(directoryRID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/\#(directoryPart)"/>"#
        rels = rels.replacingOccurrences(of: "</Relationships>", with: newRelationships + "</Relationships>")
        types = replacing(types, pattern: #"<Override\b[^>]*PartName="/xl/worksheets/[^"]+"[^>]*/>"#, with: "")
        let overrides = (created.map(\.part) + [directoryPart]).map { #"<Override PartName="/\#($0)" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined()
        types = types.replacingOccurrences(of: "</Types>", with: overrides + "</Types>")
        try workbook.write(to: workbookURL, atomically: true, encoding: .utf8)
        try rels.write(to: relsURL, atomically: true, encoding: .utf8)
        try types.write(to: typesURL, atomically: true, encoding: .utf8)
        if let files = try? FileManager.default.contentsOfDirectory(at: worksheetFolder, includingPropertiesForKeys: nil) {
            let keep = Set(created.map { URL(fileURLWithPath: $0.part).lastPathComponent } + [URL(fileURLWithPath: directoryPart).lastPathComponent])
            for file in files where !keep.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        if let relationshipFiles = try? FileManager.default.contentsOfDirectory(at: worksheetRelsFolder, includingPropertiesForKeys: nil) {
            let keep = Set(created.map { URL(fileURLWithPath: $0.part).lastPathComponent + ".rels" })
            for file in relationshipFiles where !keep.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
        try ProcessRunner.zipContents(of: folder, to: output)
        _ = selectedRID
    }

    private static func setCell(_ xml: String, address: String, value: String, numeric: Bool) -> String {
        let ref = address.uppercased()
        let escaped = xmlEscape(value)
        let replacementBody = numeric ? "<v>\(escaped)</v>" : #"<is><t>\#(escaped)</t></is>"#
        let typeAttribute = numeric ? "" : #" t="inlineStr""#
        let pattern = #"(<(?:(?:\w+):)?c\b[^>]*\br="\#(NSRegularExpression.escapedPattern(for: ref))"[^>]*)(?:/>|>[\s\S]*?</(?:(?:\w+):)?c>)"#
        if let match = XLSXReader.matches(pattern, xml).first, match.count > 1 {
            var attrs = match[1]
            attrs = replacing(attrs, pattern: #"\s+t="[^"]*""#, with: "")
            if attrs.hasSuffix("/") { attrs.removeLast() }
            return replaceFirst(xml, pattern: pattern, with: attrs + typeAttribute + ">" + replacementBody + "</c>")
        }
        guard let row = XLSXReader.cellPoint(ref)?.row else { return xml }
        let rowNumber = row + 1
        let rowPattern = #"(<(?:(?:\w+):)?row\b[^>]*\br="\#(rowNumber)"[^>]*>)"#
        let cell = "<c r=\"\(ref)\"\(typeAttribute)>\(replacementBody)</c>"
        return replaceFirst(xml, pattern: rowPattern, with: "$1" + cell)
    }

    private static func transform(_ raw: String, _ transform: ValueTransform) -> (value: String, numeric: Bool) {
        switch transform {
        case .upper: return (raw.uppercased(), false)
        case .lower: return (raw.lowercased(), false)
        case .number: return Double(raw).map { (String($0), true) } ?? (raw, false)
        case .chineseDate:
            let formats = ["yyyy-MM-dd", "yyyy/MM/dd"]
            for format in formats { let f = DateFormatter(); f.dateFormat = format; if let date = f.date(from: raw) { f.dateFormat = "yyyy年MM月dd日"; return (f.string(from: date), false) } }
            return (raw, false)
        default: return (raw, false)
        }
    }

    private static func clean(_ value: String) -> String { value.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func targets(_ value: String) -> [String] { value.components(separatedBy: CharacterSet(charactersIn: "，,;； \t\r\n")).map { $0.uppercased() }.filter { !$0.isEmpty } }
    private static func safeSheetName(_ value: String) -> String { String(value.replacingOccurrences(of: #"[\\/:*?"<>|\[\]]"#, with: "_", options: .regularExpression).prefix(31)) }
    private static func safeFilePart(_ value: String) -> String { String(value.replacingOccurrences(of: #"[\\/:*?"<>|\[\]]"#, with: "_", options: .regularExpression).prefix(60)) }
    private static func xmlEscape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;") }
    private static func replacing(_ text: String, pattern: String, with value: String) -> String { (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: value) ?? text }
    private static func replaceFirst(_ text: String, pattern: String, with value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return text }
        return regex.stringByReplacingMatches(in: text, range: match.range, withTemplate: value)
    }
    private static func directoryXML(_ rows: [[String]]) -> String {
        let body = rows.enumerated().map { r, row in "<row r=\"\(r + 1)\">" + row.enumerated().map { c, value in "<c r=\"\(excelColumn(c))\(r + 1)\" t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>" }.joined() + "</row>" }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"# + body + "</sheetData></worksheet>"
    }
    private static func writeCSV(_ rows: [[String]], to url: URL) throws {
        let text = "\u{FEFF}" + rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}
