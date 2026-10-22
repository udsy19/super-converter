import Foundation

public extension EngineID {
    /// The helpers this engine runs through (any one of them, for the DWG converter); empty for engines that need nothing
    /// installed. A route's `helpers` are the union of these over its helper chain.
    var helpers: [HelperID] {
        switch self {
        case .libreOffice: [.libreoffice]
        case .pages, .numbers, .keynote: [.iwork]
        case .calibre: [.calibre]
        case .pandoc: [.pandoc]
        case .tectonic: [.tectonic]
        case .ghostscript: [.ghostscript]
        case .djvuLibre: [.djvulibre]
        case .dwgConverter: [.oda, .libredwg]
        case .ffmpegGPL: [.ffmpegGPL]
        case .rar: [.rar]
        case .sfArk: [.sfark]
        default: []
        }
    }
}
