import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = MapperViewModel()
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        VStack(spacing: 0) {
            header
            setup
            HSplitView {
                preview(title: L10n.text("preview.source.title"), sheet: model.sourceSheet, source: true).frame(minWidth: 440)
                    .dropDestination(for: URL.self) { urls, _ in if let url = urls.first { model.loadDropped(url, asSource: true); return true }; return false }
                mappingControls.frame(minWidth: 190, maxWidth: 220)
                preview(title: L10n.text("preview.template.title"), sheet: model.templateSheet, source: false).frame(minWidth: 440)
                    .dropDestination(for: URL.self) { urls, _ in if let url = urls.first { model.loadDropped(url, asSource: false); return true }; return false }
            }.padding(12)
            mappingList
            footer
        }.frame(minWidth: 1180, minHeight: 760)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(L10n.text("app.title")).font(.title2.bold())
                Text(L10n.text("app.subtitle")).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L10n.text("language.label"), selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden().frame(width: 130)
            .onChange(of: language) { _ in model.languageDidChange() }
            if model.isBusy { ProgressView() }
        }
            .padding().foregroundStyle(.white).background(Color(red: 0.07, green: 0.27, blue: 0.43))
    }

    private var setup: some View {
        HStack {
            Button(L10n.text("ui.chooseSource"), action: model.chooseSource).buttonStyle(.borderedProminent)
            Picker(L10n.text("ui.worksheet"), selection: $model.sourceSheetName) { ForEach(model.sourceIndex?.sheets ?? []) { Text($0.name).tag($0.name) } }
                .frame(width: 240).onChange(of: model.sourceSheetName) { model.selectSourceSheet(named: $0) }
            Stepper(L10n.format("ui.headerRow", model.headerRow), value: $model.headerRow, in: 1...50).onChange(of: model.headerRow) { _ in model.refreshHeaders() }
            Stepper(L10n.format("ui.dataStartRow", model.dataStartRow), value: $model.dataStartRow, in: 2...10000)
            Divider().frame(height: 28)
            Button(L10n.text("ui.chooseTemplate"), action: model.chooseTemplate).buttonStyle(.borderedProminent).tint(.teal)
            Picker(L10n.text("ui.templateWorksheet"), selection: $model.templateSheetName) { ForEach(model.template?.sheets ?? []) { Text($0.name).tag($0.name) } }.frame(width: 220)
        }.padding(10).background(Color(nsColor: .controlBackgroundColor))
    }

    private func preview(title: String, sheet: SheetPreview?, source: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let sheet {
                NativeSpreadsheetGrid(
                    sheet: sheet,
                    source: source,
                    headerRow: model.headerRow,
                    selectedSource: model.selectedSource,
                    selectedTarget: model.selectedTarget,
                    mappedTargets: Set(model.mappings.flatMap { mappingTargets($0.target) })
                ) { value, address in
                    if source { model.selectedSource = value }
                    else { model.selectedTarget = address }
                }
                .overlay(alignment: .topTrailing) {
                    if source && model.isLoadingSourceSheet { HStack { ProgressView(); Text(L10n.text("sheet.loading")) }.padding(8).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 8)).padding(8) }
                }
            } else { Spacer(); Text(L10n.text("file.chooseFirst")).foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer() }
        }.padding(10).background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func mappingTargets(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: "，,;； \t\r\n"))
            .map { $0.uppercased() }.filter { !$0.isEmpty }
    }

    private var mappingControls: some View {
        VStack(spacing: 12) {
            Text(L10n.text("ui.addMapping")).font(.title3.bold())
            Text(model.selectedSource.isEmpty ? L10n.text("mapping.source.placeholder") : model.selectedSource).frame(maxWidth: .infinity).padding(8).background(.gray.opacity(0.1))
            Image(systemName: "arrow.down")
            Text(model.selectedTarget.isEmpty ? L10n.text("mapping.target.placeholder") : model.selectedTarget).frame(maxWidth: .infinity).padding(8).background(.gray.opacity(0.1))
            Button(L10n.text("ui.addMapping"), action: model.addMapping).buttonStyle(.borderedProminent).disabled(model.selectedSource.isEmpty || model.selectedTarget.isEmpty)
            Divider()
            TextField(L10n.text("ui.presetName"), text: $model.memoryName)
            Button(L10n.text("ui.savePreset"), action: model.saveMemory)
            ForEach(model.memories) { memory in HStack { Button(memory.name) { model.applyMemory(memory) }; Button(role: .destructive) { model.deleteMemory(memory) } label: { Image(systemName: "trash") } } }
            Spacer()
            Text(L10n.format("ui.mappingCount", model.mappings.count)).foregroundStyle(.secondary)
        }.padding(12)
    }

    private var mappingList: some View {
        VStack(alignment: .leading) {
            Text(L10n.text("ui.mappings")).font(.headline)
            HStack { Button(L10n.text("ui.exportConfig"), action: model.exportConfiguration); Button(L10n.text("ui.importConfig"), action: model.importConfiguration); Spacer() }
            Table($model.mappings) {
                TableColumn(L10n.text("ui.sourceField")) { $item in Text(item.source) }
                TableColumn(L10n.text("ui.templateCell")) { $item in Text(item.target) }
                TableColumn(L10n.text("ui.transform")) { $item in Picker("", selection: $item.transform) { ForEach(ValueTransform.allCases) { Text($0.localizedName).tag($0) } }.labelsHidden() }
                TableColumn(L10n.text("ui.required")) { $item in Toggle("", isOn: $item.required).labelsHidden() }
                TableColumn(L10n.text("ui.actions")) { $item in Button(L10n.text("ui.delete"), role: .destructive) { model.mappings.removeAll { $0.id == item.id } } }
            }.frame(height: 150)
        }.padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status).foregroundStyle(.secondary)
                if model.generationStage != .idle {
                    ProgressView(value: model.generationTotal > 0 ? Double(model.generationCompleted) : nil,
                                 total: model.generationTotal > 0 ? Double(model.generationTotal) : 1).frame(width: 240)
                }
            }
            Spacer()
            Picker(L10n.text("ui.keyField"), selection: $model.keyField) { ForEach(model.headers.filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) } }.frame(width: 220)
            Picker(L10n.text("ui.outputMode"), selection: $model.outputMode) { ForEach(OutputMode.allCases) { Text($0.localizedName).tag($0) } }.frame(width: 240)
            Stepper(L10n.format("ui.sheetsPerWorkbook", model.sheetsPerWorkbook), value: $model.sheetsPerWorkbook, in: 1...200)
            Button(L10n.text("ui.generate"), action: model.generate).buttonStyle(.borderedProminent).disabled(model.isBusy || model.mappings.isEmpty)
            if model.generationStage != .idle { Button(L10n.text("ui.cancel"), role: .cancel, action: model.cancelGeneration) }
        }.padding(12)
    }
}

