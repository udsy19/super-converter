import Foundation

// Motion (ux §3.6). Durations in seconds. With Reduce Motion on, the spring becomes a 150 ms fade and nothing moves.

public struct SCSpring: Hashable, Sendable {
    public var response: Double
    public var dampingFraction: Double
    public init(response: Double, dampingFraction: Double) { self.response = response; self.dampingFraction = dampingFraction }
}

public enum SCMotion {
    /// Dropped files: cards appear with a spring from 92 % scale and 0 opacity.
    public static let cardAppear = SCSpring(response: 0.35, dampingFraction: 0.8)
    public static let cardAppearStartScale = 0.92
    /// Staggered 25 ms, at most 12 cards; the rest appear together.
    public static let cardStagger: TimeInterval = 0.025
    public static let cardStaggerLimit = 12
    /// Reduce Motion: fade instead.
    public static let reducedFade: TimeInterval = 0.15
    /// The drop-zone gradient border hue-rotates once per this long; the fan of sample cards spreads by 30 %.
    public static let dropGradientPeriod: TimeInterval = 3
    public static let fanSpread = 0.30
    /// Done: the tint cross-fades from the source to the target colour, the badge springs from 60 % scale.
    public static let tintCrossFade: TimeInterval = 0.4
    public static let badgeStartScale = 0.60
    /// Batch done: the action bar content slides up and fades in.
    public static let actionBarSlide = 12.0
}
