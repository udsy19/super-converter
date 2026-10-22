import Foundation
import SuperConverterCore

// sconv <files…> --to jpg [--option quality=90] [--out DIR] [--list-targets]  (ARCHITECTURE §3; WP-P implements it)
let usage = "usage: sconv <files…> --to <format> [--option key=value] [--out DIR] [--list-targets]\n"
FileHandle.standardError.write(Data(usage.utf8))
exit(64)