private struct NativeSpreadsheetGrid: NSViewRepresentable {
    let sheet: SheetPreview
    let source: Bool
    let headerRow: Int
    let selectedSource: String
    let selectedTarget: String
    let mappedTargets: Set<String>
    let onSelect: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.action = #selector(Coordinator.cellClicked(_:))
        table.usesAlternatingRowBackgroundColors = false; table.rowHeight = 27
        table.selectionHighlightStyle = .none
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.allowsColumnSelection = false; table.allowsMultipleSelection = false
        context.coordinator.configureColumns(table)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.documentView = table; scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        let signature = "\(sheet.id)|\(headerRow)|\(selectedSource)|\(selectedTarget)|\(mappedTargets.sorted().joined(separator: ","))"
        guard signature != context.coordinator.lastSignature else { return }
        context.coordinator.lastSignature = signature
        context.coordinator.configureColumns(table); table.reloadData()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeSpreadsheetGrid
        var lastSignature = ""
        init(parent: NativeSpreadsheetGrid) { self.parent = parent }
        var rowCount: Int { min(50, parent.sheet.rows.count) }
        var columnCount: Int { min(200, max(1, parent.sheet.rows.prefix(50).map(\.count).max() ?? 1)) }
        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
        func configureColumns(_ table: NSTableView) {
            let wanted = columnCount + 1
            guard table.tableColumns.count != wanted else { return }
            table.tableColumns.forEach(table.removeTableColumn)
            for index in 0..<wanted {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.title = index == 0 ? "" : excelColumn(index - 1)
                column.width = index == 0 ? 38 : 111; column.minWidth = column.width; column.maxWidth = column.width
                table.addTableColumn(column)
            }
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue.dropFirst()) else { return nil }
            let id = NSUserInterfaceItemIdentifier("SpreadsheetCell")
            let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
                let value = NSTextField(labelWithString: ""); value.identifier = id; value.lineBreakMode = .byTruncatingTail
                value.alignment = .center; value.drawsBackground = true; value.font = .systemFont(ofSize: 12); return value
            }()
            if column == 0 { field.stringValue = "\(row + 1)"; field.textColor = .secondaryLabelColor; field.backgroundColor = .controlBackgroundColor; return field }
            let dataColumn = column - 1, address = "\(excelColumn(dataColumn))\(row + 1)"
            let raw = parent.sheet.rows.indices.contains(row) && parent.sheet.rows[row].indices.contains(dataColumn) ? parent.sheet.rows[row][dataColumn] : ""
            let value = previewDisplayValue(raw, address: address); field.stringValue = value; field.textColor = .labelColor
            let selected = parent.source ? (row == parent.headerRow - 1 && !value.isEmpty && value == parent.selectedSource) : address == parent.selectedTarget
            field.backgroundColor = selected ? NSColor.systemYellow.withAlphaComponent(0.35) : (!parent.source && parent.mappedTargets.contains(address) ? NSColor.systemGreen.withAlphaComponent(0.2) : NSColor.textBackgroundColor)
            return field
        }
        @objc func cellClicked(_ table: NSTableView) {
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            let column = table.clickedColumn
            guard row >= 0, column > 0 else { return }
            let dataColumn = column - 1, address = "\(excelColumn(dataColumn))\(row + 1)"
            let raw = parent.sheet.rows.indices.contains(row) && parent.sheet.rows[row].indices.contains(dataColumn) ? parent.sheet.rows[row][dataColumn] : ""
            let value = previewDisplayValue(raw, address: address)
            if parent.source && (row != parent.headerRow - 1 || value.isEmpty) { return }
            parent.onSelect(value, address)
        }
    }
}

