// The sample files the mockups use (ux §6 copy rules: real-looking names, real sizes).
window.FILES = (({ T }) => ({
  heic: { name: "Beach at golden hour.heic", meta: "4.2 MB · 4032 × 3024", cat: "img", src: "HEIC", dst: "JPG", dstCat: "img", thumb: T.photo(0) },
  docx: { name: "Quarterly report.docx", meta: "86 KB · 12 pages", cat: "doc", src: "DOCX", dst: "PDF", dstCat: "doc", thumb: T.page("doc", { title: 1, figure: 1 }) },
  mov: { name: "Interview take 3.mov", meta: "1.4 GB · 4K · 2:14", cat: "vid", src: "MOV", dst: "MP4", dstCat: "vid", thumb: T.video("2:14", 1) },
  wav: { name: "Podcast episode 12.wav", meta: "212 MB · 48 kHz · 41:20", cat: "aud", src: "WAV", dst: "MP3", dstCat: "aud", thumb: T.audio() },
  xlsx: { name: "Budget 2027.xlsx", meta: "48 KB · 3 sheets", cat: "sht", src: "XLSX", dst: "PDF", dstCat: "doc", thumb: T.sheet() },
  pptx: { name: "Pitch deck.pptx", meta: "12.6 MB · 18 slides", cat: "sld", src: "PPTX", dst: "PDF", dstCat: "doc", thumb: T.slide() },
  epub: { name: "The Time Machine.epub", meta: "412 KB · 12 chapters", cat: "ebk", src: "EPUB", dst: "PDF", dstCat: "doc", thumb: T.book() },
  svg: { name: "Logo final.svg", meta: "18 KB · 512 × 512", cat: "vec", src: "SVG", dst: "PNG", dstCat: "img", thumb: T.vector() },
  rar: { name: "Site photos.rar", meta: "88 MB · 64 files", cat: "arc", src: "RAR", dst: "ZIP", dstCat: "arc", thumb: T.zip() },
  ttf: { name: "Inter-Regular.ttf", meta: "310 KB · 2,548 glyphs", cat: "fnt", src: "TTF", dst: "WOFF2", dstCat: "fnt", thumb: T.font() },
  dwg: { name: "Ground floor plan.dwg", meta: "2.3 MB · AutoCAD 2018", cat: "cad", src: "DWG", dst: "PDF", dstCat: "doc", thumb: T.cad() },
  mobi: { name: "Middlemarch.mobi", meta: "1.9 MB · Kindle", cat: "ebk", src: "MOBI", dst: "EPUB", dstCat: "ebk", thumb: T.book() },
  md: { name: "Thesis notes.md", meta: "24 KB · 3,912 words", cat: "doc", src: "MD", dst: "PDF", dstCat: "doc", thumb: T.page("doc", { title: 1, math: 1 }) },
  raw: { name: "DSC_0412.NEF", meta: "28.4 MB · Nikon Z 6II", cat: "img", src: "NEF", dst: "JPG", dstCat: "img", thumb: T.photo(1) },
}))(SC);
