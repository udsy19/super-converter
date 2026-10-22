import Foundation

/// Audio/video is the exception to the hub-and-spoke design (ARCHITECTURE §1): MediaKit's "model" is a plan of streams and
/// settings that AVFoundation or FFmpeg then carries out.
public struct MediaPlan: Hashable, Codable, Sendable {
    public enum Engine: String, Codable, Sendable { case copy, avFoundation, ffmpeg }

    public struct Stream: Hashable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case video, audio, subtitle, data }
        public var index: Int
        public var kind: Kind
        public var codec: String
        /// Output codec/encoder chosen for it; nil when the stream is copied.
        public var outputCodec: String?
        public var bitrate: Int?
        public var width: Int?
        public var height: Int?
        public var frameRate: Double?
        public var sampleRate: Int?
        public var channels: Int?
        public var isHDR: Bool
        public var language: String?
        public init(index: Int, kind: Kind, codec: String, outputCodec: String? = nil, bitrate: Int? = nil, width: Int? = nil,
                    height: Int? = nil, frameRate: Double? = nil, sampleRate: Int? = nil, channels: Int? = nil,
                    isHDR: Bool = false, language: String? = nil) {
            self.index = index; self.kind = kind; self.codec = codec; self.outputCodec = outputCodec; self.bitrate = bitrate
            self.width = width; self.height = height; self.frameRate = frameRate; self.sampleRate = sampleRate
            self.channels = channels; self.isHDR = isHDR; self.language = language
        }
    }

    public var engine: Engine
    public var container: FormatID
    public var duration: TimeInterval?
    public var streams: [Stream]
    public var trimStart: TimeInterval?
    public var trimEnd: TimeInterval?
    public var chapters: [Chapter]

    public struct Chapter: Hashable, Codable, Sendable {
        public var title: String
        public var start: TimeInterval
        public init(title: String, start: TimeInterval) { self.title = title; self.start = start }
    }

    public init(engine: Engine, container: FormatID, duration: TimeInterval? = nil, streams: [Stream] = [],
                trimStart: TimeInterval? = nil, trimEnd: TimeInterval? = nil, chapters: [Chapter] = []) {
        self.engine = engine; self.container = container; self.duration = duration; self.streams = streams
        self.trimStart = trimStart; self.trimEnd = trimEnd; self.chapters = chapters
    }
}
