using System.IO.Compression;
using System.Text.Json;
using SheetMapper.Windows;

var root = Path.Combine(Path.GetTempPath(), "sheetmapper-win-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    var source = Path.Combine(root, "source.xlsx"); var template = Path.Combine(root, "template.xlsx"); var output = Path.Combine(root, "result.zip");
    MakeWorkbook(source, "People", SourceRows()); MakeWorkbook(template, "Card", TemplateRows(), true);
    var sourceIndex = XlsxReader.Index(source); var templateIndex = XlsxReader.Index(template);
    var mappings = new List<FieldMapping> { new() { Source = "Name", Target = "B2" }, new() { Source = "Account", Target = "D2" } };
    var config = new MappingConfiguration { HeaderRow = 1, DataStartRow = 2, KeyField = "Account", SheetsPerWorkbook = 20, OutputMode = OutputMode.Combined, Mappings = mappings };
    var result = await XlsxGenerator.GenerateAsync(sourceIndex, sourceIndex.Sheets[0], template, templateIndex.Sheets[0], config, output, null, CancellationToken.None);
    Check(result.Total == 29 && result.Success == 29 && result.Batches == 2, "29条数据应生成2批");
    var unpack = Path.Combine(root, "unpack"); ZipFile.ExtractToDirectory(output, unpack);
    Check(File.Exists(Path.Combine(unpack, "SheetMapper映射配置.json")), "结果缺少映射配置");
    var saved = JsonSerializer.Deserialize<MappingConfiguration>(File.ReadAllText(Path.Combine(unpack, "SheetMapper映射配置.json")), new JsonSerializerOptions { PropertyNameCaseInsensitive = true, Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } });
    Check(saved?.Mappings.Count == 2 && saved.SheetsPerWorkbook == 20 && saved.KeyField == "Account", "映射配置内容不一致");
    var books = Directory.GetFiles(unpack, "*.xlsx"); Check(books.Length == 2, "输出工作簿数量不正确");
    var firstBook = books.OrderBy(x => x, StringComparer.Ordinal).First();
    using var generated = ZipFile.OpenRead(firstBook); using var original = ZipFile.OpenRead(template);
    Check(Read(generated, "xl/styles.xml") == Read(original, "xl/styles.xml"), "styles.xml被改变");
    var sheet = Read(generated, "xl/worksheets/sheet1.xml");
    Check(sheet.Contains("Alice 1") && sheet.Contains("ID-001"), "映射数据未写入");
    Check(sheet.Contains("UNCHANGED") && sheet.Contains("orientation=\"landscape\""), "未映射内容或打印设置丢失");
    Check(generated.GetEntry("xl/worksheets/_rels/sheet1.xml.rels") != null, "模板Sheet关联资源未复制");
    Check(generated.GetEntry("xl/worksheets/sheet21.xml") != null, "生成目录Sheet缺失");
    Console.WriteLine("PASS: 29 records, 2 batches, template fidelity, related parts, mapping config.");
}
finally { try { Directory.Delete(root, true); } catch { } }

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static string Read(ZipArchive zip, string name) { using var r = new StreamReader(zip.GetEntry(name)!.Open()); return r.ReadToEnd(); }
static string SourceRows() => "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Account</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Name</t></is></c></row>" + string.Concat(Enumerable.Range(1, 29).Select(i => $"<row r=\"{i + 1}\"><c r=\"A{i + 1}\" t=\"inlineStr\"><is><t>ID-{i:000}</t></is></c><c r=\"B{i + 1}\" t=\"inlineStr\"><is><t>Alice {i}</t></is></c></row>"));
static string TemplateRows() => "<row r=\"1\" ht=\"30\" customHeight=\"1\"><c r=\"A1\" t=\"inlineStr\" s=\"1\"><is><t>UNCHANGED</t></is></c></row><row r=\"2\"><c r=\"A2\" t=\"inlineStr\" s=\"1\"><is><t>Name</t></is></c><c r=\"B2\" s=\"2\"/><c r=\"C2\" t=\"inlineStr\" s=\"1\"><is><t>Account</t></is></c><c r=\"D2\" s=\"2\"/></row>";
static void MakeWorkbook(string output, string name, string rows, bool template = false)
{
    var dir = Path.Combine(Path.GetTempPath(), "xlsx-fixture-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path.Combine(dir, "_rels")); Directory.CreateDirectory(Path.Combine(dir, "xl", "_rels")); Directory.CreateDirectory(Path.Combine(dir, "xl", "worksheets", "_rels"));
    File.WriteAllText(Path.Combine(dir, "[Content_Types].xml"), "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>");
    File.WriteAllText(Path.Combine(dir, "_rels", ".rels"), "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
    File.WriteAllText(Path.Combine(dir, "xl", "workbook.xml"), $"<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"{name}\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>");
    File.WriteAllText(Path.Combine(dir, "xl", "_rels", "workbook.xml.rels"), "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>");
    File.WriteAllText(Path.Combine(dir, "xl", "styles.xml"), "<?xml version=\"1.0\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"1\"><font><name val=\"Arial\"/></font></fonts><fills count=\"1\"><fill><patternFill patternType=\"none\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/></border></borders><cellXfs count=\"3\"><xf/><xf applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf><xf applyAlignment=\"1\"><alignment horizontal=\"left\"/></xf></cellXfs></styleSheet>");
    File.WriteAllText(Path.Combine(dir, "xl", "worksheets", "sheet1.xml"), $"<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols><col min=\"1\" max=\"4\" width=\"18\" customWidth=\"1\"/></cols><sheetData>{rows}</sheetData><mergeCells count=\"1\"><mergeCell ref=\"A1:D1\"/></mergeCells><pageMargins left=\"0.3\" right=\"0.3\" top=\"0.4\" bottom=\"0.4\"/><pageSetup orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"1\"/></worksheet>");
    if (template) File.WriteAllText(Path.Combine(dir, "xl", "worksheets", "_rels", "sheet1.xml.rels"), "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.invalid\" TargetMode=\"External\"/></Relationships>");
    ZipFile.CreateFromDirectory(dir, output); Directory.Delete(dir, true);
}
