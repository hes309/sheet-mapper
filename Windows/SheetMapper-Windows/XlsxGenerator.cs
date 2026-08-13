using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace SheetMapper.Windows;

public static class XlsxGenerator
{
    const string ConfigName = "SheetMapper映射配置.json";
    static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    static readonly XNamespace RelDoc = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    static readonly XNamespace RelPkg = "http://schemas.openxmlformats.org/package/2006/relationships";
    static readonly XNamespace Types = "http://schemas.openxmlformats.org/package/2006/content-types";
    sealed record Record(List<string> Values, int SourceRow, string Key);

    public static async Task<GenerationResult> GenerateAsync(WorkbookIndex sourceBook, SheetInfo sourceInfo, string templateFile, SheetInfo templateInfo,
        MappingConfiguration config, string destination, IProgress<(string Stage, int Current, int Total)>? progress, CancellationToken token)
    {
        return await Task.Run(() => Generate(sourceBook, sourceInfo, templateFile, templateInfo, config, destination, progress, token), token);
    }

    static GenerationResult Generate(WorkbookIndex sourceBook, SheetInfo sourceInfo, string templateFile, SheetInfo templateInfo,
        MappingConfiguration config, string destination, IProgress<(string, int, int)>? progress, CancellationToken token)
    {
        if (config.Mappings.Count == 0) throw new InvalidOperationException("请先建立映射关系");
        progress?.Report(("正在读取完整数据", 0, 1));
        var source = XlsxReader.Read(sourceBook, sourceInfo, 10000, 200);
        token.ThrowIfCancellationRequested();
        if (config.HeaderRow < 1 || config.HeaderRow > source.Rows.Count) throw new InvalidOperationException("表头行超出范围");
        var headers = source.Rows[config.HeaderRow - 1].Select(Clean).ToList();
        var headerMap = headers.Select((x, i) => (x, i)).Where(x => x.x.Length > 0).GroupBy(x => x.x).ToDictionary(g => g.Key, g => g.First().i);
        if (!headerMap.TryGetValue(Clean(config.KeyField), out var keyIndex)) throw new InvalidOperationException($"找不到主键字段：{config.KeyField}");
        foreach (var m in config.Mappings) if (!headerMap.ContainsKey(Clean(m.Source))) throw new InvalidOperationException($"找不到基础字段：{m.Source}");

        var records = new List<Record>(); var errors = new List<string[]>();
        var start = Math.Max(0, config.DataStartRow - 1); var totalRows = Math.Max(0, source.Rows.Count - start);
        for (var r = start; r < source.Rows.Count; r++)
        {
            token.ThrowIfCancellationRequested(); var row = source.Rows[r];
            if (!config.Mappings.Any(m => headerMap.TryGetValue(Clean(m.Source), out var c) && c < row.Count && Clean(row[c]).Length > 0)) continue;
            var key = keyIndex < row.Count ? Clean(row[keyIndex]) : ""; var reasons = new List<string>();
            if (key.Length == 0 || key == "0") reasons.Add("主键字段为空");
            foreach (var m in config.Mappings.Where(x => x.Required)) if (!headerMap.TryGetValue(Clean(m.Source), out var c) || c >= row.Count || Clean(row[c]).Length == 0) reasons.Add($"必填字段“{m.Source}”为空");
            if (reasons.Count == 0) records.Add(new(row, r + 1, key)); else errors.Add([(r + 1).ToString(), key, string.Join('；', reasons)]);
            if ((r - start + 1) % 100 == 0 || r == source.Rows.Count - 1) progress?.Report(("正在校验有效数据", r - start + 1, totalRows));
        }
        if (records.Count == 0) throw new InvalidOperationException("没有可生成的有效数据");
        var workspace = TempDir("sheetmapper-result");
        try
        {
            var batchSize = Math.Clamp(config.SheetsPerWorkbook, 1, 200); var generated = 0;
            if (config.OutputMode == OutputMode.Combined)
            {
                for (var offset = 0; offset < records.Count; offset += batchSize)
                {
                    token.ThrowIfCancellationRequested(); var count = Math.Min(batchSize, records.Count - offset);
                    var file = Path.Combine(workspace, $"通用映射_第{offset / batchSize + 1:000}批_第{offset + 1}-{offset + count}条.xlsx");
                    BuildBatch(records.GetRange(offset, count), offset + 1, templateFile, templateInfo, config.Mappings, headerMap, file);
                    progress?.Report(("正在生成批次", ++generated, (records.Count + batchSize - 1) / batchSize));
                }
            }
            else
            {
                for (var i = 0; i < records.Count; i++)
                {
                    token.ThrowIfCancellationRequested(); var folder = Path.Combine(workspace, $"第{i / batchSize + 1:000}批"); Directory.CreateDirectory(folder);
                    BuildBatch([records[i]], i + 1, templateFile, templateInfo, config.Mappings, headerMap, Path.Combine(folder, $"{i + 1:0000}_{Safe(records[i].Key)}.xlsx"));
                    progress?.Report(("正在生成文件", ++generated, records.Count));
                }
            }
            WriteCsv(Path.Combine(workspace, "数据校验异常.csv"), [["来源行", "主键", "异常原因"], .. errors]);
            File.WriteAllText(Path.Combine(workspace, ConfigName), JsonSerializer.Serialize(config, JsonOptions), new UTF8Encoding(false));
            if (File.Exists(destination)) File.Delete(destination);
            ZipFile.CreateFromDirectory(workspace, destination, CompressionLevel.Optimal, false);
            return new(records.Count + errors.Count, records.Count, errors.Count, (records.Count + batchSize - 1) / batchSize, destination);
        }
        finally { try { Directory.Delete(workspace, true); } catch { } }
    }

