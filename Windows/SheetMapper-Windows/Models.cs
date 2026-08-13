using System.Text.Json.Serialization;

namespace SheetMapper.Windows;

public sealed record SheetInfo(string Name, string Path);
public sealed record WorkbookIndex(string FilePath, List<SheetInfo> Sheets, List<string> SharedStrings);
public sealed record SheetData(string Name, string Path, List<List<string>> Rows);

public enum ValueTransform { Text, Raw, Number, ChineseDate, Upper, Lower }
public enum OutputMode { Combined, Separate }

public sealed class FieldMapping
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Source { get; set; } = "";
    public string Target { get; set; } = "";
    public ValueTransform Transform { get; set; } = ValueTransform.Text;
    public bool Required { get; set; }
}

public sealed class MappingConfiguration
{
    public int ConfigurationVersion { get; set; } = 2;
    public string ApplicationVersion { get; set; } = "2.0.0-windows";
    public int HeaderRow { get; set; } = 1;
    public int DataStartRow { get; set; } = 2;
    public string KeyField { get; set; } = "";
    public int SheetsPerWorkbook { get; set; } = 20;
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public OutputMode OutputMode { get; set; } = OutputMode.Combined;
    public List<FieldMapping> Mappings { get; set; } = [];
}

public sealed class MappingMemory
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public List<string> SourceFields { get; set; } = [];
    public List<string> TemplateLabels { get; set; } = [];
    public List<FieldMapping> Mappings { get; set; } = [];
    public int SheetsPerWorkbook { get; set; } = 20;
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public OutputMode OutputMode { get; set; } = OutputMode.Combined;
}

public sealed record GenerationResult(int Total, int Success, int Errors, int Batches, string Output);
