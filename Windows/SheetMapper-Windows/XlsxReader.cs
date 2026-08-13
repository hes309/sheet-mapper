using System.IO.Compression;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace SheetMapper.Windows;

public static class XlsxReader
{
    static readonly XNamespace Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    static readonly XNamespace RelDoc = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    static readonly XNamespace RelPkg = "http://schemas.openxmlformats.org/package/2006/relationships";

    public static WorkbookIndex Index(string file)
    {
        using var zip = ZipFile.OpenRead(file);
        var workbook = XDocument.Load(Entry(zip, "xl/workbook.xml").Open());
        var rels = XDocument.Load(Entry(zip, "xl/_rels/workbook.xml.rels").Open());
        var map = rels.Descendants(RelPkg + "Relationship").ToDictionary(x => (string)x.Attribute("Id")!, x => NormalizePart((string)x.Attribute("Target")!));
        var sheets = workbook.Descendants(Main + "sheet").Select(x => new SheetInfo((string)x.Attribute("name")!, map[(string)x.Attribute(RelDoc + "id")!])).ToList();
        var shared = new List<string>();
        var sharedEntry = zip.GetEntry("xl/sharedStrings.xml");
        if (sharedEntry != null)
        {
            var doc = XDocument.Load(sharedEntry.Open());
            shared.AddRange(doc.Descendants(Main + "si").Select(si => string.Concat(si.Descendants(Main + "t").Select(t => t.Value))));
        }
        return new(file, sheets, shared);
    }

    public static SheetData Read(WorkbookIndex book, SheetInfo sheet, int maxRows = 50, int maxColumns = 200)
    {
        using var zip = ZipFile.OpenRead(book.FilePath);
        var doc = XDocument.Load(Entry(zip, sheet.Path).Open(), LoadOptions.PreserveWhitespace);
        var values = new Dictionary<(int Row, int Col), string>();
        var lastRow = 0; var lastCol = 0;
        foreach (var cell in doc.Descendants(Main + "c"))
        {
            var address = (string?)cell.Attribute("r") ?? "";
            var point = CellPoint(address); if (point is null || point.Value.Row >= maxRows || point.Value.Col >= maxColumns) continue;
            var type = (string?)cell.Attribute("t") ?? "";
            var raw = type == "inlineStr" ? string.Concat(cell.Descendants(Main + "t").Select(x => x.Value)) : cell.Element(Main + "v")?.Value ?? "";
            if (type == "s" && int.TryParse(raw, out var si) && si >= 0 && si < book.SharedStrings.Count) raw = book.SharedStrings[si];
            if (raw.Length == 0) continue;
            values[point.Value] = raw; lastRow = Math.Max(lastRow, point.Value.Row); lastCol = Math.Max(lastCol, point.Value.Col);
        }
        var rows = new List<List<string>>();
        for (var r = 0; r <= lastRow; r++) { var row = new List<string>(); for (var c = 0; c <= lastCol; c++) row.Add(values.GetValueOrDefault((r, c), "")); rows.Add(row); }
        if (rows.Count == 0) rows.Add([""]);
        return new(sheet.Name, sheet.Path, rows);
    }

    public static (int Row, int Col)? CellPoint(string address)
    {
        var m = Regex.Match(address, "^([A-Za-z]+)([0-9]+)$"); if (!m.Success) return null;
        var col = 0; foreach (var ch in m.Groups[1].Value.ToUpperInvariant()) col = col * 26 + ch - 'A' + 1;
        return (int.Parse(m.Groups[2].Value) - 1, col - 1);
    }
    public static string ColumnName(int index) { var s = ""; for (var n = index + 1; n > 0; n /= 26) { n--; s = (char)('A' + n % 26) + s; } return s; }
    static ZipArchiveEntry Entry(ZipArchive zip, string path) => zip.GetEntry(path) ?? throw new InvalidDataException($"工作簿缺少 {path}");
    static string NormalizePart(string target) => target.StartsWith('/') ? target[1..] : target.StartsWith("xl/") ? target : "xl/" + target.TrimStart('.', '/');
}