    static void BuildBatch(List<Record> records, int startNumber, string templateFile, SheetInfo selectedSheet, List<FieldMapping> mappings, Dictionary<string, int> headerMap, string output)
    {
        var folder = TempDir("sheetmapper-batch");
        try
        {
            ZipFile.ExtractToDirectory(templateFile, folder);
            var wbPath = Path.Combine(folder, "xl", "workbook.xml"); var relPath = Path.Combine(folder, "xl", "_rels", "workbook.xml.rels"); var typePath = Path.Combine(folder, "[Content_Types].xml");
            var wb = XDocument.Load(wbPath, LoadOptions.PreserveWhitespace); var rels = XDocument.Load(relPath, LoadOptions.PreserveWhitespace); var types = XDocument.Load(typePath, LoadOptions.PreserveWhitespace);
            var selected = wb.Descendants(Main + "sheet").First(x => (string?)x.Attribute("name") == selectedSheet.Name);
            var selectedRid = (string)selected.Attribute(RelDoc + "id")!;
            var rel = rels.Descendants(RelPkg + "Relationship").First(x => (string?)x.Attribute("Id") == selectedRid);
            var templatePart = NormalizePart((string)rel.Attribute("Target")!); var templateXml = File.ReadAllText(Path.Combine(folder, templatePart));
            var templatePartName = Path.GetFileName(templatePart);
            var worksheetFolder = Path.Combine(folder, "xl", "worksheets");
            var worksheetRelsFolder = Path.Combine(worksheetFolder, "_rels");
            var templateSheetRels = Path.Combine(worksheetRelsFolder, templatePartName + ".rels");
            var hasTemplateSheetRels = File.Exists(templateSheetRels);
            var templateSheetRelsBytes = hasTemplateSheetRels ? File.ReadAllBytes(templateSheetRels) : null;
            foreach (var sheet in wb.Descendants(Main + "sheet").ToList()) sheet.Remove();
            foreach (var relationship in rels.Descendants(RelPkg + "Relationship").Where(x => ((string?)x.Attribute("Type"))?.EndsWith("/worksheet") == true).ToList()) relationship.Remove();
            foreach (var old in Directory.GetFiles(worksheetFolder, "sheet*.xml")) File.Delete(old);
            if (Directory.Exists(worksheetRelsFolder)) foreach (var old in Directory.GetFiles(worksheetRelsFolder, "sheet*.xml.rels")) File.Delete(old);
            foreach (var oldOverride in types.Descendants(Types + "Override").Where(x => ((string?)x.Attribute("PartName"))?.StartsWith("/xl/worksheets/", StringComparison.OrdinalIgnoreCase) == true).ToList()) oldOverride.Remove();
            var nextRid = rels.Descendants(RelPkg + "Relationship").Select(x => Regex.Match((string?)x.Attribute("Id") ?? "", @"rId(\d+)")).Where(x => x.Success).Select(x => int.Parse(x.Groups[1].Value)).DefaultIfEmpty(0).Max() + 1;
            var sheetsNode = wb.Descendants(Main + "sheets").First();
            for (var i = 0; i < records.Count; i++)
            {
                var sheetNumber = i + 1; var sheetName = SafeSheet($"{startNumber + i:000}_{records[i].Key}"); var path = Path.Combine(folder, "xl", "worksheets", $"sheet{sheetNumber}.xml");
                var xml = XDocument.Parse(templateXml, LoadOptions.PreserveWhitespace); ApplyMappings(xml, records[i], mappings, headerMap); xml.Save(path, SaveOptions.DisableFormatting);
                if (templateSheetRelsBytes != null)
                {
                    Directory.CreateDirectory(worksheetRelsFolder);
                    File.WriteAllBytes(Path.Combine(worksheetRelsFolder, $"sheet{sheetNumber}.xml.rels"), templateSheetRelsBytes);
                }
                var rid = $"rId{nextRid++}"; sheetsNode.Add(new XElement(Main + "sheet", new XAttribute("name", sheetName), new XAttribute("sheetId", sheetNumber), new XAttribute(RelDoc + "id", rid)));
                rels.Root!.Add(new XElement(RelPkg + "Relationship", new XAttribute("Id", rid), new XAttribute("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"), new XAttribute("Target", $"worksheets/sheet{sheetNumber}.xml")));
                types.Root!.Add(new XElement(Types + "Override", new XAttribute("PartName", $"/xl/worksheets/sheet{sheetNumber}.xml"), new XAttribute("ContentType", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")));
            }
            var directoryNumber = records.Count + 1;
            var directoryPath = Path.Combine(worksheetFolder, $"sheet{directoryNumber}.xml");
            DirectoryXml(records, startNumber).Save(directoryPath, SaveOptions.DisableFormatting);
            var directoryRid = $"rId{nextRid++}";
            sheetsNode.AddFirst(new XElement(Main + "sheet", new XAttribute("name", "生成目录"), new XAttribute("sheetId", directoryNumber), new XAttribute(RelDoc + "id", directoryRid)));
            rels.Root!.Add(new XElement(RelPkg + "Relationship", new XAttribute("Id", directoryRid), new XAttribute("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"), new XAttribute("Target", $"worksheets/sheet{directoryNumber}.xml")));
            types.Root!.Add(new XElement(Types + "Override", new XAttribute("PartName", $"/xl/worksheets/sheet{directoryNumber}.xml"), new XAttribute("ContentType", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")));
            wb.Save(wbPath, SaveOptions.DisableFormatting); rels.Save(relPath, SaveOptions.DisableFormatting); types.Save(typePath, SaveOptions.DisableFormatting);
            if (File.Exists(output)) File.Delete(output); ZipFile.CreateFromDirectory(folder, output, CompressionLevel.Optimal, false);
        }
        finally { try { Directory.Delete(folder, true); } catch { } }
    }

    static void ApplyMappings(XDocument sheet, Record record, List<FieldMapping> mappings, Dictionary<string, int> headerMap)
    {
        var sheetData = sheet.Descendants(Main + "sheetData").First();
        foreach (var m in mappings)
        {
            var col = headerMap[Clean(m.Source)]; var converted = col < record.Values.Count ? Transform(record.Values[col], m.Transform) : (Value: "", Numeric: false);
            foreach (var target in m.Target.Split([',', '，', ';', '；'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var point = XlsxReader.CellPoint(target) ?? throw new InvalidOperationException($"无效目标单元格：{target}");
                var rowNumber = point.Row + 1; var row = sheetData.Elements(Main + "row").FirstOrDefault(x => (int?)x.Attribute("r") == rowNumber);
                if (row == null) { row = new XElement(Main + "row", new XAttribute("r", rowNumber)); sheetData.Add(row); }
                var cell = row.Elements(Main + "c").FirstOrDefault(x => (string?)x.Attribute("r") == target.ToUpperInvariant());
                if (cell == null) { cell = new XElement(Main + "c", new XAttribute("r", target.ToUpperInvariant())); row.Add(cell); }
                cell.Elements().Remove();
                if (converted.Numeric)
                {
                    cell.Attribute("t")?.Remove();
                    cell.Add(new XElement(Main + "v", converted.Value));
                }
                else
                {
                    cell.SetAttributeValue("t", "inlineStr");
                    cell.Add(new XElement(Main + "is", new XElement(Main + "t", new XAttribute(XNamespace.Xml + "space", "preserve"), converted.Value)));
                }
            }
        }
    }

    static (string Value, bool Numeric) Transform(string value, ValueTransform transform)
    {
        if (transform == ValueTransform.Number && decimal.TryParse(value, out var number)) return (number.ToString(CultureInfo.InvariantCulture), true);
        if (transform == ValueTransform.ChineseDate && DateTime.TryParse(value, out var date)) return (date.ToString("yyyy年MM月dd日"), false);
        return (transform switch { ValueTransform.Upper => value.ToUpperInvariant(), ValueTransform.Lower => value.ToLowerInvariant(), _ => value }, false);
    }
    static XDocument DirectoryXml(List<Record> records, int startNumber)
    {
        var sheetData = new XElement(Main + "sheetData");
        var rows = new List<string[]> { new[] { "序号", "来源行", "主键", "Sheet名称" } };
        rows.AddRange(records.Select((record, i) => new[] { (startNumber + i).ToString(), record.SourceRow.ToString(), record.Key, SafeSheet($"{startNumber + i:000}_{record.Key}") }));
        for (var r = 0; r < rows.Count; r++)
        {
            var row = new XElement(Main + "row", new XAttribute("r", r + 1));
            for (var c = 0; c < rows[r].Length; c++) row.Add(new XElement(Main + "c", new XAttribute("r", $"{XlsxReader.ColumnName(c)}{r + 1}"), new XAttribute("t", "inlineStr"), new XElement(Main + "is", new XElement(Main + "t", rows[r][c]))));
            sheetData.Add(row);
        }
        return new XDocument(new XDeclaration("1.0", "UTF-8", "yes"), new XElement(Main + "worksheet", new XElement(Main + "cols", new XElement(Main + "col", new XAttribute("min", 1), new XAttribute("max", 4), new XAttribute("width", 20), new XAttribute("customWidth", 1))), sheetData));
    }
    static string Clean(string s) => s.Replace("\u200B", "").Trim().Replace(" ", "").Replace('（', '(').Replace('）', ')').ToLowerInvariant();
    static string TempDir(string prefix) { var p = Path.Combine(Path.GetTempPath(), $"{prefix}-{Guid.NewGuid():N}"); Directory.CreateDirectory(p); return p; }
    static string Safe(string s) => Regex.Replace(s, "[<>:\"/\\|?*]", "_");
    static string SafeSheet(string s) { s = Regex.Replace(s, @"[:\\/?*\[\]]", "_"); return s.Length > 31 ? s[..31] : s; }
    static string NormalizePart(string target) => target.StartsWith('/') ? target[1..] : target.StartsWith("xl/") ? target : "xl/" + target.TrimStart('.', '/');
    static void WriteCsv(string path, IEnumerable<string[]> rows) => File.WriteAllLines(path, rows.Select(r => string.Join(',', r.Select(x => $"\"{x.Replace("\"", "\"\"")}\""))), new UTF8Encoding(true));
    static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } };
}
