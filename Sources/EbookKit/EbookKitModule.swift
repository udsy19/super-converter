import SuperConverterCore

/// EbookKit: Publication readers and writers (ARCHITECTURE §3). An engine: it carries no app policy and registers its
/// converters in `install()`.
///
/// Formats calibre alone can read or write (AZW, AZW3, AZW4, LIT, LRF, MOBI, PDB, PML, PRC, RB, SNB, TCR) are not handled
/// here: calibre is GPL, an optional external helper that HelperKit runs (`ebook-convert`, ARCHITECTURE §7). Those routes
/// meet this module at EPUB: a calibre step leaves an `.epub` in the work folder that `EPUBReader` reads, or takes the `.epub`
/// that `EbookKit` writes.
public enum EbookKitModule {
    /// The converters this module offers. `extractor` unpacks archives EbookKit cannot open itself (RAR comics, CHM); the app
    /// passes ArchiveKit's (libarchive / 7zz). Without one, CHM is reported unavailable and RAR comics fail with a clear message.
    public static func converters(extractor: ArchiveExtractor? = nil) -> [any Converter] {
        [
            PublicationReaderConverter(id: .epubReader, formats: ["epub"], needsExtractor: false, extractor: nil) { url, context, _ in
                try EPUBReader.read(url: url) { context.report(StepProgress(fraction: $0, unit: "Reading the book")) }
            },
            PublicationReaderConverter(id: .oebReader, formats: ["oeb"], needsExtractor: false, extractor: nil) { url, context, _ in
                try OEBReader.read(url: url) { context.report(StepProgress(fraction: $0, unit: "Reading the book")) }
            },
            PublicationReaderConverter(id: .fb2Reader, formats: ["fb2"], needsExtractor: false, extractor: nil) { url, context, _ in
                try FB2Reader.read(url: url) { context.report(StepProgress(fraction: $0, unit: "Reading the book")) }
            },
            PublicationReaderConverter(id: .htmlzReader, formats: ["htmlz"], needsExtractor: false, extractor: nil) { url, _, _ in
                try HTMLZReader.read(url: url)
            },
            PublicationReaderConverter(id: .txtzReader, formats: ["txtz"], needsExtractor: false, extractor: nil) { url, _, _ in
                try TXTZReader.read(url: url)
            },
            PublicationReaderConverter(id: .comicReader, formats: ["cbz", "cbr", "cbc"], needsExtractor: false, extractor: extractor) { url, context, extractor in
                try await ComicReader.read(url: url, format: context.sourceFormat, workFolder: context.workFolder, extractor: extractor) {
                    context.report(StepProgress(fraction: $0, unit: "Reading the pages"))
                }
            },
            PublicationReaderConverter(id: .chmReader, formats: ["chm"], needsExtractor: true, extractor: extractor) { url, context, extractor in
                try await CHMReader.read(url: url, workFolder: context.workFolder, extractor: extractor) {
                    context.report(StepProgress(fraction: $0, unit: "Reading the book"))
                }
            },
            EbookKitConverter(),
        ]
    }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install(extractor: ArchiveExtractor? = nil) {
        for converter in converters(extractor: extractor) { Services.converters.register(converter) }
    }
}
