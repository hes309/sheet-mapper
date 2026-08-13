# SheetMapper for Windows

SheetMapper 的 Windows 10/11 绿色便携版。采用 C# / .NET 8 WinForms，发布包自带运行时，不需要安装 .NET、Node、Office 或 WPS 插件。

## 功能

- 基础工作簿与输出模板预览，支持按钮选择和拖拽 `.xlsx`。
- 点击基础字段和模板单元格建立映射，仅写入本次选定的映射。
- 支持一个工作簿包含多个数据 Sheet，默认每个工作簿 20 个 Sheet。
- 直接复制模板 XLSX 包并仅修改目标单元格，保留模板样式、边框、行高、列宽和打印设置。
- 自动忽略映射字段均为空的数据行。
- 结果 ZIP 同时包含 `SheetMapper映射配置.json` 和数据校验清单。
- 支持映射配置导入、导出。

`.et/.ett/.xls` 请先用 WPS 或 Excel 另存为标准 `.xlsx`。这是为了避免绿色版依赖本机 Office/WPS 转换组件。

## 构建绿色版

在安装了 .NET 8 SDK 的环境执行：

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish/win-x64
```

将 `publish/win-x64` 整个文件夹复制到 Windows 10/11，双击 `SheetMapper.exe` 即可。
