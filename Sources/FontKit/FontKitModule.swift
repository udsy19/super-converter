import SuperConverterCore

/// FontKit: SFNT, CFF, WOFF, WOFF2, EOT and SVG-font readers and writers (ARCHITECTURE §3). An engine: it carries no app
/// policy and registers its converters in `install()`.
///
/// Every route goes reader → `FontModel` → writer (formats §6.11). `SFNTReader`, `WOFFReader`, `WOFF2Reader`, `EOTReader` and
/// `SVGFontReader` produce the model; `GlyfBuilder` (TrueType outlines, cubic → quadratic through cu2qu), `CFFBuilder`
/// (PostScript outlines, quadratic → cubic exactly), `WOFFWriter`, `WOFF2Writer`, `EOTWriter` and `SVGFontWriter` write it.
public enum FontKitModule {
    /// The converters this module offers.
    public static func converters() -> [any Converter] {
        [
            FontReaderConverter(id: .sfntReader, formats: ["ttf", "otf"]) { try SFNTReader.read($0) },
            FontReaderConverter(id: .woffReader, formats: ["woff"]) { try SFNTReader.read(tables: WOFF.read($0).tables) },
            FontReaderConverter(id: .woff2Reader, formats: ["woff2"]) { try SFNTReader.read(try WOFF2Format.toSFNT($0)) },
            FontReaderConverter(id: .eotReader, formats: ["eot"]) { try SFNTReader.read(try EOT.read($0)) },
            FontReaderConverter(id: .svgFontReader, formats: ["svg"]) { try SVGFont.read($0) },

            FontWriterConverter(id: .glyfBuilder, format: "ttf", outlines: .quadratic) { model, options in
                try SFNTWriter.serialize(model, options: options.writerOptions)
            },
            FontWriterConverter(id: .cffBuilder, format: "otf", outlines: .cubic) { model, options in
                try SFNTWriter.serialize(model, options: options.writerOptions)
            },
            FontWriterConverter(id: .woffWriter, format: "woff", outlines: nil) { model, options in
                WOFF.write(try SFNTWriter.build(model, options: options.writerOptions))
            },
            FontWriterConverter(id: .woff2Writer, format: "woff2", outlines: nil) { model, options in
                try WOFF2Format.fromSFNT(try SFNTWriter.serialize(model, options: options.writerOptions))
            },
            FontWriterConverter(id: .eotWriter, format: "eot", outlines: nil) { model, options in
                let built = try SFNTWriter.build(model, options: options.writerOptions)
                let dictionary = Dictionary(uniqueKeysWithValues: built.tables)
                return try EOT.write(sfnt: SFNTContainer.serialize(flavor: built.flavor, tables: built.tables), tables: dictionary,
                                     names: dictionary["name"].map(NameTable.strings) ?? [:])
            },
            FontWriterConverter(id: .svgFontWriter, format: "svg", outlines: nil) { model, _ in SVGFont.write(model) },
        ]
    }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in converters() { Services.converters.register(converter) }
    }
}
