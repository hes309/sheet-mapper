import Foundation

@main
struct EndToEnd {
    static func main() throws {
        let fixtureRoot = try ProcessRunner.temporaryDirectory(prefix: "sheetmapper-fixtures")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let sourceURL = fixtureRoot.appendingPathComponent("synthetic-source.xlsx")
        let templateURL = fixtureRoot.appendingPathComponent("synthetic-template.xlsx")
        try makeWorkbook(at: sourceURL, sheetName: "People", worksheet: sourceWorksheet())
        try makeWorkbook(at: templateURL, sheetName: "Card", worksheet: templateWorksheet())

        let sourceIndex = try XLSXReader.index(sourceURL)
        guard let sourceIndexSheet = sourceIndex.sheets.first else { throw MapperError.message("Missing synthetic source sheet") }
        let lightweight = try XLSXReader.preview(sourceIndex, sheet: sourceIndexSheet, maxRows: 10, maxColumns: 20)
        let full = try XLSXReader.fullSheet(sourceIndex, sheet: sourceIndexSheet, maxRows: 10_000, maxColumns: 200)
        guard lightweight.rows.count == 10, full.sheet.rows.count == 30 else { throw MapperError.message("Preview/full read separation failed") }

        let source = WorkbookPreview(url: sourceURL, sheets: [full.sheet])
        let template = try XLSXReader.preview(templateURL, maxRows: 30, maxColumns: 20)
        guard let templateSheet = template.sheets.first else { throw MapperError.message("Missing synthetic template sheet") }
        let output = fixtureRoot.appendingPathComponent("result.zip")
        let mappings = [FieldMapping(source: "Name", target: "B2"), FieldMapping(source: "Account", target: "D2")]
        let summary = try XLSXGenerator.generate(source: source, sourceSheet: full.sheet, template: template, templateSheet: templateSheet,
            headerRow: 1, dataStartRow: 2, mappings: mappings, keyField: "Account", sheetsPerWorkbook: 20, destination: output)
        guard summary.total == 29, summary.success == 29, summary.batches == 2 else { throw MapperError.message("Batch generation failed") }

        let unpackedResult = try ProcessRunner.temporaryDirectory(prefix: "sheetmapper-result")
        defer { try? FileManager.default.removeItem(at: unpackedResult) }
        try ProcessRunner.unzip(output, to: unpackedResult)
        let bundledConfigURL = unpackedResult.appendingPathComponent(XLSXGenerator.bundledConfigurationFilename)
        guard FileManager.default.fileExists(atPath: bundledConfigURL.path) else {
            throw MapperError.message("Generated ZIP is missing \(XLSXGenerator.bundledConfigurationFilename)")
        }
        let bundledConfig = try JSONDecoder().decode(MappingConfiguration.self, from: Data(contentsOf: bundledConfigURL))
        guard bundledConfig.headerRow == 1,
              bundledConfig.dataStartRow == 2,
              bundledConfig.keyField == "Account",
              bundledConfig.sheetsPerWorkbook == 20,
              bundledConfig.outputMode == .combined,
              bundledConfig.mappings == mappings else {
            throw MapperError.message("Bundled mapping configuration does not match generation settings")
        }

        let legacy = #"{"headerRow":1,"dataStartRow":2,"keyField":"Account","sheetsPerWorkbook":20,"outputMode":"一个工作簿包含多个Sheet","mappings":[]}"#.data(using: .utf8)!
        let migrated = try JSONDecoder().decode(MappingConfiguration.self, from: legacy)
        guard migrated.configurationVersion == 1, migrated.applicationVersion == "1.x" else { throw MapperError.message("Legacy configuration migration failed") }
        let current = MappingConfiguration(headerRow: 1, dataStartRow: 2, keyField: "Account", sheetsPerWorkbook: 20, outputMode: .combined, mappings: mappings)
        let roundTrip = try JSONDecoder().decode(MappingConfiguration.self, from: JSONEncoder().encode(current))
        guard roundTrip.configurationVersion == 2, roundTrip.applicationVersion == "2.0.0" else { throw MapperError.message("Configuration version round-trip failed") }

        guard previewDisplayValue("A2", address: "A2").isEmpty else { throw MapperError.message("Blank coordinate placeholder rule failed") }
        print("SheetMapper end-to-end tests passed: 29 records, 2 batches, bundled configuration, versioned migration.")
    }

    private static func sourceWorksheet() -> String {
        let header = row(1, ["A1": "Account", "B1": "Name", "C1": "Amount"])
        let records = (1...29).map { index in row(index + 1, ["A\(index + 1)": "ID-\(String(format: "%03d", index))", "B\(index + 1)": "Person \(index)", "C\(index + 1)": String(index * 100)]) }.joined()
        return worksheet(header + records)
    }

    private static func templateWorksheet() -> String {
        worksheet(row(1, ["A1": "Record Card"]) + #"<row r="2"><c r="A2" t="inlineStr" s="1"><is><t>Name</t></is></c><c r="B2" s="2"/><c r="C2" t="inlineStr" s="1"><is><t>Account</t></is></c><c r="D2" s="2"/></row>"#)
    }

    private static func worksheet(_ rows: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetFormatPr defaultRowHeight="18"/><cols><col min="1" max="4" width="18" customWidth="1"/></cols><sheetData>"# + rows + #"</sheetData><pageMargins left="0.3" right="0.3" top="0.4" bottom="0.4" header="0" footer="0"/><pageSetup orientation="landscape" fitToWidth="1" fitToHeight="1"/></worksheet>"#
    }

    private static func row(_ number: Int, _ values: [String: String]) -> String {
        let cells = values.sorted { $0.key < $1.key }.map { #"<c r="\#($0.key)" t="inlineStr"><is><t>\#(escape($0.value))</t></is></c>"# }.joined()
        return "<row r=\"\(number)\">\(cells)</row>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func makeWorkbook(at output: URL, sheetName: String, worksheet: String) throws {
        let folder = try ProcessRunner.temporaryDirectory(prefix: "sheetmapper-xlsx")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\#(sheetName)" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
            "xl/styles.xml": #"<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Arial"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="right"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment horizontal="left"/></xf></cellXfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": worksheet
        ]
        for (path, contents) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try ProcessRunner.zipContents(of: folder, to: output)
    }
}
