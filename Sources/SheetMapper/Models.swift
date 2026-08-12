import Foundation

struct SheetPreview: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let rows: [[String]]
    let merges: [String]
}

struct WorkbookPreview {
    let url: URL
    let sheets: [SheetPreview]
}

struct SheetIndex: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
}

struct WorkbookIndex {
    let url: URL
    let sheets: [SheetIndex]
    let sharedStrings: [String]
}

struct FullSheetData {
    let sheet: SheetPreview
}

enum GenerationStage: String {
    case idle = ""
    case reading = "正在读取完整数据"
    case validating = "正在校验有效数据"
    case generating = "正在生成批次"
    case writing = "正在写入结果"

    var localizedName: String {
        switch self {
        case .idle: return ""
        case .reading: return L10n.text("stage.reading")
        case .validating: return L10n.text("stage.validating")
        case .generating: return L10n.text("stage.generating")
        case .writing: return L10n.text("stage.writing")
        }
    }
}

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum ValueTransform: String, Codable, CaseIterable, Identifiable {
    case text = "文本"
    case raw = "原值"
    case number = "数字"
    case chineseDate = "中文日期"
    case upper = "大写"
    case lower = "小写"
    var id: String { rawValue }
    var localizedName: String { L10n.text("transform.\(String(describing: self))") }
}

struct FieldMapping: Identifiable, Codable, Hashable {
    var id = UUID()
    var source: String
    var target: String
    var transform: ValueTransform = .text
    var required = false
}

struct MappingMemory: Identifiable, Codable {
    var id = UUID()
    var name: String
    var sourceFields: [String]
    var templateLabels: [String]
    var mappings: [FieldMapping]
    var sheetsPerWorkbook: Int
    var outputMode: OutputMode = .combined

    enum CodingKeys: String, CodingKey {
        case id, name, sourceFields, templateLabels, mappings, sheetsPerWorkbook, outputMode
    }

    init(id: UUID = UUID(), name: String, sourceFields: [String], templateLabels: [String], mappings: [FieldMapping], sheetsPerWorkbook: Int, outputMode: OutputMode = .combined) {
        self.id = id
        self.name = name
        self.sourceFields = sourceFields
        self.templateLabels = templateLabels
        self.mappings = mappings
        self.sheetsPerWorkbook = sheetsPerWorkbook
        self.outputMode = outputMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        sourceFields = try values.decode([String].self, forKey: .sourceFields)
        templateLabels = try values.decode([String].self, forKey: .templateLabels)
        mappings = try values.decode([FieldMapping].self, forKey: .mappings)
        sheetsPerWorkbook = try values.decodeIfPresent(Int.self, forKey: .sheetsPerWorkbook) ?? 20
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .combined
    }
}

enum OutputMode: String, Codable, CaseIterable, Identifiable {
    case combined = "一个工作簿包含多个Sheet"
    case separate = "每行一个Excel文件"
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .combined: return L10n.text("output.combined")
        case .separate: return L10n.text("output.separate")
        }
    }
}

struct MappingConfiguration: Codable {
    var configurationVersion: Int = 2
    var applicationVersion: String = "2.0.0"
    var headerRow: Int
    var dataStartRow: Int
    var keyField: String
    var sheetsPerWorkbook: Int
    var outputMode: OutputMode
    var mappings: [FieldMapping]

    enum CodingKeys: String, CodingKey {
        case configurationVersion, applicationVersion, headerRow, dataStartRow, keyField, sheetsPerWorkbook, outputMode, mappings
    }

    init(configurationVersion: Int = 2, applicationVersion: String = "2.0.0", headerRow: Int, dataStartRow: Int, keyField: String, sheetsPerWorkbook: Int, outputMode: OutputMode, mappings: [FieldMapping]) {
        self.configurationVersion = configurationVersion
        self.applicationVersion = applicationVersion
        self.headerRow = headerRow
        self.dataStartRow = dataStartRow
        self.keyField = keyField
        self.sheetsPerWorkbook = sheetsPerWorkbook
        self.outputMode = outputMode
        self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configurationVersion = try values.decodeIfPresent(Int.self, forKey: .configurationVersion) ?? 1
        applicationVersion = try values.decodeIfPresent(String.self, forKey: .applicationVersion) ?? "1.x"
        headerRow = try values.decode(Int.self, forKey: .headerRow)
        dataStartRow = try values.decode(Int.self, forKey: .dataStartRow)
        keyField = try values.decode(String.self, forKey: .keyField)
        sheetsPerWorkbook = try values.decodeIfPresent(Int.self, forKey: .sheetsPerWorkbook) ?? 20
        outputMode = try values.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .combined
        mappings = try values.decode([FieldMapping].self, forKey: .mappings)
    }
}

struct GenerationSummary {
    let total: Int
    let success: Int
    let errors: Int
    let batches: Int
    let output: URL
}

enum MapperError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

func normalized(_ value: String) -> String {
    value.replacingOccurrences(of: "\u{200B}", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "（", with: "(")
        .replacingOccurrences(of: "）", with: ")")
}

func excelColumn(_ index: Int) -> String {
    var number = index + 1
    var result = ""
    while number > 0 {
        number -= 1
        result = String(UnicodeScalar(65 + number % 26)!) + result
        number /= 26
    }
    return result
}

func previewDisplayValue(_ value: String, address: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.caseInsensitiveCompare(address) == .orderedSame ? "" : value
}

enum MappingMatcher {
    static func templateLabels(_ sheet: SheetPreview) -> [String] {
        var result: [String] = []
        for (rowIndex, row) in sheet.rows.prefix(60).enumerated() {
            for (columnIndex, value) in row.prefix(40).enumerated() where !value.isEmpty && Double(value) == nil {
                result.append("\(excelColumn(columnIndex))\(rowIndex + 1):\(normalized(value))")
            }
        }
        return Array(Set(result))
    }

    static func bestSource(_ memory: MappingMemory, in workbook: WorkbookPreview?) -> (sheet: SheetPreview, row: Int, score: Double)? {
        var best: (SheetPreview, Int, Double)?
        let expected = memory.sourceFields.filter { !$0.isEmpty }
        for sheet in workbook?.sheets ?? [] {
            for (index, row) in sheet.rows.prefix(12).enumerated() {
                let values = Set(row.map(normalized).filter { !$0.isEmpty })
                let score = expected.isEmpty ? 0 : Double(expected.filter(values.contains).count) / Double(expected.count)
                if best == nil || score > best!.2 { best = (sheet, index + 1, score) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    static func bestTemplate(_ memory: MappingMemory, in workbook: WorkbookPreview?) -> (sheet: SheetPreview, score: Double)? {
        var best: (SheetPreview, Double)?
        for sheet in workbook?.sheets ?? [] {
            let labels = Set(templateLabels(sheet))
            let score = memory.templateLabels.isEmpty ? 0 : Double(memory.templateLabels.filter(labels.contains).count) / Double(memory.templateLabels.count)
            if best == nil || score > best!.1 { best = (sheet, score) }
        }
        return best.map { ($0.0, $0.1) }
    }
}
