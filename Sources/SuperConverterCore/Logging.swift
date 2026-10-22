import Foundation
import os

/// Unified-log categories, one per module (local only; no telemetry, ARCHITECTURE §4).
public enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? SuperConverterPaths.bundleID

    public static func category(_ module: ModuleID) -> Logger { Logger(subsystem: subsystem, category: module.rawValue) }

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let planner = Logger(subsystem: subsystem, category: "planner")
    public static let queue = Logger(subsystem: subsystem, category: "queue")
    public static let helpers = Logger(subsystem: subsystem, category: "helpers")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}
