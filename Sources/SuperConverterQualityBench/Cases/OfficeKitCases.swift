import Foundation
import SuperConverterCore

/// OfficeKit (quality §4): spreadsheets as displayed, XLSX ↔ CSV ↔ XLSX value round trips, ODF, and the PDF → PPTX/XLSX writers.
enum OfficeKitCases {
    static let all: [BenchCase] = [
        // Values as displayed: the totals are formulas, so their cached values must come through.
        BenchCase(id: "officekit.xlsx-csv", category: .spreadsheet, fixture: "generated/sample.xlsx", target: "csv", checks: [
            .producesFormat("csv"), .textContains(["Name,Quantity,Price,Total", "Widget,12,3.5,42", "Gadget,7,12.25,85.75", "Gizmo,150,0.99,148.5"]),
        ]),
        // CSV → XLSX → CSV: the same cells come back.
        BenchCase(id: "officekit.csv-xlsx", category: .spreadsheet, fixture: "generated/sample.csv", target: "xlsx", checks: [
            .producesFormat("xlsx"), .zipEntryContains("xl/sharedStrings.xml", ["Widget", "Quoted, with comma", "Gizmo"]), .equivalentAfter(converting: "csv"),
        ]),
        BenchCase(id: "officekit.xlsx-ods", category: .spreadsheet, fixture: "generated/sample.xlsx", target: "ods", checks: [
            .producesFormat("ods"), .zipEntryContains("content.xml", ["Widget", "148.5", "Sales"]), .equivalentAfter(converting: "csv"),
        ]),
        BenchCase(id: "officekit.xlsx-html", category: .spreadsheet, tier: .full, fixture: "generated/sample.xlsx", target: "html", checks: [
            .producesFormat("html"), .textContains(["<table", "Widget", "85.75"]),
        ]),
        BenchCase(id: "officekit.csv-html", category: .spreadsheet, tier: .full, fixture: "generated/sample.csv", target: "html", checks: [
            .producesFormat("html"), .textContains(["<table", "Quoted, with comma", "Gizmo"]),
        ]),
        // The PDF → Deck and PDF → Workbook writers (LayoutKit analyses, OfficeKit writes).
        BenchCase(id: "officekit.pdf-pptx", category: .presentation, fixture: "generated/sample.pdf", target: "pptx", checks: [
            .producesFormat("pptx"), .zipHasEntries(["ppt/presentation.xml", "ppt/slides/slide1.xml"]), .zipEntryContains("ppt/slides/slide1.xml", ["Super Converter sample"]),
        ]),
        BenchCase(id: "officekit.pdf-xlsx", category: .spreadsheet, fixture: "generated/sample.pdf", target: "xlsx", checks: [
            .producesFormat("xlsx"), .zipEntryContains("xl/sharedStrings.xml", ["Widget", "Gizmo", "Quantity"]),
        ]),
    ]
}
