import ArchiveKit
import CADKit
import ConvertKit
import DocKit
import EbookKit
import FontKit
import Foundation
import HelperKit
import ImageKit
import LayoutKit
import MathKit
import MediaKit
import OfficeKit
import RenderKit
import SuperConverterCore
import TypesetKit
import VectorKit
import VectorizeKit
import XPSKit

// sconv <files…> --to jpg [--option quality=90] [--out DIR] [--list-targets]  (ARCHITECTURE §3; the logic is ConvertKit's SconvCommand)
CoreBootstrap.configure()

Task { @MainActor in
    // Launch step 2 (ARCHITECTURE §9): HelperKit, every engine, then ConvertKit, which verifies the matrix against them.
    HelperKitModule.install()
    ImageKitModule.install(); VectorKitModule.install(); XPSKitModule.install(); VectorizeKitModule.install()
    CADKitModule.install(); DocKitModule.install(); TypesetKitModule.install(); MathKitModule.install()
    LayoutKitModule.install(); RenderKitModule.install(); OfficeKitModule.install(); EbookKitModule.install(extractor: ArchiveKitModule.extractor())
    ArchiveKitModule.install(); MediaKitModule.install(); FontKitModule.install()
    ConvertKitModule.install(collisionPolicy: { .addNumber })   // scripts never depend on the app’s Settings

    // Ctrl-C stops the running jobs (partial output is deleted) and ends the command with status 130.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { Services.queue.cancelAll() }
    interrupt.resume()

    let status = await SconvCommand.run(Array(CommandLine.arguments.dropFirst())) { text, isError in
        (isError ? FileHandle.standardError : FileHandle.standardOutput).write(Data(text.utf8))
    }
    exit(status)
}
RunLoop.main.run()   // WebKit (DocKit's web engines) needs the real main thread and its run loop
