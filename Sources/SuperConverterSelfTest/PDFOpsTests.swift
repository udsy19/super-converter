import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore
import ConvertKit
import RenderKit

// PDFOps' checks (WP-L): page selection, split, passwords and permissions, watermark, PDF/A, on generated PDFs.

@MainActor
private func ops(_ url: URL, _ options: [String: OptionValue], failing: Bool = false) -> URL? {
    guard case .file(let out)? = fixtureRun(PDFOpsConverter(), from: "pdf", to: "pdf", input: .file(url), options: OptionValues(options), expectingFailure: failing)?.value else { return nil }
    return out
}

private func pageTexts(_ url: URL) -> [String] {
    guard let doc = PDFDocument(url: url) else { return [] }
    return (0..<doc.pageCount).map { ($0 < doc.pageCount ? doc.page(at: $0)?.string : nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

func registerPDFOpsTests() {
    let three = fixturePDF(pages: ["One", "Two", "Three"].map { word in { fixtureText($0, "Page \(word)", x: 72, y: 600, size: 20) } })

    SelfTest.cases.append(("PDFOps.pagesAndSplit", {
        guard let subset = ops(three, ["pages": "3,1"]) else { return }
        check(pageTexts(subset) == ["Page Three", "Page One"], "selected pages in order: \(pageTexts(subset))")
        guard let folder = ops(three, ["splitPages": true, "pages": "1-2"]) else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        check(files.count == 2 && files.allSatisfy { $0.hasSuffix(".pdf") }, "a file per page in a folder: \(files)")
        check(files.compactMap { PDFDocument(url: folder.appendingPathComponent($0)) }.allSatisfy { $0.pageCount == 1 }, "one page each")
        check(ops(three, ["pages": "9"], failing: true) == nil, "pages outside the file fail")
    }))

    SelfTest.cases.append(("PDFOps.passwordsAndPermissions", {
        guard let locked = ops(three, ["encryption": "encrypt", "setPassword": "open-me", "setOwnerPassword": "boss", "allowPrint": "none", "allowExtract": false]) else { return }
        let doc = PDFDocument(url: locked)
        check(doc?.isEncrypted == true && doc?.isLocked == true, "needs the password to open")
        check(doc?.unlock(withPassword: "open-me") == true, "opens with it")
        check(doc?.allowsPrinting == false && doc?.allowsCopying == false, "permissions applied: print \(String(describing: doc?.allowsPrinting)) copy \(String(describing: doc?.allowsCopying))")
        guard let unlocked = ops(locked, ["encryption": "remove", "password": "open-me"]) else { return }
        check(PDFDocument(url: unlocked)?.isEncrypted == false && pageTexts(unlocked).count == 3, "password removed, pages kept")
        check(ops(three, ["encryption": "encrypt", "setPassword": "x", "pdfA": true], failing: true) == nil, "PDF/A with a password is refused")
    }))

    SelfTest.cases.append(("PDFOps.watermarkPDFAAndSize", {
        let mark = fixturePDF(pages: [fixtureRedRectPage])
        guard let stamped = ops(three, ["watermarkImage": .string(mark.path), "watermarkLayer": "above"]) else { return }
        check(pageTexts(stamped).count == 3 && pageTexts(stamped)[0] == "Page One", "text kept under the watermark")
        let image = fixtureRun(RenderKitConverter(), from: "pdf", to: .imageAsset, input: .file(stamped), options: OptionValues(["pixelDensity": 72, "pages": "2"]))
        if case .image(let asset)? = image?.value, let frame = asset.frames.first {
            check(fixturePixel(frame, 150, 142).map { $0.r > 240 && $0.g < 60 } == true, "red mark drawn on the page")
        } else { check(false, "watermarked page didn't render") }
        guard let archived = ops(three, ["pdfA": true]), let doc = try? PDFPages.open(archived) else { check(false, "no PDF/A"); return }
        check(PDFAVerifier.verify(doc).isEmpty, "PDF/A output verifies")
        guard let small = ops(three, ["makeSmaller": "150", "removeMetadata": true]), let smallDoc = PDFDocument(url: small) else { return }
        check(smallDoc.pageCount == 3 && smallDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] == nil, "smaller copy without the title")
    }))
}
