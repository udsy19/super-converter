import Foundation

/// Option profiles (formats §5) as data. Every pair in the matrix names one profile id; a profile is a base plus modifiers
/// (`O-IMG+Q+DPI`). Resolve with `OptionProfiles.profile(_:)`. The options sheet shows the first controls plainly and the
/// rest under "More options" (ux §5.5).
public enum OptionProfiles {
    /// Resolves "O-IMG+Q+DPI" or "O-WEB+O-DOC-PDF". Modifier options come first (they are the profile-specific controls),
    /// then the base's; a later definition of a key replaces an earlier one. Nil when a part is unknown.
    public static func profile(_ id: String) -> OptionProfile? {
        var result: [OptionDefinition] = []
        var base: String?
        var baseOptions: [[OptionDefinition]] = []
        var modifierOptions: [OptionDefinition] = []
        for part in id.split(separator: "+").map(String.init) {
            if part.hasPrefix("O-") {
                guard let defs = bases[part] else { return nil }
                base = part
                baseOptions.append(defs)
            } else {
                guard let base, let defs = modifiers["\(base)+\(part)"] else { return nil }
                modifierOptions += defs
            }
        }
        for definition in modifierOptions + baseOptions.flatMap({ $0 }) where !result.contains(where: { $0.key == definition.key }) {
            result.append(definition)
        }
        return base == nil ? nil : OptionProfile(id: id, options: result)
    }

    /// Every base id.
    public static var baseIDs: [String] { bases.keys.sorted() }

    // MARK: Shorthand

