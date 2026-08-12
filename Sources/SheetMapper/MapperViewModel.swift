import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MapperViewModel: ObservableObject {
    @Published var sourceIndex: WorkbookIndex?
    @Published var sourceSheet: SheetPreview?
    @Published var template: WorkbookPreview?
    @Published var sourceSheetName = ""
    @Published var templateSheetName = ""
    @Published var headerRow = 1
    @Published var dataStartRow = 2
    @Published var selectedSource = ""
    @Published var selectedTarget = ""
    @Published var mappings: [FieldMapping] = []
    @Published var keyField = ""
    @Published var sheetsPerWorkbook = 20
    @Published var outputMode: OutputMode = .combined
    @Published var memoryName = ""
    @Published var memories: [MappingMemory] = []
    @Published var status = L10n.text("status.chooseBoth")
    @Published var isBusy = false
    @Published var isLoadingSourceSheet = false
    @Published var generationStage: GenerationStage = .idle
    @Published var generationCompleted = 0
    @Published var generationTotal = 0

    private let memoryKey = "sheetmapper.mappingMemories.v1"
    private var sourceLoadTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var generationCancellation = CancellationToken()
    private var previewCache: [String: SheetPreview] = [:]
    private var previewLRU: [String] = []
    init() { loadMemories() }

    func languageDidChange() {
        objectWillChange.send()
        if sourceIndex == nil && template == nil { status = L10n.text("status.chooseBoth") }
    }

    var templateSheet: SheetPreview? { template?.sheets.first(where: { $0.name == templateSheetName }) }
    var headers: [String] {
        guard let rows = sourceSheet?.rows, rows.indices.contains(headerRow - 1) else { return [] }
        return rows[headerRow - 1].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func chooseSource() { chooseWorkbook(isSource: true) }
    func chooseTemplate() { chooseWorkbook(isSource: false) }

    private func chooseWorkbook(isSource: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = WorkbookConverter.acceptedExtensions.compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isSource { loadSourceWorkbook(url) } else { loadTemplateWorkbook(url) }
    }

    func loadDropped(_ url: URL, asSource: Bool) {
        guard WorkbookConverter.acceptedExtensions.contains(url.pathExtension.lowercased()) else { status = L10n.text("error.unsupportedFormat"); return }
        if asSource { loadSourceWorkbook(url) } else { loadTemplateWorkbook(url) }
    }

    private func loadSourceWorkbook(_ url: URL) {
        sourceLoadTask?.cancel(); previewCache.removeAll(); previewLRU.removeAll()
        isBusy = true; status = L10n.text("status.readingSourceIndex")
        Task.detached {
            do {
                let prepared = try WorkbookConverter.prepare(url)
                let index = try XLSXReader.index(prepared)
                await MainActor.run {
                    self.sourceIndex = index; self.sourceSheet = nil
                    self.sourceSheetName = index.sheets.first?.name ?? ""; self.isBusy = false
                    self.status = L10n.format("status.sourceLoaded", url.lastPathComponent)
                    self.selectSourceSheet(named: self.sourceSheetName)
                }
            } catch { await MainActor.run { self.status = L10n.format("error.readFailed", error.localizedDescription); self.isBusy = false } }
        }
    }

    private func loadTemplateWorkbook(_ url: URL) {
        isBusy = true; status = L10n.text("status.readingTemplate")
        Task.detached {
            do {
                let prepared = try WorkbookConverter.prepare(url)
                let preview = try XLSXReader.preview(prepared, maxRows: 300, maxColumns: 200)
                await MainActor.run { self.setTemplate(preview); self.status = L10n.format("status.templateLoaded", url.lastPathComponent); self.isBusy = false }
            } catch { await MainActor.run { self.status = L10n.format("error.readFailed", error.localizedDescription); self.isBusy = false } }
        }
    }

    private func setTemplate(_ preview: WorkbookPreview) { template = preview; templateSheetName = preview.sheets.first?.name ?? ""; autoApplyMemory() }

    func selectSourceSheet(named name: String) {
        guard !name.isEmpty, let index = sourceIndex, let sheetIndex = index.sheets.first(where: { $0.name == name }) else { return }
        sourceSheetName = name
        if let cached = previewCache[name] { touchCache(name); applySourcePreview(cached, fromCache: true); return }
        sourceLoadTask?.cancel(); isLoadingSourceSheet = true; status = L10n.format("status.readingSheet", name)
        sourceLoadTask = Task {
            do {
                let preview = try await Task.detached { try XLSXReader.preview(index, sheet: sheetIndex, maxRows: 50, maxColumns: 200) }.value
                try Task.checkCancellation()
                guard self.sourceSheetName == name else { return }
                self.insertCache(preview, key: name); self.applySourcePreview(preview, fromCache: false)
            } catch is CancellationError { }
            catch { if self.sourceSheetName == name { self.status = L10n.format("error.sheetReadFailed", error.localizedDescription) } }
            if self.sourceSheetName == name { self.isLoadingSourceSheet = false }
        }
    }

    private func applySourcePreview(_ preview: SheetPreview, fromCache: Bool) {
        sourceSheet = preview
        headerRow = detectedHeaderRow(in: preview)
        dataStartRow = headerRow + 1
        let oldCount = mappings.count
        validateMappingsForCurrentSheet()
        refreshHeaders()
        isLoadingSourceSheet = false
        let removed = oldCount - mappings.count
        status = L10n.format(fromCache ? "status.sheetOpenedCache" : "status.sheetOpened", preview.name, mappings.count, removed)
        autoApplyMemory()
    }

    private func detectedHeaderRow(in sheet: SheetPreview) -> Int {
        let expected = Set((mappings.map(\.source) + memories.flatMap(\.sourceFields)).map(normalized).filter { !$0.isEmpty })
        var best = (row: 1, score: -1)
        for (index, row) in sheet.rows.prefix(50).enumerated() {
            let values = row.map(normalized).filter { !$0.isEmpty && Double($0) == nil }
            let matches = values.filter(expected.contains).count
            let score = matches * 1000 + Set(values).count
            if score > best.score { best = (index + 1, score) }
        }
        return best.row
    }

    private func validateMappingsForCurrentSheet() {
        let lookup = normalizedHeaderLookup()
        mappings = mappings.compactMap { item in
            guard item.source.hasPrefix("__") || lookup[normalized(item.source)] != nil else { return nil }
            var copy = item; if let actual = lookup[normalized(item.source)] { copy.source = actual }; return copy
        }
    }

    private func insertCache(_ preview: SheetPreview, key: String) {
        previewCache[key] = preview; touchCache(key)
        while previewLRU.count > 5 { let removed = previewLRU.removeFirst(); previewCache.removeValue(forKey: removed) }
    }

    private func touchCache(_ key: String) { previewLRU.removeAll { $0 == key }; previewLRU.append(key) }

    func refreshHeaders() {
        if dataStartRow <= headerRow { dataStartRow = headerRow + 1 }
        if !headers.contains(keyField) { keyField = headers.first(where: { !$0.isEmpty }) ?? "" }
    }

    func addMapping() {
        guard !selectedSource.isEmpty, !selectedTarget.isEmpty else { return }
        mappings.removeAll { $0.target == selectedTarget }
        mappings.append(FieldMapping(source: selectedSource, target: selectedTarget))
    }

    func saveMemory() {
        guard !mappings.isEmpty, let sheet = templateSheet else { status = L10n.text("status.createMappingFirst"); return }
        let name = memoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.format("memory.defaultName", memories.count + 1) : memoryName
        let item = MappingMemory(name: name, sourceFields: headers.map(normalized).filter { !$0.isEmpty }, templateLabels: MappingMatcher.templateLabels(sheet), mappings: mappings, sheetsPerWorkbook: sheetsPerWorkbook, outputMode: outputMode)
        memories.removeAll { $0.name == name }; memories.insert(item, at: 0); persistMemories(); memoryName = name; status = L10n.format("status.memorySaved", name)
    }

    func deleteMemory(_ memory: MappingMemory) { memories.removeAll { $0.id == memory.id }; persistMemories(); status = L10n.format("status.memoryDeleted", memory.name) }

    func applyMemory(_ memory: MappingMemory, automatic: Bool = false) {
        guard let sourceMatch = bestSourceMatch(memory), let templateMatch = bestTemplateMatch(memory), sourceMatch.score >= 0.6, templateMatch.score >= 0.45 else { status = L10n.text("status.memoryMismatch"); return }
        sourceSheetName = sourceMatch.sheet.name; headerRow = sourceMatch.row; dataStartRow = sourceMatch.row + 1
        templateSheetName = templateMatch.sheet.name; refreshHeaders()
        let actual = normalizedHeaderLookup()
        mappings = memory.mappings.compactMap { old in guard let name = actual[normalized(old.source)] else { return nil }; var copy = old; copy.source = name; return copy }
        sheetsPerWorkbook = memory.sheetsPerWorkbook; outputMode = memory.outputMode; memoryName = memory.name
        status = L10n.format(automatic ? "status.memoryAutoApplied" : "status.memoryApplied", memory.name, Int(sourceMatch.score * 100), Int(templateMatch.score * 100))
    }

    func autoApplyMemory() {
        guard let sourceSheet, template != nil else { return }
        let currentSource = WorkbookPreview(url: sourceIndex?.url ?? URL(fileURLWithPath: "/"), sheets: [sourceSheet])
        let candidates = memories.compactMap { memory -> (MappingMemory, Double)? in
            guard let s = MappingMatcher.bestSource(memory, in: currentSource), let t = bestTemplateMatch(memory) else { return nil }; return (memory, s.score + t.score)
        }.sorted { $0.1 > $1.1 }
        if let best = candidates.first { applyMemory(best.0, automatic: true) }
    }

    func generate() {
        guard let sourceIndex, let selectedIndex = sourceIndex.sheets.first(where: { $0.name == sourceSheetName }), let template, let templateSheet else { status = L10n.text("status.chooseBoth"); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = L10n.text("output.defaultName")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let mappings = mappings, headerRow = headerRow, dataStartRow = dataStartRow, key = keyField, count = sheetsPerWorkbook, mode = outputMode
        generationCancellation.cancel(); generationCancellation = CancellationToken(); let cancellation = generationCancellation
        isBusy = true; generationStage = .reading; generationCompleted = 0; generationTotal = 0; status = generationStage.localizedName
        generationTask = Task {
            do {
                let full = try await Task.detached { try XLSXReader.fullSheet(sourceIndex, sheet: selectedIndex, maxRows: 10_000, maxColumns: 200) }.value
                try Task.checkCancellation()
                generationStage = .validating; status = generationStage.localizedName
                let source = WorkbookPreview(url: sourceIndex.url, sheets: [full.sheet])
                let summary = try await Task.detached {
                    try XLSXGenerator.generate(source: source, sourceSheet: full.sheet, template: template, templateSheet: templateSheet, headerRow: headerRow, dataStartRow: dataStartRow, mappings: mappings, keyField: key, sheetsPerWorkbook: count, outputMode: mode, destination: destination,
                        progress: { stage, completed, total in Task { @MainActor in self.generationStage = stage; self.generationCompleted = completed; self.generationTotal = total; self.status = stage.localizedName } },
                        isCancelled: { cancellation.isCancelled })
                }.value
                try Task.checkCancellation()
                status = L10n.format("status.generationComplete", summary.total, summary.success, summary.errors, summary.batches)
            } catch is CancellationError { status = L10n.text("status.generationCancelled") }
            catch { status = L10n.format("error.generationFailed", error.localizedDescription) }
            generationStage = .idle; isBusy = false
        }
    }

    func cancelGeneration() { generationCancellation.cancel(); generationTask?.cancel(); status = L10n.text("status.cancelling") }

    func exportConfiguration() {
        guard !mappings.isEmpty else { status = L10n.text("status.noMappings"); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = L10n.text("config.defaultName")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let config = MappingConfiguration(headerRow: headerRow, dataStartRow: dataStartRow, keyField: keyField, sheetsPerWorkbook: sheetsPerWorkbook, outputMode: outputMode, mappings: mappings)
        do { try JSONEncoder.pretty.encode(config).write(to: url); status = L10n.text("status.configSaved") } catch { status = L10n.format("error.configSaveFailed", error.localizedDescription) }
    }

    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try JSONDecoder().decode(MappingConfiguration.self, from: Data(contentsOf: url))
            headerRow = config.headerRow; dataStartRow = config.dataStartRow; keyField = config.keyField
            sheetsPerWorkbook = config.sheetsPerWorkbook; outputMode = config.outputMode
            let actual = normalizedHeaderLookup()
            mappings = config.mappings.compactMap { old in guard sourceSheet == nil || actual[normalized(old.source)] != nil else { return nil }; var copy = old; copy.source = actual[normalized(old.source)] ?? old.source; return copy }
            status = L10n.format("status.configImported", mappings.count)
        } catch { status = L10n.format("error.configImportFailed", error.localizedDescription) }
    }

    private func bestSourceMatch(_ memory: MappingMemory) -> (sheet: SheetPreview, row: Int, score: Double)? {
        guard let sourceSheet else { return nil }
        return MappingMatcher.bestSource(memory, in: WorkbookPreview(url: sourceIndex?.url ?? URL(fileURLWithPath: "/"), sheets: [sourceSheet]))
    }

    private func bestTemplateMatch(_ memory: MappingMemory) -> (sheet: SheetPreview, score: Double)? {
        MappingMatcher.bestTemplate(memory, in: template)
    }

    private func loadMemories() { if let data = UserDefaults.standard.data(forKey: memoryKey), let decoded = try? JSONDecoder().decode([MappingMemory].self, from: data) { memories = decoded } }
    private func persistMemories() { if let data = try? JSONEncoder().encode(Array(memories.prefix(50))) { UserDefaults.standard.set(data, forKey: memoryKey) } }

    private func normalizedHeaderLookup() -> [String: String] {
        var result: [String: String] = [:]
        for header in headers where !header.isEmpty {
            let key = normalized(header)
            if result[key] == nil { result[key] = header }
        }
        return result
    }
}
