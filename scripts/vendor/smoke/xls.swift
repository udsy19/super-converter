// Links XLS.xcframework and reads a BIFF8 workbook written by xlwt (fixture.xls): two sheets, text, numbers, UTF-8.
import Foundation
import XLS

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

let path = CommandLine.arguments[1] + "/fixture.xls"
var error = LIBXLS_OK
guard let book = xls_open_file(path, "UTF-8", &error), error == LIBXLS_OK else {
    check(false, "open \(path): \(String(cString: xls_getError(error)))"); exit(1)
}
check(book.pointee.sheets.count == 2, "sheet count \(book.pointee.sheets.count)")
check(String(cString: book.pointee.sheets.sheet[0].name) == "Data", "first sheet name")

func text(_ sheet: UnsafeMutablePointer<xlsWorkSheet>, _ row: UInt16, _ col: UInt16) -> String? {
    guard let cell = xls_cell(sheet, row, col), let str = cell.pointee.str else { return nil }
    return String(cString: str)
}

let data = xls_getWorkSheet(book, 0)!
check(xls_parseWorkSheet(data) == LIBXLS_OK, "parse sheet 0")
check(text(data, 0, 0) == "Hello", "A1 = \(text(data, 0, 0) ?? "nil")")
check(text(data, 1, 0) == "World", "A2")
check(xls_cell(data, 0, 1).pointee.d == 42, "B1 = \(xls_cell(data, 0, 1).pointee.d)")
check(xls_cell(data, 1, 1).pointee.d == 3.5, "B2")
let second = xls_getWorkSheet(book, 1)!
check(xls_parseWorkSheet(second) == LIBXLS_OK, "parse sheet 1")
check(text(second, 0, 0) == "Caf\u{e9} \u{fc}ber", "UTF-8 cell = \(text(second, 0, 0) ?? "nil")")
xls_close_WS(data)
xls_close_WS(second)
xls_close_WB(book)
print("libxls \(String(cString: xls_getVersion())): 2 sheets, text, numbers, UTF-8 OK")