    private static func toggle(_ k: String, _ l: String, _ d: Bool, cc: String? = nil, t: String? = nil, more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .toggle, default: .bool(d), cc: cc, technical: t, more: more)
    }
    private static func choice(_ k: String, _ l: String, _ cs: [(String, String)], _ d: String, cc: String? = nil,
                               t: String? = nil, more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .choice(cs.map { OptionChoice($0.0, $0.1) }), default: .string(d), cc: cc, technical: t, more: more)
    }
    private static func int(_ k: String, _ l: String, _ r: ClosedRange<Int>, _ d: Int?, unit: String? = nil, cc: String? = nil,
                            t: String? = nil, more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .integer(r, unit: unit), default: d.map { .int($0) }, cc: cc, technical: t, more: more)
    }
    private static func number(_ k: String, _ l: String, _ r: ClosedRange<Double>, _ d: Double?, unit: String? = nil, cc: String? = nil,
                               t: String? = nil, more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .number(r, unit: unit), default: d.map { .double($0) }, cc: cc, technical: t, more: more)
    }
    private static func text(_ k: String, _ l: String, _ d: String? = nil, cc: String? = nil, t: String? = nil, more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .text, default: d.map { .string($0) }, cc: cc, technical: t, more: more)
    }
    private static func pages(_ k: String = "pages", _ l: String = "Pages", cc: String? = "pages", more: Bool = false) -> OptionDefinition {
        OptionDefinition(k, l, .pageRange, default: .string(""), cc: cc, technical: nil, more: more)
    }
    private static func password(cc: String? = "password") -> OptionDefinition {
        OptionDefinition("password", "Password to open", .secret, default: nil, cc: cc, technical: nil, more: true)
    }
    private static func colour(_ k: String, _ l: String, _ d: String, more: Bool = true) -> OptionDefinition {
        OptionDefinition(k, l, .colour, default: .string(d), cc: nil, technical: nil, more: more)
    }

    private static let profileChoices: [(String, String)] = [
        ("keep", "Keep"), ("srgb", "sRGB"), ("displayP3", "Display P3"), ("adobeRGB", "Adobe RGB (1998)"),
        ("proPhoto", "ProPhoto RGB"), ("gray", "Gray Gamma 2.2"), ("cmyk", "Generic CMYK"), ("custom", "Choose ICC…"),
    ]
    private static let paperChoices: [(String, String)] = [
        ("auto", "From this Mac’s region"), ("a4", "A4"), ("letter", "Letter"), ("legal", "Legal"), ("a5", "A5"),
        ("b5", "B5"), ("a3", "A3"), ("custom", "Custom"),
    ]

    private static let imageColour: [OptionDefinition] = [
        choice("colourProfile", "Colours", profileChoices, "keep", t: "ICC profile"),
        choice("renderingIntent", "Rendering intent", [("relative", "Relative colorimetric"), ("perceptual", "Perceptual")], "relative", more: true),
        choice("bitDepth", "Bit depth", [("keep", "Keep"), ("8", "8"), ("16", "16")], "keep", more: true),
    ]

    // MARK: Bases (formats §5)

    private static let bases: [String: [OptionDefinition]] = [
        "O-IMG": [
            choice("size", "Size", [("original", "Original"), ("50", "50%"), ("25", "25%"), ("custom", "Custom…")], "original", t: "width, height"),
            int("width", "Width", 1...100_000, nil, unit: "px", cc: "width", more: true),
            int("height", "Height", 1...100_000, nil, unit: "px", cc: "height", more: true),
            choice("fit", "Fit", [("max", "Fit inside"), ("crop", "Crop"), ("scale", "Stretch"), ("pad", "Pad")], "max", cc: "fit", more: true),
            colour("background", "Background", "#FFFFFF"),
        ] + imageColour + [
            choice("metadata", "Photo details", [("all", "Keep all"), ("allButLocation", "Keep all but location"), ("none", "Remove")], "all", cc: "strip", t: "EXIF, IPTC, XMP"),
            toggle("autoRotate", "Rotate to match the camera", true, cc: "auto_orient", t: "auto-orient", more: true),
            pages(),
            choice("rawWhiteBalance", "White balance (RAW)", [("asShot", "As shot"), ("auto", "Auto"), ("kelvin", "Kelvin")], "asShot", more: true),
            number("rawExposure", "Exposure (RAW)", -4...4, 0, unit: "EV", more: true),
            choice("rawLook", "Look (RAW)", [("apple", "Apple"), ("neutral", "Neutral")], "apple", more: true),
        ],
        "O-IMG-PDF": [
            choice("pageSize", "Page size", [("fit", "Fit image"), ("a4", "A4"), ("letter", "Letter")], "fit"),
            choice("margin", "Margin", [("0", "None"), ("10", "10 mm"), ("20", "20 mm")], "0", more: true),
            choice("orientation", "Orientation", [("auto", "Automatic"), ("portrait", "Portrait"), ("landscape", "Landscape")], "auto", more: true),
            toggle("combine", "Combine into one PDF", true),
            choice("colourProfile", "Colours", profileChoices, "keep", t: "ICC profile", more: true),
            choice("metadata", "Photo details", [("all", "Keep all"), ("allButLocation", "Keep all but location"), ("none", "Remove")], "all", more: true),
        ],
        "O-TRACE": [
            choice("preset", "Preset", [("auto", "Automatic"), ("bw", "Black and white"), ("poster", "Poster"), ("photo", "Photo")], "auto", cc: "preset"),
            number("colours", "Colours", 2...64, nil, t: "colours"),
            choice("mode", "Smoothness", [("spline", "Curves"), ("polygon", "Straight lines"), ("pixel", "Pixels")], "spline", cc: "mode", t: "curve fitting"),
            int("filterSpeckle", "Remove specks", 0...128, 4, unit: "px", cc: "filter_speckle", more: true),
            int("colourPrecision", "Colour precision", 1...8, 6, unit: "bits", cc: "color_precision", more: true),
            number("simplify", "Simplify", 0...10, nil, unit: "px", cc: "simplify", more: true),
        ],
        "O-VEC": [
            toggle("textToPath", "Turn text into shapes", false, cc: "text_to_path", t: "text to outlines"),
            pages("pages", "Pages", cc: nil),
            int("pixelDensity", "Render density", 36...2400, 96, unit: "dpi", cc: "pixel_density", more: true),
            int("width", "Width", 1...100_000, nil, unit: "px", cc: "width", more: true),
            int("height", "Height", 1...100_000, nil, unit: "px", cc: "height", more: true),
            choice("dxfUnits", "Units (DXF)", [("mm", "mm"), ("cm", "cm"), ("m", "m"), ("in", "in"), ("ft", "ft")], "mm", more: true),
            choice("dxfVersion", "AutoCAD version (DXF)", [("r12", "R12"), ("2000", "2000"), ("2010", "2010"), ("2018", "2018")], "2018", more: true),
            toggle("pdfA", "PDF/A", false, more: true),
            choice("epsPreview", "EPS preview", [("none", "None"), ("tiff", "TIFF")], "none", more: true),
        ],
        "O-RENDER": [
            int("pixelDensity", "Resolution", 36...1200, 300, unit: "dpi", cc: "pixel_density"),
            pages(),
            toggle("alpha", "Transparent background (PNG)", false, cc: "alpha"),
            int("quality", "Quality (JPG)", 1...100, 90, cc: "quality", more: true),
            int("width", "Width", 1...100_000, nil, unit: "px", cc: "width", more: true),
            int("height", "Height", 1...100_000, nil, unit: "px", cc: "height", more: true),
            choice("colourProfile", "Colours", [("srgb", "sRGB"), ("displayP3", "Display P3"), ("keep", "Keep")], "srgb", more: true),
        ],
        "O-DOC-PDF": [
            choice("look", "Look", [("original", "Original layout"), ("asWritten", "As written"), ("latex", "LaTeX")], "asWritten"),
            choice("paper", "Paper", paperChoices, "auto"),
            choice("baseSize", "Text size", [("10", "10 pt"), ("11", "11 pt"), ("12", "12 pt")], "10", t: "base size"),
            toggle("contents", "Contents page", false),
            choice("margins", "Margins", [("default", "LaTeX default"), ("narrow", "Narrow"), ("wide", "Wide"), ("custom", "Custom")], "default", more: true),
            choice("font", "Font", [("latinModern", "Latin Modern"), ("latinModernSans", "Latin Modern Sans"), ("own", "The document’s own")], "latinModern", more: true),
            choice("columns", "Columns", [("1", "One"), ("2", "Two")], "1", more: true),
            choice("numberedSections", "Numbered sections", [("auto", "Automatic"), ("on", "On"), ("off", "Off")], "auto", more: true),
            toggle("hyphenation", "Hyphenation", true, more: true),
            text("language", "Language", "auto", more: true),
            pages(more: true),
            choice("pdfA", "PDF/A", [("off", "Off"), ("1b", "PDF/A-1b"), ("2b", "PDF/A-2b")], "off", cc: "pdf_a", more: true),
            toggle("bookmarks", "Bookmarks from headings", true, cc: "bookmarks", more: true),
            toggle("includeMarkup", "Tracked changes and comments", false, cc: "include_markup", more: true),
            choice("optimise", "Optimise for", [("print", "Print"), ("screen", "Screen")], "print", cc: "optimize_print", more: true),
            password(),
        ],
        "O-WEB": [
            choice("pageFormat", "Page size", paperChoices, "auto", cc: "page_format"),
            choice("orientation", "Orientation", [("portrait", "Portrait"), ("landscape", "Landscape")], "portrait", cc: "page_orientation"),
            number("zoom", "Zoom", 0.1...5, 1, cc: "zoom", more: true),
            int("margin", "Margins", 0...100, 10, unit: "mm", cc: "margin_top", more: true),
            toggle("printBackground", "Print backgrounds", true, cc: "print_background", more: true),
            choice("cssMedia", "Style sheet", [("print", "Print"), ("screen", "Screen")], "print", cc: "css_media_type", more: true),
            toggle("headerFooter", "Header and footer", false, cc: "display_header_footer", more: true),
            text("headerTemplate", "Header template", cc: "header_template", more: true),
            text("footerTemplate", "Footer template", cc: "footer_template", more: true),
            choice("waitUntil", "Wait until", [("load", "Loaded"), ("domcontentloaded", "Content loaded"), ("networkidle0", "Network idle"), ("networkidle2", "Network almost idle")], "load", cc: "wait_until", more: true),
            text("waitForElement", "Wait for element", cc: "wait_for_element", more: true),
            int("waitTime", "Wait", 0...60_000, 0, unit: "ms", cc: "wait_time", more: true),
            pages(more: true),
            toggle("loadWebResources", "Load web resources", false, more: true),
        ],
        "O-WEB-SHOT": [
            int("screenWidth", "Screen width", 200...8000, 1440, unit: "px", cc: "screen_width"),
            int("scale", "Scale factor", 1...4, 2, cc: "device_scale_factor", more: true),
            int("quality", "Quality (JPG)", 1...100, 90, cc: "quality", more: true),
            choice("waitUntil", "Wait until", [("load", "Loaded"), ("networkidle0", "Network idle")], "load", cc: "wait_until", more: true),
            text("waitForElement", "Wait for element", cc: "wait_for_element", more: true),
            int("waitTime", "Wait", 0...60_000, 0, unit: "ms", cc: "wait_time", more: true),
            toggle("loadWebResources", "Load web resources", false, more: true),
        ],
        "O-DOC": [
            choice("markdownFlavour", "Markdown flavour", [("github", "GitHub"), ("strict", "CommonMark"), ("pandoc", "Pandoc"), ("mmd", "MultiMarkdown")], "github", cc: "output_markdown_syntax"),
            toggle("embedImages", "Embed pictures in the web page", true, cc: "embed_images"),
            choice("trackedChanges", "Tracked changes", [("accept", "Accept"), ("reject", "Reject"), ("keep", "Keep as markup")], "accept", more: true),
            choice("latexClass", "LaTeX class", [("article", "Article"), ("report", "Report"), ("book", "Book")], "article", more: true),
            choice("lineEndings", "Line endings", [("lf", "LF"), ("crlf", "CRLF")], "lf", more: true),
            text("encoding", "Text encoding", "UTF-8", more: true),
            password(),
        ],
        "O-PDF-OFFICE": [
            pages(),
            toggle("ocr", "Recognise text in scans", true, cc: "images_ocr"),
            toggle("connectHyphens", "Join hyphenated words", true, cc: "connect_hyphens", more: true),
            toggle("visualAppearance", "Look over editability", false, cc: "prioritize_visual_appearance", more: true),
            password(),
        ],
        "O-PDF-SHEET": [
            pages(),
            toggle("ocr", "Recognise text in scans", true, cc: "images_ocr"),
            toggle("nonTableContent", "Text outside tables", false, cc: "non_table_content"),
            toggle("singleSheet", "All tables on one sheet", false, cc: "single_sheet", more: true),
            password(),
        ],
        "O-PDF-HTML": [
            choice("mode", "Mode", [("reflow", "Reflow"), ("positioned", "Positioned")], "reflow"),
            pages(),
            toggle("embedFonts", "Embed fonts", true, cc: "embed_fonts", more: true),
            toggle("embedImages", "Embed pictures", true, cc: "embed_images", more: true),
            toggle("splitPages", "One file per page", false, cc: "split_pages", more: true),
            number("zoom", "Zoom", 0.1...5, 1.5, cc: "zoom", more: true),
            password(),
        ],
        "O-PDF-TXT": [
            choice("layout", "Layout", [("reading", "Reading order"), ("page", "As on the page")], "reading"),
            pages(),
            toggle("ocr", "Recognise text in scans", true, cc: "images_ocr"),
            password(),
        ],
        "O-PDF-PDF": [
            pages(),
            toggle("splitPages", "Split into one file per page", false, cc: "split_pages"),
            choice("encryption", "Password", [("unchanged", "Unchanged"), ("remove", "Remove"), ("encrypt", "Add")], "unchanged", cc: "encryption"),
            text("setPassword", "New password", cc: "set_password", more: true),
            text("setOwnerPassword", "Owner password", cc: "set_owner_password", more: true),
            choice("allowPrint", "Allow printing", [("full", "Full"), ("low", "Low quality"), ("none", "None")], "full", cc: "allow_print", more: true),
            choice("allowModify", "Allow changes", [("all", "All"), ("annotate", "Comments"), ("form", "Forms"), ("assembly", "Page assembly"), ("none", "None")], "all", cc: "allow_modify", more: true),
            toggle("allowExtract", "Allow copying", true, cc: "allow_extract", more: true),
            toggle("allowAccessibility", "Allow accessibility tools", true, cc: "allow_accessibility", more: true),
            OptionDefinition("watermarkImage", "Watermark (PDF)", .file(extensions: ["pdf"]), default: nil, cc: "watermark_image", technical: nil, more: true),
            choice("watermarkLayer", "Watermark position", [("above", "Above"), ("below", "Below")], "above", cc: "watermark_layer", more: true),
            toggle("pdfA", "PDF/A-2b", false, more: true),
            choice("makeSmaller", "Make smaller", [("off", "Off"), ("300", "300 dpi pictures"), ("150", "150 dpi pictures")], "off", more: true),
            toggle("removeMetadata", "Remove metadata", false, more: true),
            password(),
        ],
        "O-TEX": [
            choice("engine", "Engine", [("xetex", "XeTeX"), ("pdflatex", "pdfLaTeX"), ("lualatex", "LuaLaTeX")], "xetex"),
            int("reruns", "Reruns", 1...5, 5, more: true),
            toggle("bibliography", "Bibliography", true, more: true),
        ],
        "O-SHEET-PDF": [
            choice("look", "Look", [("original", "Original"), ("grid", "Grid as laid out"), ("latex", "LaTeX")], "grid"),
            text("sheet", "Sheets", "all", cc: "sheet"),
            int("pagesFitWide", "Fit to pages wide", 1...50, 1, cc: "pages_fit_wide"),
            int("pagesFitTall", "Fit to pages tall", 0...50, nil, cc: "pages_fit_tall", more: true),
            toggle("usePrintAreas", "Print areas", false, cc: "use_print_areas", more: true),
            toggle("gridlines", "Gridlines", false, more: true),
            choice("orientation", "Orientation", [("auto", "Automatic"), ("portrait", "Portrait"), ("landscape", "Landscape")], "auto", more: true),
            choice("paper", "Paper", paperChoices, "auto", more: true),
            text("decimalSeparator", "Decimal separator", cc: "decimal_separator", more: true),
            text("thousandsSeparator", "Thousands separator", cc: "thousands_separator", more: true),
            password(),
        ],
        "O-SHEET-OUT": [
            text("sheet", "Sheets", "all", cc: "sheet"),
            choice("formulas", "Formulas", [("keep", "Keep"), ("values", "Values only")], "values", more: true),
            password(),
        ],
        "O-CSV": [
            choice("delimiter", "Separator", [("comma", "Comma"), ("semicolon", "Semicolon"), ("tab", "Tab")], "comma"),
            choice("encoding", "Encoding", [("utf8", "UTF-8"), ("utf8bom", "UTF-8 for Excel"), ("utf16", "UTF-16")], "utf8"),
            choice("values", "Values", [("displayed", "As displayed"), ("raw", "Raw")], "displayed", more: true),
            toggle("onePerSheet", "One file per sheet", true, more: true),
            text("sheet", "Sheets", "all", cc: "sheet", more: true),
            text("decimalSeparator", "Decimal separator", cc: "decimal_separator", more: true),
            password(),
        ],
        "O-DECK": [
            choice("output", "Slides or handouts", [("slides", "Slides"), ("handout", "Handout")], "slides", cc: "output_type"),
            choice("notes", "Speaker notes", [("off", "Off"), ("notesPages", "Notes pages")], "off"),
            toggle("hiddenSlides", "Hidden slides", false, cc: "hidden_slides", more: true),
            int("slidesPerHandout", "Slides per handout page", 1...12, 6, cc: "slides_per_handout_page", more: true),
            int("firstSlideNumber", "First slide number", 0...9999, 1, cc: "first_slide_number", more: true),
            pages(more: true),
            password(),
        ],
        "O-DECK-VIDEO": [
            number("secondsPerSlide", "Seconds per slide", 1...60, 5),
            choice("size", "Size", [("1080", "1920 × 1080"), ("720", "1280 × 720")], "1080"),
            number("fps", "Frame rate", 1...60, 30, unit: "fps", more: true),
        ],
        "O-EBOOK": [
            choice("epubVersion", "EPUB version", [("3", "3"), ("2", "2")], "3"),
            choice("cover", "Cover", [("keep", "Keep"), ("generate", "Make one when missing")], "keep", more: true),
            toggle("contents", "Table of contents", true, more: true),
            choice("embedFonts", "Embed fonts", [("subset", "Used glyphs"), ("none", "None")], "subset", more: true),
            text("title", "Title", more: true),
            text("author", "Author", more: true),
            text("language", "Language", more: true),
            choice("deviceProfile", "Device (calibre)", [("kindle", "Kindle"), ("generic", "Generic e-ink")], "kindle", t: "output profile", more: true),
            choice("mobiType", "MOBI type", [("both", "Both"), ("old", "Old"), ("new", "KF8")], "both", more: true),
        ],
        "O-EBOOK-PDF": [
            choice("trimSize", "Page size", [("a5", "A5"), ("6x9", "6 × 9 in"), ("a4", "A4"), ("letter", "Letter")], "a5", t: "trim size"),
            choice("baseSize", "Text size", [("10", "10 pt"), ("11", "11 pt")], "10", t: "base size"),
            toggle("contents", "Contents page", false, more: true),
            toggle("twoSided", "Two-sided", false, more: true),
        ],
        "O-COMIC": [
            choice("direction", "Reading direction", [("ltr", "Left to right"), ("rtl", "Right to left")], "ltr"),
        ],
        "O-ARCHIVE": [
            choice("compression", "Compression", [("fast", "Fast"), ("normal", "Normal"), ("smallest", "Smallest")], "normal"),
            OptionDefinition("newPassword", "Password for the new archive", .secret, default: nil, cc: nil, technical: nil, more: false),
            choice("split", "Split into parts", [("off", "Off"), ("100", "100 MB"), ("700", "700 MB"), ("4096", "4 GB")], "off", more: true),
            toggle("keepMacExtras", "Keep Mac extras", false, more: true),
            toggle("unpackPayload", "Unpack package payload", true, more: true),
            choice("nameEncoding", "File-name encoding", [("auto", "Automatic"), ("cp437", "CP437"), ("shiftJIS", "Shift-JIS"), ("gbk", "GBK"), ("eucKR", "EUC-KR")], "auto", more: true),
            toggle("compatibleZip", "Compatible ZIP password (ZipCrypto)", false, more: true),
            password(),
        ],
        "O-VIDEO": [
            int("quality", "Smaller file ↔ Best quality", 0...51, 20, cc: "crf", t: "CRF"),
            choice("size", "Size", [("original", "Original"), ("2160", "2160p"), ("1080", "1080p"), ("720", "720p"), ("480", "480p"), ("custom", "Custom…")], "original", t: "width, height"),
            number("fps", "Frame rate", 1...240, nil, unit: "fps", cc: "fps"),
            choice("sound", "Sound", [("keep", "Keep"), ("none", "Remove")], "keep"),
            choice("videoCodec", "Video codec", [("auto", "Automatic"), ("copy", "Keep the stream"), ("h264", "H.264"), ("hevc", "HEVC"), ("prores", "ProRes"), ("vp8", "VP8"), ("vp9", "VP9"), ("av1", "AV1")], "auto", cc: "video_codec", more: true),
            choice("speed", "Speed", [("fast", "Fast"), ("medium", "Balanced"), ("slow", "Best")], "medium", cc: "preset", more: true),
            choice("fit", "Fit", [("max", "Fit inside"), ("crop", "Crop"), ("scale", "Stretch"), ("pad", "Pad")], "max", cc: "fit", more: true),
            int("keyframeInterval", "Keyframe interval", 1...1000, nil, unit: "frames", cc: "keyframe_interval", more: true),
            text("aspectRatio", "Aspect ratio", cc: "aspect_ratio", more: true),
            choice("audioCodec", "Audio codec", [("auto", "Automatic"), ("copy", "Keep the stream"), ("aac", "AAC"), ("opus", "Opus"), ("vorbis", "Vorbis"), ("mp3", "MP3"), ("ac3", "AC-3")], "auto", cc: "audio_codec", more: true),
            int("audioBitrate", "Audio bitrate", 32...512, 192, unit: "kb/s", cc: "audio_bitrate", more: true),
            toggle("allAudioStreams", "All audio tracks", false, cc: "all_audio_streams", more: true),
            text("trimStart", "Start at", cc: "trim_start", more: true),
            text("trimEnd", "End at", cc: "trim_end", more: true),
            choice("subtitles", "Subtitles", [("copy", "Keep"), ("none", "None"), ("soft", "Soft"), ("hard", "Burned in")], "copy", cc: "subtitles_mode", more: true),
            OptionDefinition("watermarkImage", "Watermark (PNG)", .file(extensions: ["png"]), default: nil, cc: "watermark_image", technical: nil, more: true),
            choice("hdr", "HDR", [("keep", "Keep when possible"), ("sdr", "Convert to standard range")], "keep", more: true),
            choice("deinterlace", "Deinterlace", [("auto", "Automatic"), ("off", "Off")], "auto", more: true),
            toggle("webReady", "Ready for the web", true, more: true),
            toggle("hardwareEncoding", "Use the Mac’s encoder", true, more: true),
            int("qscale", "Old-codec quality", 1...31, 3, cc: "qscale", more: true),
        ],
        "O-ANIM": [
            int("width", "Width", 16...8000, 800, unit: "px", cc: "width"),
            number("fps", "Frame rate", 1...60, 15, unit: "fps", cc: "fps"),
            int("colours", "Colours", 2...256, 256, more: true),
            choice("dither", "Dither", [("sierra2_4a", "Smooth"), ("bayer", "Ordered"), ("none", "None")], "sierra2_4a", more: true),
            choice("loop", "Loop", [("forever", "Forever"), ("once", "Once")], "forever", more: true),
            int("lossy", "WebP quality", 1...100, 80, more: true),
            text("trimStart", "Start at", cc: "trim_start", more: true),
            text("trimEnd", "End at", cc: "trim_end", more: true),
            choice("fit", "Fit", [("max", "Fit inside"), ("crop", "Crop"), ("scale", "Stretch"), ("pad", "Pad")], "max", cc: "fit", more: true),
        ],
        "O-AUDIO": [
            int("bitrate", "Smaller file ↔ Best quality", 32...512, 192, unit: "kb/s", cc: "audio_bitrate", t: "bitrate"),
            choice("channels", "Channels", [("source", "Same as the original"), ("1", "Mono"), ("2", "Stereo")], "source", cc: "channels"),
            choice("sampleRate", "Sample rate", [("source", "Same as the original"), ("22050", "22.05 kHz"), ("44100", "44.1 kHz"), ("48000", "48 kHz"), ("96000", "96 kHz")], "source", cc: "sample_rate"),
            choice("loudness", "Loudness", [("off", "Off"), ("-14", "−14 LUFS"), ("-16", "−16 LUFS"), ("-23", "−23 LUFS")], "off"),
            choice("codec", "Codec", [("auto", "Automatic")], "auto", cc: "audio_codec", more: true),
            int("mp3Quality", "MP3 quality (VBR)", 0...9, 0, cc: "audio_qscale", more: true),
            number("volume", "Volume", 0...4, 1, cc: "volume", more: true),
            choice("bitDepth", "Bit depth", [("source", "Same as the original"), ("16", "16"), ("24", "24"), ("32f", "32-bit float")], "source", more: true),
            int("flacLevel", "FLAC level", 0...12, 8, more: true),
            toggle("keepArtwork", "Keep artwork and chapters", true, more: true),
            text("trimStart", "Start at", cc: "trim_start", more: true),
            text("trimEnd", "End at", cc: "trim_end", more: true),
        ],
        "O-CAD": [
            toggle("allLayouts", "All layouts", false, cc: "all_layouts"),
            toggle("autoZoom", "Zoom to the drawing", true, cc: "auto_zoom", t: "zoom to extents"),
            choice("paper", "Paper", [("fit", "Fit drawing"), ("a4", "A4"), ("a3", "A3"), ("a2", "A2"), ("a1", "A1"), ("a0", "A0"), ("letter", "Letter")], "fit", more: true),
            choice("colours", "Colours", [("drawn", "As drawn"), ("mono", "Black and white")], "drawn", more: true),
            colour("background", "Background", "#FFFFFF"),
            choice("lineWeights", "Line weights", [("drawn", "As drawn"), ("thin", "Thin")], "drawn", more: true),
        ],
        "O-CAD-DWG": [
            choice("version", "AutoCAD version", [("9", "R9"), ("12", "R12"), ("14", "R14"), ("2000", "2000"), ("2004", "2004"), ("2007", "2007"), ("2010", "2010"), ("2013", "2013"), ("2018", "2018")], "2018", cc: "autocad_version"),
            toggle("allLayouts", "All layouts", false, cc: "all_layouts", more: true),
        ],
        "O-FONT": [
            choice("subset", "Subset", [("off", "Off"), ("latin", "Latin"), ("custom", "Custom text")], "off"),
            toggle("hinting", "Keep hinting", true, more: true),
            number("curveTolerance", "Curve tolerance", 0.1...5, 1, unit: "‰ em", more: true),
            toggle("verticalMetricsFix", "Fix vertical metrics", false, more: true),
        ],
        "O-SF2": [
            choice("sampleFormat", "Sample format", [("wav", "As stored (WAV)"), ("flac", "FLAC")], "wav"),
            toggle("sfzMap", "SFZ map", true, more: true),
            toggle("folders", "Folders per preset", true, more: true),
        ],
    ]

    // MARK: Modifiers, keyed "<base>+<modifier>"

    private static let modifiers: [String: [OptionDefinition]] = [
        "O-IMG+Q": [
            int("quality", "Smaller file ↔ Best quality", 1...100, 90, cc: "quality", t: "quality"),
            toggle("lossless", "Lossless", false, more: true),
            choice("chroma", "Chroma", [("420", "4:2:0"), ("444", "4:4:4")], "444", more: true),
            toggle("progressive", "Progressive (JPG)", true, more: true),
        ],
        "O-IMG+GIF": [
            int("colours", "Colours", 2...256, 256),
            choice("dither", "Dither", [("floydSteinberg", "Floyd–Steinberg"), ("ordered", "Ordered"), ("none", "None")], "floydSteinberg", more: true),
            choice("loop", "Loop", [("forever", "Forever"), ("once", "Once")], "forever", more: true),
        ],
        "O-IMG+ICON": [
            text("sizes", "Sizes", "all"),
        ],
        "O-IMG+TIFF": [
            choice("compression", "Compression", [("lzw", "LZW"), ("zip", "ZIP"), ("none", "None"), ("jpeg", "JPEG")], "lzw"),
            toggle("multiPage", "Multi-page", true, more: true),
        ],
        "O-IMG+PS": [
            choice("level", "PostScript level", [("3", "3"), ("2", "2")], "3"),
            choice("encoding", "Encoding", [("flate", "Flate"), ("jpeg", "JPEG")], "flate", more: true),
            choice("preview", "Preview", [("none", "None"), ("tiff", "TIFF")], "none", more: true),
        ],
        "O-IMG+DPI": [
            int("pixelDensity", "Render density", 36...2400, 96, unit: "dpi", cc: "pixel_density"),
        ],
        "O-RENDER+SHEET": [
            text("sheet", "Sheets", "all", cc: "sheet", more: true),
            int("pagesFitWide", "Fit to pages wide", 1...50, 1, cc: "pages_fit_wide", more: true),
            toggle("usePrintAreas", "Print areas", false, cc: "use_print_areas", more: true),
        ],
        "O-DOC-PDF+TXT": [
            choice("treatAs", "Treat as", [("auto", "Automatic"), ("prose", "Prose"), ("code", "Code")], "auto"),
            text("encoding", "Text encoding", "auto", more: true),
            int("tabWidth", "Tab width", 2...8, 8, more: true),
        ],
        "O-DOC+MD": [
            choice("markdownInput", "Markdown flavour (input)", [("auto", "Automatic"), ("github", "GitHub"), ("strict", "CommonMark"), ("pandoc", "Pandoc"), ("mmd", "MultiMarkdown")], "auto", cc: "input_markdown_syntax", more: true),
            choice("wrap", "Wrap lines", [("none", "No"), ("80", "At 80")], "none", more: true),
        ],
        "O-DECK+IMG": [
            int("pixelDensity", "Resolution", 36...1200, 300, unit: "dpi", cc: "pixel_density"),
            int("quality", "Quality (JPG)", 1...100, 90, cc: "quality", more: true),
            int("width", "Width", 1...100_000, nil, unit: "px", cc: "width", more: true),
            int("height", "Height", 1...100_000, nil, unit: "px", cc: "height", more: true),
        ],
        "O-CAD+IMG": [
            int("width", "Size", 100...20_000, 3000, unit: "px", cc: "width"),
            int("quality", "Quality (JPG)", 1...100, 90, more: true),
        ],
    ]

    /// Modifiers that exist for a base, for tests.
    static var modifierKeys: [String] { modifiers.keys.sorted() }
}
