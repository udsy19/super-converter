import Combine
import Foundation

// The engine-facing value types and contracts that are not about conversion: updates (UpdateKit). The engines implement or
// consume these; they never touch `Services` or `Defaults`.
//
// Adapted from super-pdf Sources/SuperPDFCore/Contracts/Engines.swift (commit 058469b): the updater part. WP0a extends
// this file with what the copied updater needs, in the same change.

// MARK: - Updates (UpdateKit, registered by the app target as `Services.updates`)

public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case downloading(version: String, fraction: Double)
    /// Staged; installs on quit or when idle, or now from "Install Latest Version".
    case readyToInstall(version: String)
    case failed(String)
    /// "Check for updates" is off (Settings › General).
    case disabled
}

@MainActor
public protocol UpdateChecking: AnyObject {
    /// Begins the background schedule (soon after launch, then every few hours) unless updates are off.
    func start()
    func checkNow()
    /// Installs a staged update now (relaunching the app).
    func installNow()
    var status: UpdateStatus { get }
    var statusChanges: AnyPublisher<UpdateStatus, Never> { get }
}
