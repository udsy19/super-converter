import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Export/SpreadsheetWriter.swift @ 058469b (`OfficeXLSX`: package layout, column names,
// styles part), rewritten over Core's `Workbook`: shared strings, formulas with cached results, dates, booleans, errors,
// number formats, fonts, fills, alignment, merges, widths, hidden sheets and print areas.
//
// XLSX writer (formats §3.2). Output is deterministic: no dates, stable ids.

enum XLSXWriter {
    /// "A", "Z", "AA"… for a zero-based column.
    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func reference(row: Int, column: Int) -> String { columnName(column) + "\(row + 1)" }

    /// Excel's sheet-name rules: no []:*?/\ and no apostrophe at the edges, at most 31 characters, not empty, unique without
    /// regard to case.
    static func sheetNames(_ names: [String]) -> [String] {
        var used: Set<String> = []
        return names.map { raw in
            var base = String(raw.filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: "'")).prefix(31))
            if base.isEmpty { base = "Sheet" }
            var name = base, n = 2
            while used.contains(name.lowercased()) {
                let suffix = " \(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    private static let builtInFormats: [String: Int] = ["0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10]
    private static let defaultDateFormat = "yyyy-mm-dd"

    private struct StyleKey: Hashable {
        var numFmt: Int
        var font: Int
        var fill: Int
        var alignment: DocParagraphStyle.Alignment?
        var wrap: Bool
    }

    private struct FontKey: Hashable {
        var bold: Bool, italic: Bool, name: String?, size: Double?, colour: String?
    }

    /// The `.xlsx` bytes. `keepFormulas: false` writes values only ("Formulas: values only").
    static func write(_ workbook: Workbook, keepFormulas: Bool = true) -> Data {
        var customFormats: [String: Int] = [:]
        var fonts: [FontKey] = [FontKey(bold: false, italic: false, name: nil, size: nil, colour: nil)]
        var fills: [String] = []
        var xfs: [StyleKey] = [StyleKey(numFmt: 0, font: 0, fill: 0, alignment: nil, wrap: false)]
        var xfIndex: [StyleKey: Int] = [xfs[0]: 0]
        var strings: [String] = []
        var stringIndex: [String: Int] = [:]

        func formatID(_ code: String?) -> Int {
            guard let code, code != "General" else { return 0 }
            if let builtIn = builtInFormats[code] { return builtIn }
            if let id = customFormats[code] { return id }
            let id = 164 + customFormats.count
            customFormats[code] = id
            return id
        }
        func style(_ cell: Cell) -> Int {
            var code = cell.numberFormat
            if code == nil, case .date = cell.value { code = defaultDateFormat }
            let s = cell.style
            let font = FontKey(bold: s.bold, italic: s.italic, name: s.fontName, size: s.fontSize, colour: s.textColour)
            var fontID = 0
            if font != fonts[0] {
                if let found = fonts.firstIndex(of: font) { fontID = found } else { fonts.append(font); fontID = fonts.count - 1 }
            }
            var fillID = 0
            if let colour = s.fillColour.flatMap({ SheetRGB(hex: $0) })?.hash {
                if let found = fills.firstIndex(of: colour) { fillID = found + 2 } else { fills.append(colour); fillID = fills.count + 1 }
            }
            let key = StyleKey(numFmt: formatID(code), font: fontID, fill: fillID, alignment: s.alignment, wrap: s.wrapsText)
            if let found = xfIndex[key] { return found }
            xfs.append(key)
            xfIndex[key] = xfs.count - 1
            return xfs.count - 1
        }
        func sharedString(_ text: String) -> Int {
            if let found = stringIndex[text] { return found }
            strings.append(text)
            stringIndex[text] = strings.count - 1
            return strings.count - 1
        }

        let names = sheetNames(workbook.sheets.map(\.name))
        var package = OfficePackage()
        var relationships: [OfficeRelationship] = []
        var sheetEntries = "", definedNames = ""
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1")] : workbook.sheets
        for (index, sheet) in sheets.enumerated() {
            let maxColumns = sheet.rows.map(\.count).max() ?? 0
            var data = "<sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                var cells = ""
                for (c, cell) in row.enumerated() {
                    let s = style(cell)
                    let ref = reference(row: r, column: c)
                    let sAttr = s > 0 ? " s=\"\(s)\"" : ""
                    let formula = keepFormulas ? cell.formula.map { "<f>\(XML.escape($0))</f>" } ?? "" : ""
                    switch cell.value {
                    case .empty:
                        if s > 0 || !formula.isEmpty { cells += "<c r=\"\(ref)\"\(sAttr)>\(formula)</c>" }
                    case .number(let n):
                        cells += n.isFinite ? "<c r=\"\(ref)\"\(sAttr)>\(formula)<v>\(n)</v></c>"
                            : "<c r=\"\(ref)\"\(sAttr) t=\"e\">\(formula)<v>#NUM!</v></c>"
                    case .text(let t):
                        if formula.isEmpty {
                            cells += "<c r=\"\(ref)\"\(sAttr) t=\"s\"><v>\(sharedString(t))</v></c>"
                        } else {
                            cells += "<c r=\"\(ref)\"\(sAttr) t=\"str\">\(formula)<v>\(XML.escape(t))</v></c>"
                        }
                    case .bool(let b):
                        cells += "<c r=\"\(ref)\"\(sAttr) t=\"b\">\(formula)<v>\(b ? 1 : 0)</v></c>"
                    case .date(let d):
                        cells += "<c r=\"\(ref)\"\(sAttr)>\(formula)<v>\(SheetNumberFormat.serial(from: d, date1904: false))</v></c>"
                    case .error(let e):
                        cells += "<c r=\"\(ref)\"\(sAttr) t=\"e\">\(formula)<v>\(XML.escape(e))</v></c>"
                    }
                }
                if !cells.isEmpty { data += "<row r=\"\(r + 1)\">\(cells)</row>" }
            }
            data += "</sheetData>"
            var xml = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            if maxColumns > 0, !sheet.rows.isEmpty {
                xml += "<dimension ref=\"A1:\(columnName(maxColumns - 1))\(sheet.rows.count)\"/>"
            }
            if !sheet.columnWidths.isEmpty {
                xml += "<cols>" + sheet.columnWidths.sorted { $0.key < $1.key }.map { column, width in
                    "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
                }.joined() + "</cols>"
            }
            xml += data
            if !sheet.merges.isEmpty {
                xml += "<mergeCells count=\"\(sheet.merges.count)\">" + sheet.merges.map {
                    "<mergeCell ref=\"\(reference(row: $0.firstRow, column: $0.firstColumn)):\(reference(row: $0.lastRow, column: $0.lastColumn))\"/>"
                }.joined() + "</mergeCells>"
            }
            xml += "</worksheet>"
            package.add("xl/worksheets/sheet\(index + 1).xml", xml: xml,
                        contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
            relationships.append(OfficeRelationship(id: "rId\(index + 1)", type: OfficeRelationship.worksheet, target: "worksheets/sheet\(index + 1).xml"))
            sheetEntries += "<sheet name=\"\(XML.escape(names[index]))\" sheetId=\"\(index + 1)\"\(sheet.isHidden ? " state=\"hidden\"" : "") r:id=\"rId\(index + 1)\"/>"
            if let area = sheet.printArea {
                let quoted = "'" + names[index].replacingOccurrences(of: "'", with: "''") + "'"
                definedNames += "<definedName name=\"_xlnm.Print_Area\" localSheetId=\"\(index)\">\(XML.escape(quoted))!"
                    + "$\(columnName(area.firstColumn))$\(area.firstRow + 1):$\(columnName(area.lastColumn))$\(area.lastRow + 1)</definedName>"
            }
        }
        package.add("xl/workbook.xml", xml: """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews>\
            <sheets>\(sheetEntries)</sheets>\(definedNames.isEmpty ? "" : "<definedNames>\(definedNames)</definedNames>")</workbook>
            """, contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")

        var styles = #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if !customFormats.isEmpty {
            styles += "<numFmts count=\"\(customFormats.count)\">" + customFormats.sorted { $0.value < $1.value }.map {
                "<numFmt numFmtId=\"\($0.value)\" formatCode=\"\(XML.escape($0.key))\"/>"
            }.joined() + "</numFmts>"
        }
        styles += "<fonts count=\"\(fonts.count)\">" + fonts.map { font in
            var xml = "<font>"
            if font.bold { xml += "<b/>" }
            if font.italic { xml += "<i/>" }
            xml += "<sz val=\"\(font.size ?? 11)\"/>"
            if let colour = font.colour.flatMap({ SheetRGB(hex: $0) }) { xml += "<color rgb=\"FF\(colour.hash.dropFirst())\"/>" }
            xml += "<name val=\"\(XML.escape(font.name ?? "Calibri"))\"/><family val=\"2\"/></font>"
            return xml
        }.joined() + "</fonts>"
        styles += "<fills count=\"\(fills.count + 2)\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
            + fills.map { "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\($0.dropFirst())\"/><bgColor indexed=\"64\"/></patternFill></fill>" }.joined()
            + "</fills>"
        styles += #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
        styles += #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        styles += "<cellXfs count=\"\(xfs.count)\">" + xfs.map { xf in
            var attributes = "numFmtId=\"\(xf.numFmt)\" fontId=\"\(xf.font)\" fillId=\"\(xf.fill)\" borderId=\"0\" xfId=\"0\""
            if xf.numFmt > 0 { attributes += " applyNumberFormat=\"1\"" }
            if xf.font > 0 { attributes += " applyFont=\"1\"" }
            if xf.fill > 0 { attributes += " applyFill=\"1\"" }
            var horizontal = ""
            switch xf.alignment {
            case .start?: horizontal = "left"
            case .centre?: horizontal = "center"
            case .end?: horizontal = "right"
            case .justified?: horizontal = "justify"
            case nil: break
            }
            guard !horizontal.isEmpty || xf.wrap else { return "<xf \(attributes)/>" }
            return "<xf \(attributes) applyAlignment=\"1\"><alignment\(horizontal.isEmpty ? "" : " horizontal=\"\(horizontal)\"")\(xf.wrap ? " wrapText=\"1\"" : "")/></xf>"
        }.joined() + "</cellXfs>"
        styles += #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#
        package.add("xl/styles.xml", xml: styles, contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml")
        relationships.append(OfficeRelationship(id: "rId\(sheets.count + 1)", type: OfficeRelationship.styles, target: "styles.xml"))

        package.add("xl/sharedStrings.xml", xml: "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
            + strings.map { "<si><t xml:space=\"preserve\">\(XML.escape($0))</t></si>" }.joined() + "</sst>",
            contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml")
        relationships.append(OfficeRelationship(id: "rId\(sheets.count + 2)", type: OfficeRelationship.sharedStrings, target: "sharedStrings.xml"))
        package.addRelationships("xl/_rels/workbook.xml.rels", relationships)
        package.addProperties(title: workbook.title ?? "", mainPart: "xl/workbook.xml")
        return package.finish()
    }
}
