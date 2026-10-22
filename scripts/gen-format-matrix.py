#!/usr/bin/env python3
"""Generate Super Converter's format matrix.

Reads the CloudConvert parity snapshot (docs/specs/data/cloudconvert-*.json), adds the formats CloudConvert lists but
does not convert, routes every (input, output) pair through Super Converter's own engines, and writes:

  docs/specs/data/format-matrix.json   machine-readable matrix (the source for SuperConverterCore's catalog, WP1)
  docs/specs/formats.md                the section between the GENERATED markers

Usage:  python3 -I scripts/gen-format-matrix.py          (from the repository root; no third-party modules)

Routing rules live here, not in prose: change a rule, re-run, commit both files. Engine ids, helper ids and option
profile ids are defined in docs/specs/formats.md (sections 3-5); this script only refers to them.
"""
import json
import os
import sys
from collections import OrderedDict, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT = os.path.join(ROOT, "docs/specs/data/cloudconvert-2026-10-22.json")
OUT_JSON = os.path.join(ROOT, "docs/specs/data/format-matrix.json")
OUT_MD = os.path.join(ROOT, "docs/specs/formats.md")
BEGIN = "<!-- BEGIN GENERATED MATRIX (scripts/gen-format-matrix.py) -->"
END = "<!-- END GENERATED MATRIX -->"

# ---------------------------------------------------------------------------------------------------------------------
# 1. The 212 formats CloudConvert lists, by category (read from its Format Catalog, 2026-10-22), with our names.
# ---------------------------------------------------------------------------------------------------------------------
CATEGORIES = OrderedDict([
    ("document", ("Documents", [
        ("abw", "AbiWord document"), ("djvu", "DjVu document"), ("doc", "Word 97–2003 document"),
        ("docm", "Word macro-enabled document"), ("docx", "Word document"), ("dot", "Word 97–2003 template"),
        ("dotx", "Word template"), ("html", "Web page (HTML)"), ("hwp", "Hangul (HWP) document"),
        ("hwpx", "Hangul OWPML document (HWPX)"), ("lwp", "Lotus Word Pro document"), ("md", "Markdown"),
        ("odt", "OpenDocument text"), ("pages", "Apple Pages document"), ("pdf", "PDF"),
        ("rst", "reStructuredText"), ("rtf", "Rich Text Format"), ("sdw", "StarOffice Writer document"),
        ("tex", "LaTeX source"), ("txt", "Plain text"), ("wpd", "WordPerfect document"),
        ("wps", "Works / WPS Writer document"), ("zabw", "Compressed AbiWord document")])),
    ("image", ("Images", [
        ("3fr", "Hasselblad RAW"), ("arw", "Sony RAW"), ("avif", "AVIF (AV1 image)"), ("bmp", "Windows bitmap"),
        ("cr2", "Canon RAW 2"), ("cr3", "Canon RAW 3"), ("crw", "Canon RAW (CIFF)"), ("dcr", "Kodak RAW"),
        ("dng", "Adobe Digital Negative"), ("eps", "Encapsulated PostScript"), ("erf", "Epson RAW"),
        ("gif", "GIF"), ("heic", "HEIC"), ("heif", "HEIF"), ("icns", "Apple icon"), ("ico", "Windows icon"),
        ("jfif", "JPEG (JFIF)"), ("jpeg", "JPEG"), ("jpg", "JPEG"), ("mos", "Leaf RAW"), ("mrw", "Minolta RAW"),
        ("nef", "Nikon RAW"), ("odd", "OpenDocument drawing (legacy .odd)"), ("odg", "OpenDocument drawing"),
        ("orf", "Olympus RAW"), ("pef", "Pentax RAW"), ("png", "PNG"), ("ppm", "Portable pixmap (Netpbm)"),
        ("ps", "PostScript"), ("psb", "Photoshop large document"), ("psd", "Photoshop document"),
        ("pub", "Microsoft Publisher"), ("raf", "Fujifilm RAW"), ("raw", "Panasonic / Leica RAW"),
        ("rw2", "Panasonic RAW 2"), ("tga", "Truevision TGA"), ("tif", "TIFF"), ("tiff", "TIFF"),
        ("webp", "WebP"), ("x3f", "Sigma Foveon RAW"), ("xcf", "GIMP image"), ("xps", "XML Paper Specification")])),
    ("video", ("Video", [
        ("3g2", "3GPP2 video"), ("3gp", "3GPP video"), ("3gpp", "3GPP video"), ("avi", "AVI"),
        ("cavs", "Chinese AVS video"), ("dv", "DV video"), ("dvr", "DVR-MS recording"), ("flv", "Flash video"),
        ("m2ts", "Blu-ray transport stream"), ("m4v", "MPEG-4 video (iTunes)"), ("mkv", "Matroska video"),
        ("mod", "Camcorder MPEG-2 (MOD)"), ("mov", "QuickTime movie"), ("mp4", "MPEG-4 video"),
        ("mpeg", "MPEG program stream"), ("mpg", "MPEG program stream"), ("mts", "AVCHD transport stream"),
        ("mxf", "Material Exchange Format"), ("ogg", "Ogg"), ("ogv", "Ogg video"), ("rm", "RealMedia"),
        ("rmvb", "RealMedia VBR"), ("swf", "Flash (SWF)"), ("ts", "MPEG transport stream"),
        ("vob", "DVD video object"), ("webm", "WebM"), ("wmv", "Windows Media video"), ("wtv", "Windows recorded TV")])),
    ("audio", ("Audio", [
        ("aac", "AAC (ADTS)"), ("ac3", "Dolby Digital (AC-3)"), ("aif", "AIFF"), ("aifc", "AIFF-C"), ("aiff", "AIFF"),
        ("amr", "Adaptive Multi-Rate"), ("au", "Sun / NeXT audio"), ("caf", "Core Audio Format"),
        ("dss", "Olympus Digital Speech Standard"), ("flac", "FLAC"), ("m4a", "MPEG-4 audio"),
        ("m4b", "MPEG-4 audiobook"), ("mp3", "MP3"), ("oga", "Ogg audio"), ("opus", "Opus"), ("sf2", "SoundFont 2"),
        ("sfark", "sfArk compressed SoundFont"), ("voc", "Creative Voice"), ("wav", "WAVE"), ("weba", "WebM audio"),
        ("wma", "Windows Media audio")])),
    ("spreadsheet", ("Spreadsheets", [
        ("csv", "Comma-separated values"), ("et", "WPS Spreadsheets"), ("numbers", "Apple Numbers"),
        ("ods", "OpenDocument spreadsheet"), ("sdc", "StarOffice Calc spreadsheet"), ("xls", "Excel 97–2003 workbook"),
        ("xlsm", "Excel macro-enabled workbook"), ("xlsx", "Excel workbook")])),
    ("presentation", ("Slides", [
        ("dps", "WPS Presentation"), ("key", "Apple Keynote"), ("odp", "OpenDocument presentation"),
        ("pot", "PowerPoint 97–2003 template"), ("potx", "PowerPoint template"), ("pps", "PowerPoint 97–2003 show"),
        ("ppsx", "PowerPoint show"), ("ppt", "PowerPoint 97–2003"), ("pptm", "PowerPoint macro-enabled"),
        ("pptx", "PowerPoint"), ("sda", "StarOffice Draw / Impress")])),
    ("ebook", ("E-books", [
        ("azw", "Kindle (AZW)"), ("azw3", "Kindle KF8 (AZW3)"), ("azw4", "Kindle Print Replica"),
        ("cbc", "Comic book collection"), ("cbr", "Comic book (RAR)"), ("cbz", "Comic book (ZIP)"),
        ("chm", "Compiled HTML Help"), ("epub", "EPUB"), ("fb2", "FictionBook 2"), ("htm", "HTML e-book"),
        ("htmlz", "Zipped HTML e-book"), ("lit", "Microsoft Reader"), ("lrf", "Sony BBeB"), ("mobi", "Mobipocket"),
        ("oeb", "Open eBook"), ("pdb", "Palm database e-book"), ("pml", "Palm Markup Language"),
        ("prc", "Mobipocket (PRC)"), ("rb", "Rocket eBook"), ("snb", "Shanda Bambook"), ("tcr", "Psion TCR"),
        ("txtz", "Zipped text e-book")])),
    ("archive", ("Archives", [
        ("7z", "7-Zip"), ("ace", "ACE"), ("alz", "ALZip"), ("arc", "ARC (SEA)"), ("arj", "ARJ"), ("bz", "bzip2"),
        ("bz2", "bzip2"), ("cab", "Windows cabinet"), ("cpio", "cpio"), ("deb", "Debian package"),
        ("dmg", "Apple disk image"), ("eml", "Email message"), ("gz", "gzip"), ("img", "Disk image"),
        ("iso", "ISO / UDF disc image"), ("jar", "Java archive"), ("lha", "LHA / LZH"), ("lz", "lzip"),
        ("lzma", "LZMA"), ("lzo", "lzop"), ("rar", "RAR"), ("rpm", "RPM package"), ("rz", "rzip"), ("tar", "tar"),
        ("tar.7z", "tar + 7z"), ("tar.bz", "tar + bzip2"), ("tar.bz2", "tar + bzip2"), ("tar.gz", "tar + gzip"),
        ("tar.lzo", "tar + lzop"), ("tar.xz", "tar + xz"), ("tar.z", "tar + compress"), ("tbz", "tar + bzip2"),
        ("tbz2", "tar + bzip2"), ("tgz", "tar + gzip"), ("tz", "tar + compress"), ("tzo", "tar + lzop"),
        ("xz", "xz"), ("z", "Unix compress"), ("zip", "ZIP")])),
    ("vector", ("Vector", [
        ("ai", "Adobe Illustrator"), ("cdr", "CorelDRAW"), ("cgm", "Computer Graphics Metafile"),
        ("emf", "Enhanced Metafile"), ("sk", "Skencil / Sketch"), ("sk1", "sK1 drawing"), ("svg", "SVG"),
        ("svgz", "Compressed SVG"), ("vsd", "Visio drawing"), ("wmf", "Windows Metafile")])),
    ("cad", ("CAD", [("dwf", "Design Web Format"), ("dwg", "AutoCAD drawing"), ("dxf", "Drawing Exchange Format")])),
    ("font", ("Fonts", [
        ("eot", "Embedded OpenType"), ("otf", "OpenType (CFF)"), ("ttf", "TrueType"), ("woff", "WOFF"),
        ("woff2", "WOFF 2")])),
])

CAT_OF = {}
NAME_OF = {}
for cat, (_, items) in CATEGORIES.items():
    for ext, name in items:
        CAT_OF[ext] = cat
        NAME_OF[ext] = name
assert len(CAT_OF) == 212, len(CAT_OF)

