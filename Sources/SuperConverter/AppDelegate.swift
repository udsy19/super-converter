import AppKit
import SuperConverterCore
import HelperKit
import ConvertKit
import WindowKit
import MenuBarKit
import SettingsKit
import ImageKit
import VectorKit
import XPSKit
import VectorizeKit
import CADKit
import DocKit
import TypesetKit
import MathKit
import LayoutKit
import RenderKit
import OfficeKit
import EbookKit
import ArchiveKit
import MediaKit
import FontKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A throwaway data folder or defaults suite (tests): no updater.
    private var isThrowaway = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 1. Core bootstrap.
        isThrowaway = CoreBootstrap.configure()
        SuperConverterPaths.ensure(SuperConverterPaths.support)

        // 2. Modules in order: HelperKit, every engine, then the feature modules.
        HelperKitModule.install()
        ImageKitModule.install()
        RenderKitModule.install()
        VectorKitModule.install()
        XPSKitModule.install()
        VectorizeKitModule.install()
        CADKitModule.install()
        DocKitModule.install()
        MathKitModule.install()
        TypesetKitModule.install()
        LayoutKitModule.install()
        OfficeKitModule.install()
        EbookKitModule.install()
        ArchiveKitModule.install()
        MediaKitModule.install()
        FontKitModule.install()
        ConvertKitModule.install()
        WindowKitModule.install()
        MenuBarKitModule.install()
        SettingsKitModule.install()
    }
}