private struct SpreadsheetPreviewGrid: View, Equatable {
    let sheet: SheetPreview
    let source: Bool
    let headerRow: Int
    let selectedSource: String
    let selectedTarget: String
    let mappedTargets: Set<String>
    let onSelect: (String, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sheet.id == rhs.sheet.id && lhs.source == rhs.source && lhs.headerRow == rhs.headerRow
            && lhs.selectedSource == rhs.selectedSource && lhs.selectedTarget == rhs.selectedTarget
            && lhs.mappedTargets == rhs.mappedTargets
    }

    var body: some View {
        let rows = Array(sheet.rows.prefix(50))
        let columnCount = min(200, max(1, rows.map(\.count).max() ?? 1))
        let columns = [GridItem(.fixed(38), spacing: 1)]
            + Array(repeating: GridItem(.fixed(111), spacing: 1), count: columnCount)

        ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 1) {
                headerCell("")
                ForEach(0..<columnCount, id: \.self) { headerCell(excelColumn($0), emphasized: true) }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    headerCell("\(rowIndex + 1)")
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        let value = row.indices.contains(columnIndex) ? row[columnIndex] : ""
                        let address = "\(excelColumn(columnIndex))\(rowIndex + 1)"
                        previewCell(value: value, address: address, rowIndex: rowIndex)
                    }
                }
            }
        }
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func previewCell(value: String, address: String, rowIndex: Int) -> some View {
        let displayValue = previewDisplayValue(value, address: address)
        let canSelect = source ? (rowIndex == headerRow - 1 && !displayValue.isEmpty) : true
        if canSelect {
            Button { onSelect(displayValue, address) } label: {
                Text(displayValue.isEmpty ? " " : displayValue).lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityLabel(displayValue.isEmpty ? address : displayValue)
            .frame(width: 111, height: 27)
            .background(selectionColor(value: displayValue, address: address, row: rowIndex))
            .contentShape(Rectangle())
        } else {
            Text(displayValue).lineLimit(1).frame(width: 105, height: 27).padding(.horizontal, 3)
                .foregroundStyle(Color.primary)
                .background(selectionColor(value: displayValue, address: address, row: rowIndex))
        }
    }

    private func headerCell(_ value: String, emphasized: Bool = false) -> some View {
        Text(value).fontWeight(emphasized ? .semibold : .regular).foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 27, maxHeight: 27)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private func selectionColor(value: String, address: String, row: Int) -> Color {
        if source && row == headerRow - 1 && !value.isEmpty && value == selectedSource { return .yellow.opacity(0.35) }
        if !source && address == selectedTarget { return .yellow.opacity(0.35) }
        if !source && mappedTargets.contains(address) { return .green.opacity(0.25) }
        return .gray.opacity(0.08)
    }
}
