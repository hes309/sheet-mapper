# SheetMapper

SheetMapper is a native, local-first macOS app for mapping rows from a source spreadsheet into an XLSX template. It can create one workbook per row or batch multiple generated sheets into each workbook while preserving the uploaded template package.

[简体中文说明](README.zh-CN.md)

## Highlights

- Visual field-to-cell mapping with drag-and-drop file selection.
- Batch output with a configurable number of sheets per workbook.
- XLSX template preservation: only mapped target cells are changed.
- Reusable mapping presets that survive file and worksheet renaming when structures still match.
- On-demand worksheet previews and full-data generation.
- Local processing with no server upload and no Node.js runtime.
- English and Simplified Chinese UI.

## Requirements

- macOS 13 or later
- Xcode 16 or later recommended
- Swift Package Manager network access for the first dependency resolution

## Build

1. Open `SheetMapper.xcodeproj` in Xcode.
2. Select the `SheetMapper` scheme and `My Mac` destination.
3. Build and run.

The project uses [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) through Swift Package Manager.

## Supported files

- Native read/write: `.xlsx`
- WPS/legacy formats: `.xls`, `.et`, `.ett` when a compatible local converter is available
- Password-protected or encrypted workbooks are not supported

## Privacy

Workbook contents are processed locally. Do not attach confidential production workbooks to public bug reports; use a minimized synthetic sample instead.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

SheetMapper is licensed under the GNU General Public License v3.0. Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