# ---------------------------------------------------------------------------------------------------------------------
# 2. Format groups used by the routing rules.
# ---------------------------------------------------------------------------------------------------------------------
RAW = {"3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "mos", "mrw", "nef", "orf", "pef", "raf", "raw", "rw2"}
IMAGEIO_IN = {"avif", "bmp", "gif", "heic", "heif", "icns", "ico", "jfif", "jpeg", "jpg", "png", "ppm", "psd", "tga",
              "tif", "tiff", "webp"}
IMAGEIO_OUT = {"bmp", "gif", "icns", "ico", "jpg", "jpeg", "png", "psd", "tiff", "heic"}
RASTER_OUT = IMAGEIO_OUT | {"webp", "avif", "odd"}
VECTOR_OUT = {"svg", "eps", "ps", "emf", "wmf", "dxf", "cgm"}
VIDEO_OUT = {"3g2", "3gp", "3gpp", "avi", "cavs", "dv", "dvr", "flv", "m2ts", "m4v", "mkv", "mod", "mov", "mp4",
             "mpeg", "mpg", "mts", "mxf", "ogv", "rm", "rmvb", "swf", "ts", "vob", "webm", "wmv", "wtv"}
AUDIO_OUT = {"aac", "ac3", "aif", "aifc", "aiff", "amr", "au", "caf", "dss", "flac", "m4a", "m4b", "mp3", "oga", "ogg",
             "opus", "voc", "wav", "weba", "wma"}
AVF_CONTAINERS = {"mov", "mp4", "m4v", "3gp", "3gpp", "3g2"}
AVF_AUDIO = {"m4a", "m4b", "aac", "aif", "aiff", "aifc", "wav", "caf", "flac"}
ARCHIVE_OUT = {"7z", "rar", "tar", "tar.bz2", "tar.gz", "zip"}
EBOOK_NATIVE_IN = {"epub", "oeb", "fb2", "htm", "htmlz", "txtz", "cbz", "cbr", "cbc", "chm"}
EBOOK_CALIBRE_IN = {"azw", "azw3", "azw4", "lit", "lrf", "mobi", "pdb", "pml", "prc", "rb", "snb", "tcr"}
LAYOUT_DOCS = {"doc", "docm", "docx", "dot", "dotx", "odt", "pages", "wpd", "wps", "lwp", "sdw", "hwp", "hwpx", "abw",
               "zabw", "rtf"}

# Niche formats (used only to rank work: P1 ships first, P3 last). A pair is P1 when both ends are common and no helper
# beyond LibreOffice/iWork is needed.
NICHE = {"sk", "sk1", "arc", "ace", "rz", "dwf", "x3f", "snb", "tcr", "rb", "pml", "lit", "lrf", "cbc", "dss", "sfark",
         "sf2", "cgm", "wtv", "dvr", "cavs", "swf", "rm", "rmvb", "alz", "tzo", "tar.lzo", "lzo", "sda", "sdc", "sdw",
         "et", "dps", "lwp", "wpd", "zabw", "abw", "pub", "psb", "xcf", "odd", "voc", "au", "amr", "3g2", "mod", "mxf",
         "dv", "vob", "oeb", "pdb", "xps", "eot", "tar.z", "tz", "z", "lha", "arj", "cpio", "img", "rpm", "deb",
         "tar.bz", "tbz", "bz", "lzma", "tar.7z", "djvu", "hwp", "hwpx", "wps", "pot", "pps", "dot", "azw4", "prc",
         "ppm", "tga", "erf", "mos", "mrw", "dcr", "3fr", "crw", "ogg", "oga", "weba", "aifc", "caf", "m4b", "ac3"}

# ---------------------------------------------------------------------------------------------------------------------
# 3. Helpers (optional, installed by the person with one click or "Get…"). Defined in formats.md §4.
# ---------------------------------------------------------------------------------------------------------------------
HELPERS = {
    "libreoffice": "LibreOffice", "iwork": "Pages / Numbers / Keynote", "calibre": "calibre", "pandoc": "Pandoc",
    "tectonic": "Tectonic", "ghostscript": "Ghostscript", "djvulibre": "DjVuLibre", "oda": "ODA File Converter",
    "libredwg": "LibreDWG", "ffmpeg-gpl": "FFmpeg GPL encoders", "rar": "RAR (RARLAB)", "sfark": "sfArk tool",
}




class Route:
    """How one (input, output) pair runs.

    builtin  — the path that needs nothing installed (Apple frameworks + code shipped in the app), or None.
    helper   — the path through an optional helper (§4), or None. When both exist, `prefer` says which one runs when
               the helper is present ("helper" for original-layout office rendering, "builtin" otherwise).
    """
    __slots__ = ("builtin", "helper", "helpers", "prefer", "options", "status", "note")

    def __init__(self, builtin=None, helper=None, helpers=(), options="—", prefer="builtin", status=None, note=""):
        assert builtin or helper or status == "no"
        assert (helper is None) == (not helpers) or status == "no", (builtin, helper, helpers)
        self.builtin = builtin
        self.helper = helper
        self.helpers = tuple(dict.fromkeys(helpers))
        self.prefer = prefer if (builtin and helper) else ("builtin" if builtin else "helper")
        self.options = options
        self.status = status
        self.note = note

    @property
    def need(self):
        if self.status == "no":
            return "no"
        if self.builtin and self.helper:
            return "optional"
        return "builtin" if self.builtin else "required"


def B(chain, options, **kw):
    return Route(builtin=chain, options=options, **kw)


def H(chain, helpers, options, **kw):
    return Route(helper=chain, helpers=helpers, options=options, **kw)


def BH(builtin, helper, helpers, options, prefer="builtin", **kw):
    return Route(builtin=builtin, helper=helper, helpers=helpers, options=options, prefer=prefer, **kw)


def X(reason):
    """A pair CloudConvert lists that Super Converter deliberately does not offer."""
    return Route(status="no", note=reason)


def then(route, tail, options=None, status=None):
    """Extend both paths of a route with the same tail."""
    return Route(builtin=f"{route.builtin} → {tail}" if route.builtin else None,
                 helper=f"{route.helper} → {tail}" if route.helper else None, helpers=route.helpers,
                 options=options or route.options, prefer=route.prefer, status=status or route.status, note=route.note)


# ---------------------------------------------------------------------------------------------------------------------
# 4. Routing rules: (input, output) -> Route. Engine names are the ids of formats.md §3.
# ---------------------------------------------------------------------------------------------------------------------
def image_writer(o):
    if o in IMAGEIO_OUT:
        return "ImageIO"
    return {"webp": "libwebp", "avif": "AVIFEncoder", "odd": "ODFWriter"}[o]


def raster_options(o):
    if o in ("jpg", "jpeg", "webp", "avif", "heic"):
        return "O-IMG+Q"
    if o in ("ico", "icns"):
        return "O-IMG+ICON"
    if o == "gif":
        return "O-IMG+GIF"
    if o == "tiff":
        return "O-IMG+TIFF"
    return "O-IMG"


VECTOR_WRITER = {"svg": "SVGWriter", "eps": "PSWriter", "ps": "PSWriter", "emf": "EMFWriter", "wmf": "WMFWriter",
                 "dxf": "DXFWriter", "pdf": "CGPDF", "cgm": "CGMWriter", "xps": "XPSWriter"}


def route_image(i, o):
    if o in AUDIO_OUT:
        return X("an image has no sound; CloudConvert's GIF/WebP → audio pairs produce an empty file")
    if o in VIDEO_OUT:
        return B("ImageIO frames (with their delays) → MediaKit encoder", "O-ANIM")

    # Vector-ish sources: PostScript (helper), XPS (own), OpenDocument/Publisher drawings (helper).
    if i in ("eps", "ps"):
        src = "Ghostscript⬇ (pdfwrite) → VectorKit"
        if o == "pdf":
            return H("Ghostscript⬇ (pdfwrite)", ("ghostscript",), "O-VEC")
        if o in ("eps", "ps"):
            return H(f"Ghostscript⬇ ({o}2write{', normalise' if o == i else ''})", ("ghostscript",), "O-VEC")
        if o in VECTOR_WRITER:
            return H(f"{src} → {VECTOR_WRITER[o]}", ("ghostscript",), "O-VEC")
        return H(f"{src} → RenderKit → ImagePipeline → {image_writer(o)}", ("ghostscript",), raster_options(o) + "+DPI",
                 note="EPS files with a TIFF preview show it built in, marked as a preview")
    if i == "xps":
        src = "XPSKit → VectorKit"
        if o in VECTOR_WRITER:
            return B(f"{src} → {VECTOR_WRITER[o]}", "O-VEC")
        if o == "html":
            return B(f"{src} → HTMLWriter (one inline SVG per page)", "O-RENDER")
        return B(f"{src} → RenderKit → ImagePipeline → {image_writer(o)}", raster_options(o) + "+DPI")
    if i in ("odg", "pub", "odd"):
        lo = "LibreOffice⬇ → PDF"
        native = "ODFReader (single embedded picture)" if i == "odd" else None
        if o == "pdf":
            if native:
                return BH(f"{native} → CGPDF", lo, ("libreoffice",), "O-VEC", prefer="helper")
            return H(lo, ("libreoffice",), "O-VEC")
        if o in VECTOR_WRITER:
            if native:
                return BH(f"{native} → PSWriter (raster, Level 3)" if o in ("eps", "ps") else
                          f"{native} → VectorKit → {VECTOR_WRITER[o]}",
                          f"{lo} → VectorKit → {VECTOR_WRITER[o]}", ("libreoffice",), "O-VEC", prefer="helper")
            return H(f"{lo} → VectorKit → {VECTOR_WRITER[o]}", ("libreoffice",), "O-VEC")
        tail = f"RenderKit → ImagePipeline → {image_writer(o)}"
        if native:
            return BH(f"{native} → ImagePipeline → {image_writer(o)}", f"{lo} → {tail}", ("libreoffice",),
                      raster_options(o) + "+DPI", prefer="helper")
        return H(f"{lo} → {tail}", ("libreoffice",), raster_options(o) + "+DPI")

    # Raster sources.
    if i in RAW:
        reader = "CIRAWFilter"
    elif i == "x3f":
        reader = "LibRaw (X3F tools)"
    elif i in ("psb", "xcf"):
        reader = "ImageCodecs"
    else:
        reader = "ImageIO"
    pipe = f"{reader} → ImagePipeline"
    if o in RASTER_OUT:
        return B(f"{pipe} → {image_writer(o)}", raster_options(o))
    if o == "pdf":
        return B(f"{pipe} → CGPDF (image page, ICC kept)", "O-IMG-PDF")
    if o == "svg":
        return B(f"{pipe} → VectorizeKit (trace)", "O-TRACE")
    if o in ("eps", "ps"):
        return B(f"{pipe} → PSWriter (raster, Level 3)", "O-IMG+PS")
    raise KeyError((i, o))


DOC_READER = {
    "abw": "AbiWordReader", "zabw": "AbiWordReader (gzip)", "doc": "TextKitImport(.doc)", "dot": "TextKitImport(.doc)",
    "docx": "DOCXReader", "docm": "DOCXReader", "dotx": "DOCXReader", "html": "HTMLReader", "hwp": "HWPReader",
    "hwpx": "HWPXReader", "md": "MarkdownReader", "odt": "ODTReader", "rtf": "TextKitImport(.rtf)",
    "txt": "PlainTextReader", "eml": "MailReader",
}
# Formats only a helper can open.
DOC_HELPER_READER = {
    "lwp": ("LibreOffice⬇ (→ ODT) → ODTReader", ("libreoffice",)),
    "sdw": ("LibreOffice⬇ (→ ODT) → ODTReader", ("libreoffice",)),
    "wpd": ("LibreOffice⬇ (→ ODT) → ODTReader", ("libreoffice",)),
    "wps": ("LibreOffice⬇ (→ ODT) → ODTReader", ("libreoffice",)),
    "rst": ("Pandoc⬇ (→ JSON AST) → DocModel", ("pandoc",)),
    "tex": ("Pandoc⬇ (LaTeX reader → JSON AST) → DocModel", ("pandoc",)),
    "pages": ("Pages app⬇ (export DOCX) → DOCXReader", ("iwork",)),
}
DOC_WRITER = {
    "doc": "TextKitExport(.doc)", "docx": "DOCXWriter", "odt": "ODTWriter", "rtf": "TextKitExport(.rtf)",
    "html": "HTMLWriter", "md": "MarkdownWriter", "rst": "RSTWriter", "tex": "LaTeXWriter", "txt": "TextWriter",
}
# Sources whose own page layout matters (office documents). They render through LibreOffice (or the owning app) for
# "Original layout" when it is installed; built in they are typeset "as written" (their fonts, sizes, spacing).
ORIGINAL_LAYOUT = {"doc", "docm", "docx", "dot", "dotx", "odt", "rtf", "abw", "zabw", "hwp"}


def doc_to_semantic(i):
    """Route from a document input to the DocModel (semantic) — the hub for every non-PDF document output."""
    if i in DOC_READER:
        return B(f"{DOC_READER[i]} → DocModel", "O-DOC")
    chain, hs = DOC_HELPER_READER[i]
    return H(chain, hs, "O-DOC")


def route_document(i, o):
    if i == "pdf":
        return route_pdf(o)
    if i == "djvu":
        if o == "pdf":
            return H("DjVuLibre⬇ (ddjvu -format=pdf; text layer kept)", ("djvulibre",), "O-PDF-PDF")
        r = route_pdf(o)
        return H(f"DjVuLibre⬇ → PDF → {r.builtin}", ("djvulibre",), r.options)
    if i == "tex" and o == "pdf":
        return H("Tectonic⬇ (XeTeX, real LaTeX run, offline bundle)", ("tectonic",), "O-TEX")
    if i == "pages":
        if o == "pdf":
            return H("Pages app⬇ export PDF (exact)", ("iwork",), "O-DOC-PDF")
        if o in ("docx", "epub", "txt"):
            return H(f"Pages app⬇ export {o.upper()}", ("iwork",), "O-DOC")
        if o == "doc":
            return H("Pages app⬇ → DOCX → DOCXReader → DocModel → TextKitExport(.doc)", ("iwork",), "O-DOC")
        if o in ("jpg", "png"):
            return H("Pages app⬇ → PDF → RenderKit → ImageIO", ("iwork",), "O-RENDER")
        if o == "ppt":
            return H("Pages app⬇ → PDF → LayoutKit → PPTXWriter → LibreOffice⬇ (.ppt)", ("iwork", "libreoffice"),
                     "O-DECK", status="P3")
        if o == "xls":
            return H("Pages app⬇ → PDF → LayoutKit tables → XLSXWriter → LibreOffice⬇ (.xls)", ("iwork", "libreoffice"),
                     "O-SHEET-OUT", status="P3")
        raise KeyError((i, o))

    sem = doc_to_semantic(i)
    if o == "pdf":
        if i == "html":
            return B("WebKit print (as a web page) · LaTeX look: HTMLReader → DocModel → TypesetKit", "O-WEB+O-DOC-PDF")
        if i in ORIGINAL_LAYOUT:
            hs = ("libreoffice",)
            orig = "LibreOffice⬇ (original layout; Word app when installed)" if i != "hwp" else \
                "LibreOffice⬇ (original layout, HWP ≤ 3.0 only)"
            return BH(f"{sem.builtin} → TypesetKit (as written, or LaTeX look)", orig, hs, "O-DOC-PDF",
                      prefer="helper")
        if i in ("lwp", "sdw", "wpd", "wps"):
            return H("LibreOffice⬇ → PDF (original layout) · LaTeX look: → ODTReader → DocModel → TypesetKit",
                     ("libreoffice",), "O-DOC-PDF")
        opts = "O-DOC-PDF+TXT" if i == "txt" else "O-DOC-PDF"
        return then(sem, "TypesetKit (LaTeX look; MathKit for math)", opts)
    if o in ("jpg", "png"):
        if i == "html":
            return B("WebKit snapshot (as a web page)", "O-WEB-SHOT")
        return then(route_document(i, "pdf"), "RenderKit → ImageIO (one image per page)", "O-RENDER")
    if o == "xps":
        return then(route_document(i, "pdf"), "VectorKit → XPSWriter", "O-DOC-PDF", status="P3")
    if o in ("epub", "oeb"):
        return then(sem, f"EbookKit ({o.upper()} writer)", "O-EBOOK")
    if o in ("azw3", "mobi", "lrf", "pdb"):
        r = then(sem, "EbookKit EPUB")
        return H(f"{r.builtin or r.helper} → calibre⬇ (ebook-convert)", r.helpers + ("calibre",), "O-EBOOK")
    if o == "pages":
        r = then(sem, "DOCXWriter") if i not in ("docx", "docm", "dotx") else B("DOCX", "O-DOC")
        return H(f"{r.builtin or r.helper} → Pages app⬇ (open + save as Pages)", r.helpers + ("iwork",), "O-DOC")
    if o in ("doc", "docx", "odt", "rtf") and i in ORIGINAL_LAYOUT - {"abw", "zabw", "hwp"}:
        if i in ("docx", "docm", "dotx") and o == "docx":
            return B("OOXML repackage (template/macros → document; content untouched)", "O-DOC")
        return BH(f"{sem.builtin} → {DOC_WRITER[o]}", f"LibreOffice⬇ (convert-to {o}; layout kept)", ("libreoffice",),
                  "O-DOC", prefer="helper")
    if o in ("doc", "docx", "odt", "rtf") and i in ("lwp", "sdw", "wpd", "wps"):
        return H(f"LibreOffice⬇ (convert-to {o}; layout kept)", ("libreoffice",), "O-DOC")
    if o in DOC_WRITER:
        return then(sem, DOC_WRITER[o], "O-DOC+MD" if o in ("md", "rst", "tex", "txt", "html") else "O-DOC")
    raise KeyError((i, o))


def route_pdf(o):
    if o == "pdf":
        return B("PDFKit + PDFOps (pages, split, passwords, permissions, watermark; PDF/A via RenderKit)", "O-PDF-PDF")
    if o in ("doc", "docx", "rtf"):
        return B(f"PDFKit → LayoutKit (+ Vision OCR) → DocModel → {DOC_WRITER[o]}", "O-PDF-OFFICE")
    if o == "xlsx":
        return B("PDFKit → LayoutKit tables → XLSXWriter", "O-PDF-SHEET")
    if o == "xls":
        return H("PDFKit → LayoutKit tables → XLSXWriter → LibreOffice⬇ (.xls)", ("libreoffice",), "O-PDF-SHEET")
    if o == "pptx":
        return B("PDFKit → LayoutKit → PPTXWriter (text editable, art as vectors)", "O-PDF-OFFICE")
    if o == "ppt":
        return H("PDFKit → LayoutKit → PPTXWriter → LibreOffice⬇ (.ppt)", ("libreoffice",), "O-PDF-OFFICE")
    if o == "html":
        return B("PDFKit → LayoutKit → HTMLWriter (reflowed, or positioned pages)", "O-PDF-HTML")
    if o == "md":
        return B("PDFKit → LayoutKit → DocModel → MarkdownWriter", "O-DOC+MD")
    if o == "txt":
        return B("PDFKit text in LayoutKit reading order", "O-PDF-TXT")
    if o in RASTER_OUT or o == "tiff":
        return B(f"RenderKit (CGPDF + ColorSync) → ImagePipeline → {image_writer(o)}", "O-RENDER")
    if o in VECTOR_WRITER:
        return B(f"VectorKit (CGPDFScanner) → {VECTOR_WRITER[o]}", "O-VEC", status="P3" if o == "xps" else None)
    if o in ("epub", "oeb"):
        return B(f"PDFKit → LayoutKit → DocModel → EbookKit ({o.upper()} writer)", "O-EBOOK")
    if o in ("azw3", "mobi", "lrf", "pdb"):
        return H("PDFKit → LayoutKit → EbookKit EPUB → calibre⬇", ("calibre",), "O-EBOOK")
    raise KeyError(("pdf", o))


def route_media(i, o):
    if o == "dss":
        return X("no DSS encoder or muxer exists outside Olympus' own software; CloudConvert can only copy the file")
    if o in VIDEO_OUT or o in ("gif", "webp"):
        if o == "cavs":
            return H("FFmpeg-GPL⬇ (libxavs encoder)", ("ffmpeg-gpl",), "O-VIDEO", status="P3")
        if o == "gif":
            return B("FFmpeg (palettegen + paletteuse, sierra2_4a dither)", "O-ANIM")
        if o == "webp":
            return B("FFmpeg (libwebp animated)", "O-ANIM")
        if i in AVF_CONTAINERS and o in AVF_CONTAINERS:
            return B("AVFoundation + VideoToolbox (FFmpeg when a stream is outside Apple's codecs)", "O-VIDEO")
        return B("FFmpeg LGPL (VideoToolbox H.264/HEVC/ProRes, libvpx, SVT-AV1)", "O-VIDEO")
    if o in AUDIO_OUT:
        if (i in AVF_CONTAINERS or i in AVF_AUDIO or i in ("mp3", "ac3")) and o in AVF_AUDIO:
            return B("AVFoundation + AudioToolbox (FFmpeg fallback)", "O-AUDIO")
        return B("FFmpeg LGPL (AudioToolbox AAC, LAME MP3, libopus, libvorbis)", "O-AUDIO")
    raise KeyError((i, o))


def route_soundfont(i, o):
    if i == "sf2":
        if o == "sfz":
            return B("SoundFontReader → SFZ + WAV samples (zipped)", "O-SF2")
        if o == "zip":
            return B("SoundFontReader → WAV samples + SFZ map → ArchiveKit", "O-SF2")
        return B(f"SoundFontReader → one {o.upper()} per sample (zipped)", "O-SF2")
    if o == "sf2":
        return H("sfArk tool⬇ (sfArkLib)", ("sfark",), "O-SF2", status="P3")
    return H(f"sfArk tool⬇ → SF2 → {route_soundfont('sf2', o).builtin}", ("sfark",), "O-SF2", status="P3")


SHEET_READER = {"csv": "CSVReader", "ods": "ODSReader", "xls": "XLSReader (libxls)", "xlsm": "XLSXReader",
                "xlsx": "XLSXReader"}
SHEET_HELPER_READER = {"et": ("LibreOffice⬇ (→ XLSX) → XLSXReader", ("libreoffice",)),
                       "sdc": ("LibreOffice⬇ (→ XLSX) → XLSXReader", ("libreoffice",)),
                       "numbers": ("Numbers app⬇ (export XLSX) → XLSXReader", ("iwork",))}


def sheet_to_workbook(i):
    if i in SHEET_READER:
        return B(f"{SHEET_READER[i]} → Workbook", "O-SHEET-OUT")
    c, hs = SHEET_HELPER_READER[i]
    return H(f"{c} → Workbook", hs, "O-SHEET-OUT")


def route_sheet(i, o):
    wb = sheet_to_workbook(i)
    if o == "pdf":
        if i == "csv":
            return B("CSVReader → Workbook → TypesetKit (booktabs table)", "O-SHEET-PDF")
        if i == "numbers":
            return H("Numbers app⬇ export PDF (exact)", ("iwork",), "O-SHEET-PDF")
        if i in ("et", "sdc"):
            return H("LibreOffice⬇ → PDF (original layout) · LaTeX look: → Workbook → TypesetKit", ("libreoffice",),
                     "O-SHEET-PDF")
        return BH(f"{wb.builtin} → TypesetKit (grid as laid out, or booktabs LaTeX look)",
                  "LibreOffice⬇ (original layout; Numbers / Excel app when installed)", ("libreoffice",),
                  "O-SHEET-PDF", prefer="helper")
    if o in ("jpg", "png"):
        return then(route_sheet(i, "pdf"), "RenderKit → ImageIO", "O-RENDER+SHEET")
    if o == "xps":
        return then(route_sheet(i, "pdf"), "VectorKit → XPSWriter", "O-SHEET-PDF", status="P3")
    if o in ("csv", "html", "xlsx", "ods"):
        w = {"csv": "CSVWriter", "html": "HTMLWriter (one table per sheet)", "xlsx": "XLSXWriter", "ods": "ODSWriter"}[o]
        if i in ("xlsx", "xlsm") and o == "xlsx":
            return B("OOXML repackage (macros dropped; content untouched)", "O-SHEET-OUT")
        return then(wb, w, "O-CSV" if o == "csv" else "O-SHEET-OUT")
    if o == "xls":
        if i in ("et", "sdc"):
            return H("LibreOffice⬇ (convert-to xls)", ("libreoffice",), "O-SHEET-OUT")
        return H(f"{wb.builtin or wb.helper} → XLSXWriter → LibreOffice⬇ (.xls) (Numbers / Excel app when installed)",
                 wb.helpers + ("libreoffice",), "O-SHEET-OUT")
    if o == "numbers":
        return H(f"{'XLSX' if i == 'xlsx' else (wb.builtin or wb.helper) + ' → XLSXWriter'} → Numbers app⬇ (open + save)",
                 wb.helpers + ("iwork",), "O-SHEET-OUT")
    if o in ("doc", "ppt"):
        return H(f"Numbers app⬇ → PDF → LayoutKit → {'DOCX' if o == 'doc' else 'PPTX'}Writer → LibreOffice⬇",
                 ("iwork", "libreoffice"), "O-SHEET-OUT", status="P3")
    raise KeyError((i, o))


OWN_PPTX = {"pptx", "pptm", "potx", "ppsx"}


def deck_to_pdf(i):
    if i == "key":
        return H("Keynote app⬇ export PDF (exact)", ("iwork",), "O-DECK")
    if i in OWN_PPTX:
        return BH("SlideRenderer (own PPTX: text, pictures, shapes, themes)",
                  "LibreOffice⬇ → PDF (Keynote app when installed)", ("libreoffice",), "O-DECK", prefer="helper")
    return H("LibreOffice⬇ → PDF (Keynote app for PPT/PPS when installed)", ("libreoffice",), "O-DECK")


def route_deck(i, o):
    pdf = deck_to_pdf(i)
    if o == "pdf":
        return pdf
    if o in ("jpg", "png"):
        if i == "key":
            return H("Keynote app⬇ export images (one per slide)", ("iwork",), "O-DECK+IMG")
        return then(pdf, "RenderKit → ImageIO (one per slide)", "O-DECK+IMG")
    if o in ("eps", "emf"):
        return then(pdf, f"VectorKit → {VECTOR_WRITER[o]} (one per slide)", "O-VEC")
    if o == "html":
        return then(pdf, "VectorKit → HTMLWriter (slide SVGs + speaker notes)", "O-DECK")
    if o in ("md", "txt"):
        w = "MarkdownWriter" if o == "md" else "TextWriter"
        if i in OWN_PPTX:
            return B(f"SlideReader (own PPTX) → titles, bullets, notes → {w}", "O-DOC+MD")
        if i == "key":
            return H(f"Keynote app⬇ → PPTX → SlideReader → {w}", ("iwork",), "O-DOC+MD")
        return H(f"LibreOffice⬇ (→ PPTX) → SlideReader → {w}", ("libreoffice",), "O-DOC+MD")
    if o == "pptx":
        if i == "key":
            return H("Keynote app⬇ export PPTX", ("iwork",), "O-DECK")
        if i in OWN_PPTX:
            return B("OOXML repackage (show/template/macros → presentation; content untouched)", "O-DECK")
        return H("LibreOffice⬇ (convert-to pptx; Keynote app when installed)", ("libreoffice",), "O-DECK")
    if o == "ppt":
        if i == "key":
            return H("Keynote app⬇ → PPTX → LibreOffice⬇ (.ppt)", ("iwork", "libreoffice"), "O-DECK")
        return H("LibreOffice⬇ (convert-to ppt)", ("libreoffice",), "O-DECK")
    if o == "odp":
        if i == "key":
            return H("Keynote app⬇ → PPTX → LibreOffice⬇ (.odp)", ("iwork", "libreoffice"), "O-DECK")
        return H("LibreOffice⬇ (convert-to odp)", ("libreoffice",), "O-DECK")
    if o == "key":
        return H("Keynote app⬇ (open + save as Keynote)", ("iwork",), "O-DECK")
    if o == "xps":
        return then(pdf, "VectorKit → XPSWriter", "O-DECK", status="P3")
    if o == "swf":
        r = then(pdf, "slide images → FFmpeg (SWF slideshow)", "O-DECK-VIDEO", status="P3")
        r.note = "Flash is obsolete; offered for parity only"
        return r
    if o in ("doc", "xls"):
        return H(f"Keynote app⬇ → PDF → LayoutKit → {'DOCX' if o == 'doc' else 'XLSX'}Writer → LibreOffice⬇",
                 ("iwork", "libreoffice"), "O-DOC", status="P3")
    raise KeyError((i, o))


EBOOK_READER = {"epub": "EPUBReader", "oeb": "OEBReader", "fb2": "FB2Reader", "htm": "HTMLReader",
                "htmlz": "HTMLZReader", "txtz": "TXTZReader", "cbz": "ComicReader (ZIP)",
                "cbr": "ComicReader (libarchive RAR)", "cbc": "ComicReader (collection)",
                "chm": "CHMReader (7zz extract + .hhc contents)"}


def ebook_to_publication(i):
    if i in EBOOK_READER:
        return B(f"{EBOOK_READER[i]} → Publication", "O-EBOOK")
    if i == "azw4":
        return H("calibre⬇ (Print Replica → its PDF)", ("calibre",), "O-EBOOK")
    return H("calibre⬇ (ebook-convert → EPUB) → EPUBReader → Publication", ("calibre",), "O-EBOOK")


def route_ebook(i, o):
    if i == "htm" and o in ("doc", "docx", "odt", "rtf", "txt"):
        return route_document("html", o)
    if i == "htm" and o in ("jpg", "png"):
        return B("WebKit snapshot (as a web page)", "O-WEB-SHOT")
    pub = ebook_to_publication(i)
    comic = i in ("cbz", "cbr", "cbc")
    if o == "pdf":
        if i == "azw4":
            return H("calibre⬇ → the embedded PDF, as published", ("calibre",), "O-PDF-PDF")
        if comic:
            return B(f"{EBOOK_READER[i]} → one page per picture (no recompression, ICC kept) → CGPDF", "O-COMIC")
        if i == "htm":
            return B("WebKit print (as a web page) · LaTeX look: HTMLReader → TypesetKit (book)", "O-WEB+O-DOC-PDF")
        return then(pub, "TypesetKit (book style, LaTeX look)", "O-EBOOK-PDF")
    if o in ("epub", "oeb"):
        if comic:
            return B(f"{EBOOK_READER[i]} → fixed-layout {o.upper()}", "O-EBOOK")
        return then(pub, f"EbookKit ({o.upper()} writer)", "O-EBOOK")
    if o in ("azw3", "mobi", "lrf", "pdb"):
        if i in EBOOK_CALIBRE_IN:
            return H("calibre⬇ (ebook-convert, direct)", ("calibre",), "O-EBOOK")
        return H(f"{pub.builtin} → EbookKit EPUB → calibre⬇ (ebook-convert)", ("calibre",), "O-EBOOK")
    if o in ("rtf", "txt"):
        return then(pub, f"DocModel → {DOC_WRITER[o]}", "O-DOC")
    raise KeyError((i, o))


ARCHIVE_READER = {
    "7z": "libarchive (7zz for AES-encrypted)", "tar.7z": "libarchive (7zz for AES-encrypted)",
    "rar": "libarchive RAR 4/5 (7zz for encrypted)", "zip": "libarchive (7zz for AES)", "jar": "libarchive",
    "arj": "7zz (bundled LGPL executable)", "img": "7zz (FAT/NTFS/MBR/GPT; hdiutil for Mac images)",
    "dmg": "hdiutil attach -readonly (7zz fallback)", "iso": "libarchive ISO 9660 (7zz for UDF)",
    "cab": "libarchive MSZIP/LZX (7zz for Quantum)", "lzo": "LZOKit (lzokay, MIT) + lzop container",
    "tar.lzo": "LZOKit + libarchive tar", "tzo": "LZOKit + libarchive tar", "ace": "ACEKit (acefile port, BSD-2)",
    "alz": "unalz (zlib licence, bundled)", "arc": "ARCKit (own: stored, packed, squeezed, crunched, squashed)",
    "rz": "RZipKit (own rzip decoder over bzip2)", "eml": "MailReader (attachments + message.html)",
    "deb": "libarchive ar + data.tar.* unpacked", "rpm": "libarchive RPM (cpio payload unpacked)",
}


def route_archive(i, o):
    r = ARCHIVE_READER.get(i, "libarchive")
    status = "P3" if i in ("arc", "rz", "ace") else None
    if o == "rar":
        return H(f"{r} → RAR⬇ (rar a -ma5)", ("rar",), "O-ARCHIVE", status=status or "P2",
                 note="RAR creation is proprietary; needs RARLAB's rar")
    if o == "7z":
        return B(f"{r} → libarchive 7z writer (7zz when a password is set)", "O-ARCHIVE", status=status)
    return B(f"{r} → libarchive {o} writer", "O-ARCHIVE", status=status)


def vector_source(i):
    if i == "ai":
        return BH("AIReader (PDF-compatible AI via CGPDF) → VectorKit",
                  "Ghostscript⬇ (pre-CS PostScript AI) → VectorKit", ("ghostscript",), "O-VEC")
    if i in ("cdr", "cgm", "vsd"):
        lib = {"cdr": "libcdr", "cgm": "CGM import", "vsd": "libvisio"}[i]
        return H(f"LibreOffice⬇ ({lib}) → PDF → VectorKit", ("libreoffice",), "O-VEC")
    if i in ("svg", "svgz"):
        pre = "gunzip → " if i == "svgz" else ""
        return B(f"{pre}SVGReader → VectorKit (WebKit for CSS, filters, foreignObject)", "O-VEC")
    return B({"emf": "EMFReader → VectorKit", "wmf": "WMFReader → VectorKit", "sk": "SkencilReader → VectorKit",
              "sk1": "SK1Reader → VectorKit"}[i], "O-VEC", status="P3" if i in ("sk", "sk1") else None)


def route_vector(i, o):
    if o in ("eot", "otf", "ttf", "woff", "woff2"):
        return B(f"SVGFontReader (<font>/<glyph>) → FontKit → {o.upper()} writer", "O-FONT", status="P2",
                 note="needs an SVG font; a plain drawing gets a clear message")
    src = vector_source(i)
    if o in VECTOR_WRITER:
        return then(src, VECTOR_WRITER[o], "O-VEC")
    return then(src, f"RenderKit → ImagePipeline → {image_writer(o)}", raster_options(o) + "+DPI")


def route_cad(i, o):
    if i == "dwg":
        if o == "dwg":
            return H("ODA File Converter⬇ (version change) · LibreDWG⬇", ("oda", "libredwg"), "O-CAD-DWG", status="P2")
        if o == "dxf":
            return H("ODA File Converter⬇ (chosen AutoCAD version) · LibreDWG⬇ dwg2dxf", ("oda", "libredwg"),
                     "O-CAD-DWG", status="P2")
        src = H("ODA File Converter⬇ / LibreDWG⬇ → DXF → DXFReader → CADKit", ("oda", "libredwg"), "O-CAD", status="P2")
    elif i == "dwf":
        src = B("DWFReader (DWFx via XPSKit; DWF 6 W2D own decoder) → CADKit", "O-CAD", status="P3")
    else:
        src = B("DXFReader → CADKit", "O-CAD")
    if o == "dwg":
        return H(f"{src.builtin or src.helper} → DXFWriter → ODA File Converter⬇ / LibreDWG⬇ (dxf2dwg)",
                 src.helpers + ("oda", "libredwg"), "O-CAD-DWG", status=src.status or "P2")
    if o == "dxf":
        return then(src, "DXFWriter (chosen AutoCAD version)", "O-CAD-DWG")
    if o in VECTOR_WRITER:
        return then(src, f"plot → VectorKit → {VECTOR_WRITER[o]}", "O-CAD")
    return then(src, f"plot → RenderKit → {image_writer(o)}", "O-CAD+IMG")


def route_font(i, o):
    reader = {"eot": "EOTReader (MTX via libeot)", "otf": "SFNTReader", "ttf": "SFNTReader",
              "woff": "WOFFReader", "woff2": "WOFF2Reader (google/woff2)"}[i]
    writer = {"eot": "EOTWriter", "otf": "CFFBuilder (quadratic → cubic, exact)",
              "ttf": "GlyfBuilder (cubic → quadratic, cu2qu ≤ 1/1000 em)", "woff": "WOFFWriter",
              "woff2": "WOFF2Writer (google/woff2 + Brotli 11)", "svg": "SVGFontWriter"}[o]
    return B(f"{reader} → FontKit → {writer}", "O-FONT")


def route(i, o):
    c = CAT_OF[i]
    if c == "image":
        return route_image(i, o)
    if c == "document":
        return route_document(i, o)
    if c == "video":
        return route_media(i, o)
    if c == "audio":
        return route_soundfont(i, o) if i in ("sf2", "sfark") else route_media(i, o)
    if c == "spreadsheet":
        return route_sheet(i, o)
    if c == "presentation":
        return route_deck(i, o)
    if c == "ebook":
        return route_ebook(i, o)
    if c == "archive":
        if i == "eml" and o not in ARCHIVE_OUT:
            return route_document("eml", o)
        return route_archive(i, o)
    if c == "vector":
        return route_vector(i, o)
    if c == "cad":
        return route_cad(i, o)
    return route_font(i, o)


# ---------------------------------------------------------------------------------------------------------------------
# 5. Pairs for the formats CloudConvert lists but does not convert, and gaps the hub fills for free (marked ⁺).
# ---------------------------------------------------------------------------------------------------------------------
ADDED_PAIRS = {
    "eml": ["pdf", "html", "txt", "md", "docx", "zip", "7z", "tar", "tar.gz", "tar.bz2"],
    "hwpx": ["doc", "docx", "html", "jpg", "md", "odt", "pdf", "png", "rtf", "txt"],
    "oeb": ["azw3", "epub", "lrf", "mobi", "pdb", "pdf", "rtf", "txt"],
    "sda": ["eps", "html", "jpg", "md", "odp", "pdf", "png", "ppt", "pptx", "txt"],
    "sdc": ["csv", "html", "jpg", "ods", "pdf", "png", "xls", "xlsx"],
    "sdw": ["doc", "docx", "html", "jpg", "md", "odt", "pdf", "png", "rtf", "txt"],
    "sf2": ["zip", "sfz", "wav", "flac"],
    "sfark": ["sf2", "zip", "sfz", "wav"],
}
BONUS_PAIRS = {"icns": ["avif", "bmp", "eps", "gif", "ico", "jpg", "odd", "pdf", "ps", "psd", "tiff", "webp"]}
for _ext in sorted(IMAGEIO_IN | RAW | {"psb", "xcf", "x3f"}):
    BONUS_PAIRS.setdefault(_ext, []).append("heic")  # HEIC is the Mac's own photo format; ImageIO writes it


def priority(i, o, r):
    if r.status:
        return r.status
    if r.need == "required" and set(r.helpers) - {"libreoffice", "iwork"}:
        return "P2"
    if i in NICHE and o in NICHE:
        return "P3"
    if i in NICHE or o in NICHE:
        return "P2"
    return "P1"


NEED_LABEL = {"builtin": "built in", "optional": "built in · helper better", "required": "needs helper"}


# ---------------------------------------------------------------------------------------------------------------------
# 6. Typed steps. Every route's readable chain is turned into [{engine, from, to}] so the planner never parses prose
#    (ARCHITECTURE §6). `from`/`to` are file formats ("docx") or model kinds ("@DocModel"). The chain strings stay the
#    single source of the routing; this section only reads them, and fails the run if a chain does not connect.
# ---------------------------------------------------------------------------------------------------------------------
import re

MODELS = ["ImageAsset", "VectorDocument", "DocModel", "LayoutDocument", "Workbook", "Deck", "Publication",
          "ArchiveTree", "MediaPlan", "FontModel", "CADDrawing"]

# Engine id -> (owning module, kind). Kinds: apple (system framework), own (this repository), bundled (third-party
# code shipped in the app), helper (optional program, formats §4). Ids are formats §3's names.
ENGINES = OrderedDict([
    ("ImageIO", ("ImageKit", "apple")), ("CIRAWFilter", ("ImageKit", "apple")), ("ImagePipeline", ("ImageKit", "own")),
    ("ImageCodecs", ("ImageKit", "own")), ("AVIFEncoder", ("ImageKit", "own")), ("libwebp", ("ImageKit", "bundled")),
    ("LibRaw", ("ImageKit", "bundled")),
    ("RenderKit", ("RenderKit", "own")),
    ("VectorKit", ("VectorKit", "own")), ("CGPDF", ("VectorKit", "apple")), ("SVGReader", ("VectorKit", "own")), ("SVGWriter", ("VectorKit", "own")),
    ("EMFReader", ("VectorKit", "own")), ("EMFWriter", ("VectorKit", "own")), ("WMFReader", ("VectorKit", "own")),
    ("WMFWriter", ("VectorKit", "own")), ("CGMWriter", ("VectorKit", "own")), ("PSWriter", ("VectorKit", "own")),
    ("SkencilReader", ("VectorKit", "own")), ("SK1Reader", ("VectorKit", "own")), ("AIReader", ("VectorKit", "own")),
    ("XPSKit", ("XPSKit", "own")), ("XPSWriter", ("XPSKit", "own")),
    ("VectorizeKit", ("VectorizeKit", "own")),
    ("CADKit", ("CADKit", "own")), ("DXFReader", ("CADKit", "own")), ("DXFWriter", ("CADKit", "own")),
    ("DWFReader", ("CADKit", "own")),
    ("DOCXReader", ("DocKit", "own")), ("ODTReader", ("DocKit", "own")), ("MarkdownReader", ("DocKit", "own")),
    ("HTMLReader", ("DocKit", "own")), ("PlainTextReader", ("DocKit", "own")), ("AbiWordReader", ("DocKit", "own")),
    ("HWPReader", ("DocKit", "own")), ("HWPXReader", ("DocKit", "own")), ("MailReader", ("DocKit", "own")),
    ("TextKitImport", ("DocKit", "apple")), ("TextKitExport", ("DocKit", "apple")),
    ("DOCXWriter", ("DocKit", "own")), ("ODTWriter", ("DocKit", "own")), ("HTMLWriter", ("DocKit", "own")),
    ("MarkdownWriter", ("DocKit", "own")), ("RSTWriter", ("DocKit", "own")), ("LaTeXWriter", ("DocKit", "own")),
    ("TextWriter", ("DocKit", "own")), ("WebKitPrint", ("DocKit", "apple")), ("WebKitSnapshot", ("DocKit", "apple")),
    ("TypesetKit", ("TypesetKit", "own")),
    ("LayoutKit", ("LayoutKit", "own")), ("PDFOps", ("ConvertKit", "own")),
    ("CSVReader", ("OfficeKit", "own")), ("CSVWriter", ("OfficeKit", "own")), ("XLSXReader", ("OfficeKit", "own")),
    ("XLSXWriter", ("OfficeKit", "own")), ("ODSReader", ("OfficeKit", "own")), ("ODSWriter", ("OfficeKit", "own")),
    ("XLSReader", ("OfficeKit", "bundled")), ("SlideReader", ("OfficeKit", "own")),
    ("SlideRenderer", ("OfficeKit", "own")), ("PPTXWriter", ("OfficeKit", "own")), ("ODFReader", ("OfficeKit", "own")),
    ("ODFWriter", ("OfficeKit", "own")), ("OOXMLRepackage", ("OfficeKit", "own")),
    ("EPUBReader", ("EbookKit", "own")), ("OEBReader", ("EbookKit", "own")), ("FB2Reader", ("EbookKit", "own")),
    ("HTMLZReader", ("EbookKit", "own")), ("TXTZReader", ("EbookKit", "own")), ("ComicReader", ("EbookKit", "own")),
    ("CHMReader", ("EbookKit", "own")), ("EbookKit", ("EbookKit", "own")),
    ("libarchive", ("ArchiveKit", "bundled")), ("7zz", ("ArchiveKit", "bundled")), ("hdiutil", ("ArchiveKit", "apple")),
    ("ACEKit", ("ArchiveKit", "own")), ("ARCKit", ("ArchiveKit", "own")), ("RZipKit", ("ArchiveKit", "own")),
    ("LZOKit", ("ArchiveKit", "own")), ("unalz", ("ArchiveKit", "bundled")), ("ArchiveKit", ("ArchiveKit", "own")),
    ("AVFoundation", ("MediaKit", "apple")), ("FFmpeg", ("MediaKit", "bundled")),
    ("SoundFontReader", ("MediaKit", "own")),
    ("SFNTReader", ("FontKit", "own")), ("WOFFReader", ("FontKit", "own")), ("WOFFWriter", ("FontKit", "own")),
    ("WOFF2Reader", ("FontKit", "bundled")), ("WOFF2Writer", ("FontKit", "bundled")), ("EOTReader", ("FontKit", "own")),
    ("EOTWriter", ("FontKit", "own")), ("SVGFontReader", ("FontKit", "own")), ("SVGFontWriter", ("FontKit", "own")),
    ("CFFBuilder", ("FontKit", "own")), ("GlyfBuilder", ("FontKit", "own")),
    ("LibreOffice", ("HelperKit", "helper")), ("Pages", ("HelperKit", "helper")), ("Numbers", ("HelperKit", "helper")),
    ("Keynote", ("HelperKit", "helper")), ("calibre", ("HelperKit", "helper")), ("Pandoc", ("HelperKit", "helper")),
    ("Tectonic", ("HelperKit", "helper")), ("Ghostscript", ("HelperKit", "helper")),
    ("DjVuLibre", ("HelperKit", "helper")), ("DWGConverter", ("HelperKit", "helper")),
    ("FFmpeg-GPL", ("HelperKit", "helper")), ("RAR", ("HelperKit", "helper")), ("sfArk", ("HelperKit", "helper")),
])

# Models that need a file-to-model reader when a chain names the model while still holding a file.
FILE_READER = {("odt", "DocModel"): "ODTReader", ("xlsx", "Workbook"): "XLSXReader", ("docx", "DocModel"): "DOCXReader",
               ("pdf", "DocModel"): "LayoutKit", ("pdf", "Publication"): "LayoutKit"}
# Model-to-model conversions a chain may imply.
MODEL_BRIDGE = {("Publication", "DocModel"): "EbookKit"}

READERS = {  # token prefix -> (engine, model); the model may follow the next marker token (FLEX)
    "AbiWordReader": ("AbiWordReader", "DocModel"), "DOCXReader": ("DOCXReader", "DocModel"),
    "ODTReader": ("ODTReader", "DocModel"), "MarkdownReader": ("MarkdownReader", "DocModel"),
    "HTMLZReader": ("HTMLZReader", "Publication"), "HTMLReader": ("HTMLReader", "DocModel"),
    "HWPXReader": ("HWPXReader", "DocModel"), "HWPReader": ("HWPReader", "DocModel"),
    "PlainTextReader": ("PlainTextReader", "DocModel"), "TextKitImport": ("TextKitImport", "DocModel"),
    "CSVReader": ("CSVReader", "Workbook"), "ODSReader": ("ODSReader", "Workbook"),
    "XLSReader": ("XLSReader", "Workbook"), "XLSXReader": ("XLSXReader", "Workbook"),
    "EPUBReader": ("EPUBReader", "Publication"), "OEBReader": ("OEBReader", "Publication"),
    "FB2Reader": ("FB2Reader", "Publication"), "TXTZReader": ("TXTZReader", "Publication"),
    "ComicReader": ("ComicReader", "Publication"), "CHMReader": ("CHMReader", "Publication"),
    "SVGReader": ("SVGReader", "VectorDocument"), "EMFReader": ("EMFReader", "VectorDocument"),
    "WMFReader": ("WMFReader", "VectorDocument"), "SkencilReader": ("SkencilReader", "VectorDocument"),
    "SK1Reader": ("SK1Reader", "VectorDocument"), "AIReader": ("AIReader", "VectorDocument"),
    "XPSKit": ("XPSKit", "VectorDocument"), "ODFReader": ("ODFReader", "ImageAsset"),
    "CIRAWFilter": ("CIRAWFilter", "ImageAsset"), "ImageCodecs": ("ImageCodecs", "ImageAsset"),
    "LibRaw": ("LibRaw", "ImageAsset"), "DXFReader": ("DXFReader", "CADDrawing"),
    "DWFReader": ("DWFReader", "CADDrawing"), "SFNTReader": ("SFNTReader", "FontModel"),
    "WOFF2Reader": ("WOFF2Reader", "FontModel"), "WOFFReader": ("WOFFReader", "FontModel"),
    "EOTReader": ("EOTReader", "FontModel"), "SVGFontReader": ("SVGFontReader", "FontModel"),
    "SlideReader": ("SlideReader", "DocModel"), "Pandoc": ("Pandoc", "DocModel"),
    "MailReader": ("MailReader", "DocModel"),
    "7zz": ("7zz", "ArchiveTree"), "hdiutil": ("hdiutil", "ArchiveTree"), "ACEKit": ("ACEKit", "ArchiveTree"),
    "ARCKit": ("ARCKit", "ArchiveTree"), "RZipKit": ("RZipKit", "ArchiveTree"), "LZOKit": ("LZOKit", "ArchiveTree"),
    "unalz": ("unalz", "ArchiveTree"),
}
FLEX = {"HTMLReader", "MailReader"}   # the model follows the next marker token
WRITERS = {  # token prefix -> (engine, fixed target format or None = the pair's output)
    "DOCXWriter": ("DOCXWriter", "docx"), "ODTWriter": ("ODTWriter", "odt"), "HTMLWriter": ("HTMLWriter", "html"),
    "MarkdownWriter": ("MarkdownWriter", "md"), "RSTWriter": ("RSTWriter", "rst"), "LaTeXWriter": ("LaTeXWriter", "tex"),
    "TextWriter": ("TextWriter", "txt"), "CSVWriter": ("CSVWriter", "csv"), "XLSXWriter": ("XLSXWriter", "xlsx"),
    "ODSWriter": ("ODSWriter", "ods"), "PPTXWriter": ("PPTXWriter", "pptx"), "SVGWriter": ("SVGWriter", "svg"),
    "PSWriter": ("PSWriter", None), "EMFWriter": ("EMFWriter", "emf"), "WMFWriter": ("WMFWriter", "wmf"),
    "DXFWriter": ("DXFWriter", "dxf"), "CGMWriter": ("CGMWriter", "cgm"), "XPSWriter": ("XPSWriter", "xps"),
    "CGPDF": ("CGPDF", "pdf"), "ODFWriter": ("ODFWriter", "odd"), "AVIFEncoder": ("AVIFEncoder", "avif"),
    "libwebp": ("libwebp", "webp"), "CFFBuilder": ("CFFBuilder", "otf"), "GlyfBuilder": ("GlyfBuilder", "ttf"),
    "WOFF2Writer": ("WOFF2Writer", "woff2"), "WOFFWriter": ("WOFFWriter", "woff"), "EOTWriter": ("EOTWriter", "eot"),
    "SVGFontWriter": ("SVGFontWriter", "svg"), "EOT writer": ("EOTWriter", "eot"), "OTF writer": ("CFFBuilder", "otf"),
    "TTF writer": ("GlyfBuilder", "ttf"), "WOFF2 writer": ("WOFF2Writer", "woff2"), "WOFF writer": ("WOFFWriter", "woff"),
    "ArchiveKit": ("ArchiveKit", None), "RAR": ("RAR", "rar"), "VectorizeKit": ("VectorizeKit", "svg"),
    "MediaKit encoder": ("FFmpeg", None),
}
PROCESS = {  # token prefix -> engine for programs and apps that turn a file into a file
    "LibreOffice": "LibreOffice", "Pages app": "Pages", "Numbers app": "Numbers", "Keynote app": "Keynote",
    "calibre": "calibre", "Tectonic": "Tectonic", "Ghostscript": "Ghostscript", "DjVuLibre": "DjVuLibre",
    "ODA File Converter": "DWGConverter", "FFmpeg-GPL": "FFmpeg-GPL", "sfArk tool": "sfArk",
    "OOXML repackage": "OOXMLRepackage", "WebKit print": "WebKitPrint", "WebKit snapshot": "WebKitSnapshot",
    "AVFoundation": "AVFoundation", "PDFKit + PDFOps": "PDFOps",
}
NOOPS = ("PDFKit", "gunzip", "titles, bullets", "one page per picture", "SFZ + WAV", "WAV samples + SFZ",
         "one FLAC per sample", "one WAV per sample")
FORMAT_MARKERS = ("PDF", "DXF", "DOCX", "PPTX", "XLSX", "EPUB", "SF2", "ODT")
MODEL_MARKERS = {"DocModel": "DocModel", "Workbook": "Workbook", "Publication": "Publication", "CADKit": "CADDrawing",
                 "FontKit": "FontModel"}
LIBARCHIVE_WRITER = re.compile(r"^libarchive (7z|tar\.bz2|tar\.gz|tar|zip) writer")


class ChainError(Exception):
    pass


def _tokens(chain):
    """Split on top-level arrows (arrows inside parentheses stay in their token)."""
    out, depth, cur = [], 0, ""
    i = 0
    while i < len(chain):
        ch = chain[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if depth == 0 and chain.startswith(" → ", i):
            out.append(cur.strip())
            cur = ""
            i += 3
            continue
        cur += ch
        i += 1
    out.append(cur.strip())
    return [t.removeprefix("→ ").strip() for t in out if t.strip()]


def _clean(tok):
    return tok.replace("⬇", "").strip()


def _starts(tok, table):
    """The longest key of `table` that `tok` starts with."""
    hits = [k for k in table if tok.startswith(k)]
    return max(hits, key=len) if hits else None


def _process_hint(tok):
    """The format a program/app step names for its result, or None."""
    m = re.search(r"\(\.(\w+)\)", tok)
    if m:
        return m.group(1).lower()
    m = re.search(r"convert-to (\w+)", tok)
    if m:
        return m.group(1).lower()
    m = re.search(r"→ (?:its |the )?(\w+)\)", tok)
    if m and m.group(1).upper() in FORMAT_MARKERS + ("JSON",):
        return m.group(1).lower()
    m = re.search(r"export (\w+)", tok)
    if m and m.group(1).upper() in FORMAT_MARKERS:
        return m.group(1).lower()
    if "save as Pages" in tok:
        return "pages"
    if "save as Keynote" in tok:
        return "key"
    if "pdfwrite" in tok:
        return "pdf"
    if "eps2write" in tok:
        return "eps"
    if "ps2write" in tok:
        return "ps"
    if "ddjvu -format=pdf" in tok:
        return "pdf"
    if "dxf2dwg" in tok:
        return "dwg"
    if "original layout" in tok:
        return "pdf"
    if "pre-CS PostScript AI" in tok:
        return "pdf"
    return None


def parse_chain(chain, i, o, start=None, prefix=None):
    """Turn one readable chain into steps. `start` is a (kind, value) state, 'f' file or 'm' model."""
    toks = [_clean(t) for t in _tokens(chain)]
    state = start or ("f", i)
    steps = list(prefix or [])
    pending = []   # indexes into steps of process steps whose target is not known yet

    def ep(s):
        return s[1] if s[0] == "f" else "@" + s[1]

    def emit(engine, frm, to, process=False):
        steps.append({"engine": engine, "from": ep(frm), "to": ep(to) if isinstance(to, tuple) else (to or None)})
        if process and steps[-1]["to"] is None:
            pending.append(len(steps) - 1)

    def settle(fmt):
        for k in pending:
            steps[k]["to"] = fmt
        pending.clear()

    def need_model(where):
        nonlocal state
        if state[0] == "f":
            if state[1] == "pdf":
                emit("LayoutKit", state, ("m", "DocModel"))
                state = ("m", "DocModel")
            else:
                raise ChainError(f"{where}: needs a model but holds file {state[1]}")

    def follows(k):
        return toks[k + 1] if k + 1 < len(toks) else None

    for k, t in enumerate(toks):
        nxt = follows(k)
        last = nxt is None

        # --- markers and no-ops ----------------------------------------------------------------------------------
        if t.startswith("PDFKit text"):
            emit("LayoutKit", state, o)
            state = ("f", o)
            continue
        if _starts(t, NOOPS) and not t.startswith("PDFKit + PDFOps"):
            continue
        if t in MODEL_MARKERS:
            want = MODEL_MARKERS[t]
            if state == ("m", want):
                continue
            if state[0] == "m":
                bridge = MODEL_BRIDGE.get((state[1], want))
                if not bridge:
                    raise ChainError(f"no bridge {state[1]} -> {want}")
                emit(bridge, state, ("m", want))
                state = ("m", want)
            else:
                reader = FILE_READER.get((state[1], want))
                if not reader:
                    raise ChainError(f"no reader {state[1]} -> {want}")
                emit(reader, state, ("m", want))
                state = ("m", want)
            continue
        fm = re.match(r"^(PDF|DXF|DOCX|PPTX|XLSX|EPUB|SF2|ODT)\b", t) or re.match(r"^the embedded (PDF)", t)
        if fm and state[0] == "f" and (pending or state[1] != fm.groups()[-1].lower()):
            fmt = fm.groups()[-1].lower()
            if pending:
                settle(fmt)
                state = ("f", fmt)
            elif state[1] in ("docm", "dotx") and fmt == "docx":
                emit("OOXMLRepackage", state, fmt)
                state = ("f", fmt)
            else:
                raise ChainError(f"marker {t} while holding file {state[1]}")
            continue
        if fm:
            continue   # the file is already that format
        if t == "slide images":
            emit("RenderKit", state, ("m", "ImageAsset"))
            state = ("m", "ImageAsset")
            continue
        if t == "plot":
            emit("CADKit", state, ("m", "VectorDocument"))
            state = ("m", "VectorDocument")
            continue

        # --- dual engines: reader or writer depending on what is held ----------------------------------------------
        if t.startswith("ImageIO"):
            if state[0] == "f":
                emit("ImageIO", state, ("m", "ImageAsset"))
                state = ("m", "ImageAsset")
            else:
                emit("ImageIO", state, o if last else None)
                state = ("f", o)
            continue
        if t.startswith("VectorKit"):
            if state[0] == "f":
                emit("VectorKit", state, ("m", "VectorDocument"))
                state = ("m", "VectorDocument")
            elif state != ("m", "VectorDocument"):
                raise ChainError(f"VectorKit holding {state}")
            continue
        if t.startswith("RenderKit"):
            if state[0] == "f" or state[1] == "VectorDocument":
                emit("RenderKit", state, ("m", "ImageAsset"))
                state = ("m", "ImageAsset")
            else:
                raise ChainError(f"RenderKit holding {state}")
            continue
        if t.startswith("ImagePipeline"):
            if state != ("m", "ImageAsset"):
                raise ChainError(f"ImagePipeline holding {state}")
            emit("ImagePipeline", state, state)
            continue
        if t.startswith("LayoutKit"):
            if state != ("f", "pdf"):
                raise ChainError(f"LayoutKit holding {state}")
            if "tables" in t:
                model = "Workbook"
            elif nxt in MODEL_MARKERS and MODEL_MARKERS[nxt] != "CADDrawing":
                model = MODEL_MARKERS[nxt]
            elif nxt and nxt.startswith("PPTXWriter"):
                model = "Deck"
            elif nxt and nxt.startswith("XLSXWriter"):
                model = "Workbook"
            elif nxt and nxt.startswith("HTMLWriter"):
                model = "LayoutDocument"
            elif nxt and nxt.startswith("EbookKit"):
                model = "Publication"
            elif nxt and (nxt.startswith("DOCXWriter") or nxt.startswith("MarkdownWriter")):
                model = "DocModel"
            else:
                raise ChainError(f"LayoutKit followed by {nxt}")
            emit("LayoutKit", state, ("m", model))
            state = ("m", model)
            continue
        if t.startswith("TypesetKit"):
            if state[0] == "f":
                need_model("TypesetKit")
            if state[1] not in ("DocModel", "Workbook", "Publication"):
                raise ChainError(f"TypesetKit holding {state}")
            emit("TypesetKit", state, "pdf")
            state = ("f", "pdf")
            continue
        if t.startswith("SlideRenderer"):
            emit("SlideRenderer", state, "pdf")
            state = ("f", "pdf")
            continue
        if t.startswith("SoundFontReader"):
            if nxt and nxt.startswith("WAV samples + SFZ map"):
                emit("SoundFontReader", state, ("m", "ArchiveTree"))
                state = ("m", "ArchiveTree")
            else:
                emit("SoundFontReader", state, o)
                state = ("f", o)
            continue
        if t.startswith("FFmpeg-GPL"):
            emit("FFmpeg-GPL", state, o)
            state = ("f", o)
            continue
        if t.startswith("FFmpeg"):
            emit("FFmpeg", state, o)
            state = ("f", o)
            continue
        if t.startswith("EbookKit") or t.startswith("fixed-layout"):
            if state[0] == "f":
                need_model("EbookKit")
            fmt = "oeb" if "OEB" in t else "epub"
            emit("EbookKit", state, fmt)
            state = ("f", fmt)
            continue
        lw = LIBARCHIVE_WRITER.match(t)
        if lw:
            if state != ("m", "ArchiveTree"):
                raise ChainError(f"libarchive writer holding {state}")
            emit("libarchive", state, lw.group(1))
            state = ("f", lw.group(1))
            continue
        if t.startswith("libarchive"):
            emit("libarchive", state, ("m", "ArchiveTree"))
            state = ("m", "ArchiveTree")
            continue
        if t.startswith("MailReader (attachments"):
            emit("MailReader", state, ("m", "ArchiveTree"))
            state = ("m", "ArchiveTree")
            continue

        # --- readers --------------------------------------------------------------------------------------------
        r = _starts(t, READERS)
        if r:
            eng, model = READERS[r]
            if r in FLEX:
                if nxt in MODEL_MARKERS:
                    model = MODEL_MARKERS[nxt]
                elif nxt and nxt.startswith("TypesetKit (book"):
                    model = "Publication"
            if state[0] != "f":
                raise ChainError(f"{eng} reader holding model {state[1]}")
            emit(eng, state, ("m", model))
            state = ("m", model)
            continue

        if t.startswith("TextKitExport"):
            if state[0] == "f":
                need_model("TextKitExport")
            fmt = re.search(r"\.(\w+)", t).group(1)
            emit("TextKitExport", state, fmt)
            state = ("f", fmt)
            continue

        # --- writers --------------------------------------------------------------------------------------------
        w = _starts(t, WRITERS)
        if w:
            eng, fixed = WRITERS[w]
            if state[0] == "f":
                need_model(eng)
            fmt = fixed or o
            emit(eng, state, fmt)
            state = ("f", fmt)
            continue

        # --- programs and apps (file in, file out) ---------------------------------------------------------------
        p = _starts(t, PROCESS)
        if p:
            eng = PROCESS[p]
            if state[0] != "f":
                raise ChainError(f"{eng} holding model {state[1]}")
            hint = _process_hint(t)
            if eng in ("OOXMLRepackage", "WebKitPrint", "WebKitSnapshot", "AVFoundation", "PDFOps", "Tectonic",
                       "FFmpeg-GPL"):
                hint = o
            if hint is None and "open + save" in t:
                hint = o
            if hint is None and last:
                hint = o
            emit(eng, state, hint, process=True)
            if hint:
                state = ("f", hint)
            else:
                state = ("f", "?")   # settled by the next marker
            continue
        raise ChainError(f"unknown token {t!r}")

    if pending:
        raise ChainError("unsettled process step")
    # Fix the file state of process steps settled by a later marker: re-derive continuity below.
    return steps


def check_steps(steps, i, o, label):
    """Continuity: the first step starts at the input, each step starts where the last ended, the last gives the output."""
    if not steps:
        raise ChainError(f"{label}: no steps")
    cur = i
    for s in steps:
        if s["engine"] not in ENGINES:
            raise ChainError(f"{label}: engine {s['engine']} not in ENGINES")
        if s["from"] != cur:
            raise ChainError(f"{label}: {s} does not start at {cur}")
        if s["to"] in (None, "?"):
            raise ChainError(f"{label}: {s} has no target")
        cur = s["to"]
    if cur != o:
        raise ChainError(f"{label}: ends at {cur}, wanted {o}")


def route_steps(i, o, row):
    """{"builtin": [...]|None, "helper": [...]|None, "alternates": [...]} for one matrix row."""
    label = f"{i}>{o}"
    out = {"builtin": None, "helper": None, "alternates": []}
    for kind in ("builtin", "helper"):
        chain = row[kind]
        if not chain:
            continue
        look = None
        if " · LaTeX look: " in chain:
            chain, look = chain.split(" · LaTeX look: ", 1)
            # What follows TypesetKit in the alternative (page rendering) applies to both looks.
            lt = _tokens(look)
            cut = next(n for n, x in enumerate(lt) if x.startswith("TypesetKit"))
            tail = lt[cut + 1:]
            if tail:
                chain = " → ".join([chain] + tail)
                look = " → ".join(lt[:cut + 1] + tail)
        elif " · " in chain:
            chain = chain.split(" · ")[0]
        steps = parse_chain(chain, i, o)
        out[kind] = steps
        if look is not None:
            prefix, start = [], None
            if kind == "helper":
                mid = "xlsx" if CAT_OF[i] == "spreadsheet" else "odt"
                prefix = [{"engine": "LibreOffice", "from": i, "to": mid}]
                start = ("f", mid)
            alt = parse_chain(look, i, o, start=start, prefix=prefix)
            check_steps(alt, i, o, label + " latex-look")
            out["alternates"].append({"look": "latex", "via": kind, "steps": alt})
    for kind in ("builtin", "helper"):
        if out[kind]:
            check_steps(out[kind], i, o, f"{label} {kind}")
    return out


# ---------------------------------------------------------------------------------------------------------------------
# 7. Swift data for SuperConverterCore (Sources/SuperConverterCore/Catalog/Generated/*.swift): the engine list, the
#    format list and every route with its typed steps. Generated; never edit by hand.
# ---------------------------------------------------------------------------------------------------------------------
SWIFT_DIR = os.path.join(ROOT, "Sources/SuperConverterCore/Catalog/Generated")
SWIFT_HEADER = "// Generated by scripts/gen-format-matrix.py from docs/specs/data/format-matrix.json. Do not edit.\n\n"
HELPER_CASE = {"libreoffice": "libreoffice", "iwork": "iwork", "calibre": "calibre", "pandoc": "pandoc",
               "tectonic": "tectonic", "ghostscript": "ghostscript", "djvulibre": "djvulibre", "oda": "oda",
               "libredwg": "libredwg", "ffmpeg-gpl": "ffmpegGPL", "rar": "rar", "sfark": "sfark"}
CASE_OVERRIDE = {"FFmpeg": "ffmpeg", "FFmpeg-GPL": "ffmpegGPL", "7zz": "sevenZip", "CGPDF": "cgPDF", "RAR": "rar",
                 "CIRAWFilter": "ciRAWFilter", "LaTeXWriter": "latexWriter", "RZipKit": "rzipKit", "DjVuLibre": "djvuLibre"}


def swift_case(name):
    if name in CASE_OVERRIDE:
        return CASE_OVERRIDE[name]
    run = 0
    while run < len(name) and (name[run].isupper() or name[run].isdigit()):
        run += 1
    if run == len(name):
        return name.lower()
    if run > 1 and name[run].islower():
        run -= 1
    return name[:run].lower() + name[run:]


def sw(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def endpoint(v):
    if v.startswith("@"):
        return "." + swift_case(v[1:])
    return sw(v)


def step_literal(s):
    return f".{swift_case(s['engine'])}, {endpoint(s['from'])}, {endpoint(s['to'])}"


def write_swift(matrix):
    os.makedirs(SWIFT_DIR, exist_ok=True)
    used = set()
    for f in matrix:
        for r in f["outputs"]:
            st = r["steps"]
            if st:
                for k in ("builtin", "helper"):
                    used.update(x["engine"] for x in st[k] or [])
                for a in st["alternates"]:
                    used.update(x["engine"] for x in a["steps"])
    unused = [e for e in ENGINES if e not in used]
    if unused:
        raise SystemExit(f"engines no route uses (remove from ENGINES): {unused}")
    cases = [swift_case(e) for e in ENGINES]
    assert len(set(cases)) == len(cases), "engine case names collide"

    out = [SWIFT_HEADER, "public enum EngineID: String, CaseIterable, Codable, Hashable, Sendable {\n"]
    for e in ENGINES:
        out.append(f"    case {swift_case(e)} = {sw(e)}\n")
    out.append("\n    /// The module that registers this engine's converter, and what kind of code it is.\n")
    out.append("    public var info: EngineInfo {\n        switch self {\n")
    for e, (mod, kind) in ENGINES.items():
        out.append(f"        case .{swift_case(e)}: EngineInfo(module: .{swift_case(mod)}, kind: .{kind})\n")
    out.append("        }\n    }\n}\n")
    open(os.path.join(SWIFT_DIR, "GeneratedEngines.swift"), "w").write("".join(out))

    # formats
    out = [SWIFT_HEADER, "extension FormatCatalog {\n    /// Every catalog format in CloudConvert's order, then the output-only formats.\n",
           "    static let seeds: [FormatSeed] = [\n"]
    inputs = {f["input"] for f in matrix}
    for f in matrix:
        out.append(f"        FormatSeed({sw(f['input'])}, .{f['category']}, {sw(f['name'])}),\n")
    outputs_only = OrderedDict()
    for f in matrix:
        for r in f["outputs"]:
            if r["output"] not in inputs:
                outputs_only.setdefault(r["output"], f["category"])
    OUTPUT_ONLY_NAMES = {"sfz": "SFZ instrument"}
    for o, cat in outputs_only.items():
        out.append(f"        FormatSeed({sw(o)}, .{cat}, {sw(OUTPUT_ONLY_NAMES[o])}, outputOnly: true),\n")
    out.append("    ]\n}\n")
    open(os.path.join(SWIFT_DIR, "GeneratedFormats.swift"), "w").write("".join(out))

    # routes, one file per input category; chains are shared constants
    by_cat = OrderedDict()
    for f in matrix:
        by_cat.setdefault(f["category"], []).append(f)
    for old in os.listdir(SWIFT_DIR):
        if old.startswith("GeneratedRoutes"):
            os.remove(os.path.join(SWIFT_DIR, old))
    for cat, fs in by_cat.items():
        chains = OrderedDict()

        def chain_ref(steps):
            key = tuple((x["engine"], x["from"], x["to"]) for x in steps)
            if key not in chains:
                chains[key] = f"c{len(chains)}"
            return chains[key]

        rows = []
        for f in fs:
            for r in f["outputs"]:
                args = [sw(f["input"]), sw(r["output"]), "." + r["origin"], "." + {"builtin": "builtin", "optional": "optional",
                        "required": "required", "no": "notOffered"}[r["need"]]]
                st = r["steps"]
                if st:
                    if st["builtin"]:
                        args.append(f"builtin: {chain_ref(st['builtin'])}")
                    if st["helper"]:
                        args.append(f"helper: {chain_ref(st['helper'])}")
                    if r["helpers"]:
                        args.append("helpers: [" + ", ".join("." + HELPER_CASE[h] for h in r["helpers"]) + "]")
                    if r["prefer"] == "helper" and st["builtin"]:
                        args.append("prefer: .helper")
                    if st["alternates"]:
                        args.append("alternates: [" + ", ".join(
                            f"RouteAlternate(.{a['look']}, via: .{a['via']}, steps: {chain_ref(a['steps'])})"
                            for a in st["alternates"]) + "]")
                args.append(f"options: {sw(r['options'])}")
                args.append(f".{r['priority'].lower()}" if r["priority"] != "no" else ".p3")
                if r["note"]:
                    args.append(f"note: {sw(r['note'])}")
                rows.append("        Route(" + ", ".join(args) + "),\n")
        name = "".join(w.capitalize() for w in cat.split("_"))
        out = [SWIFT_HEADER]
        for key, ref in chains.items():
            body = ", ".join(f"Step({step_literal(dict(engine=e, **{'from': a, 'to': b}))})" for e, a, b in key)
            out.append(f"private let {ref}: [Step] = [{body}]\n")
        out.append(f"\nextension GeneratedMatrix {{\n    static let {cat}: [Route] = [\n")
        out.extend(rows)
        out.append("    ]\n}\n")
        open(os.path.join(SWIFT_DIR, f"GeneratedRoutes{name}.swift"), "w").write("".join(out))

    out = [SWIFT_HEADER, "enum GeneratedMatrix {\n    static var all: [Route] {\n        ", " + ".join(by_cat), "\n    }\n}\n"]
    open(os.path.join(SWIFT_DIR, "GeneratedMatrix.swift"), "w").write("".join(out))



def main():
    snap = json.load(open(SNAPSHOT))
    cc_pairs = defaultdict(dict)
    for inp, out, engine, group, opts in snap["pairs"]:
        cc_pairs[inp][out] = (engine, opts)

    matrix = []
    for cat, (label, items) in CATEGORIES.items():
        for ext, name in items:
            outs = OrderedDict()
            for o in sorted(cc_pairs.get(ext, {})):
                outs[o] = ("cloudconvert", cc_pairs[ext][o][0], cc_pairs[ext][o][1])
            for o in ADDED_PAIRS.get(ext, []):
                outs.setdefault(o, ("added", None, []))
            for o in BONUS_PAIRS.get(ext, []):
                outs.setdefault(o, ("bonus", None, []))
            rows = []
            for o, (origin, cc_engine, cc_opts) in outs.items():
                r = route(ext, o)
                row = dict(builtin=r.builtin, helper=r.helper)
                steps = route_steps(ext, o, row) if r.need != "no" else None
                rows.append(OrderedDict([
                    ("output", o), ("origin", origin), ("cloudconvert", {"engine": cc_engine, "options": cc_opts}),
                    ("need", r.need), ("builtin", r.builtin), ("helper", r.helper), ("helpers", list(r.helpers)),
                    ("prefer", r.prefer if r.need != "no" else None), ("options", r.options),
                    ("priority", "no" if r.need == "no" else priority(ext, o, r)), ("note", r.note),
                    ("steps", steps)]))
            matrix.append(OrderedDict([("input", ext), ("category", cat), ("name", name), ("outputs", rows)]))

    text = json.dumps({"generated_by": "scripts/gen-format-matrix.py", "parity_snapshot": os.path.basename(SNAPSHOT),
                       "helpers": HELPERS, "formats": matrix}, indent=1, ensure_ascii=False)
    # One line per step keeps the file readable: {"engine": "ImageIO", "from": "heic", "to": "@ImageAsset"}.
    text = re.sub(r'\{\n\s+"engine": ("[^"]*"),\n\s+"from": ("[^"]*"),\n\s+"to": ("[^"]*")\n\s+\}',
                  r'{"engine": \1, "from": \2, "to": \3}', text)
    with open(OUT_JSON, "w") as fh:
        fh.write(text + "\n")

    write_swift(matrix)

    # ---- Markdown ----------------------------------------------------------------------------------------------------
    lines = [BEGIN, ""]
    by_cat = OrderedDict()
    for f in matrix:
        by_cat.setdefault(f["category"], []).append(f)
    lines += ["### 6.0 Totals", "",
              "| Category | Formats | Pairs (CloudConvert) | Pairs added ⁺ | Not offered | Built in | Built in · helper better | Needs helper | P1 | P2 | P3 |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    grand = defaultdict(int)
    for cat, fs in by_cat.items():
        c = defaultdict(int)
        c["formats"] = len(fs)
        for f in fs:
            for r in f["outputs"]:
                c["parity" if r["origin"] == "cloudconvert" else "added"] += 1
                c[r["need"]] += 1
                if r["priority"] != "no":
                    c[r["priority"]] += 1
        for k, v in c.items():
            grand[k] += v
        lines.append(f"| {CATEGORIES[cat][0]} | {c['formats']} | {c['parity']} | {c['added']} | {c['no']} | {c['builtin']} | "
                     f"{c['optional']} | {c['required']} | {c['P1']} | {c['P2']} | {c['P3']} |")
    lines.append(f"| **All** | **{grand['formats']}** | **{grand['parity']}** | **{grand['added']}** | **{grand['no']}** | "
                 f"**{grand['builtin']}** | **{grand['optional']}** | **{grand['required']}** | **{grand['P1']}** | "
                 f"**{grand['P2']}** | **{grand['P3']}** |")
    lines += ["", "*Built in* runs with nothing installed. *Built in · helper better* runs built in and switches to the "
              "helper when it is present (original office layout). *Needs helper* shows the one-click helper on the "
              "card. P1/P2/P3 order the work (§7); they do not limit what ships.", ""]

    sec = 1
    for cat, fs in by_cat.items():
        lines += [f"### 6.{sec} {CATEGORIES[cat][0]}", ""]
        sec += 1
        for f in fs:
            offered = [r for r in f["outputs"] if r["need"] != "no"]
            lines += [f"#### {f['input'].upper()} — {f['name']} · {len(offered)} target{'s' if len(offered) != 1 else ''}", ""]
            lines += ["| To | Built in | With a helper | Options | Rank |", "|---|---|---|---|---|"]
            groups = OrderedDict()
            for r in f["outputs"]:
                key = (r["builtin"], r["helper"], tuple(r["helpers"]), r["prefer"], r["options"], r["priority"], r["note"])
                groups.setdefault(key, []).append(r)
            for (bi, he, hs, pref, op, pr, note), rs in groups.items():
                tos = " ".join(r["output"].upper() + ("⁺" if r["origin"] != "cloudconvert" else "") for r in rs)
                if pr == "no":
                    lines.append(f"| {tos} | *not offered: {note}* | | | — |")
                    continue
                b = bi or "—"
                h = "—"
                if he:
                    names = ", ".join(HELPERS[x] for x in hs)
                    h = f"**{names}**: {he}" + (" *(preferred when present)*" if pref == "helper" and bi else "")
                if note:
                    b += f" *({note})*" if bi else ""
                    h += f" *({note})*" if not bi else ""
                lines.append(f"| {tos} | {b} | {h} | {op} | {pr} |")
            lines.append("")
    lines.append(END)

    md = open(OUT_MD).read() if os.path.exists(OUT_MD) else ""
    if BEGIN in md and END in md:
        md = md.split(BEGIN)[0] + "\n".join(lines) + md.split(END)[1]
    else:
        md = md + "\n" + "\n".join(lines) + "\n"
    with open(OUT_MD, "w") as fh:
        fh.write(md)
    print(f"formats={grand['formats']} parity={grand['parity']} added={grand['added']} not_offered={grand['no']} "
          f"builtin={grand['builtin']} optional={grand['optional']} required={grand['required']} "
          f"P1={grand['P1']} P2={grand['P2']} P3={grand['P3']}")


if __name__ == "__main__":
    sys.exit(main())
