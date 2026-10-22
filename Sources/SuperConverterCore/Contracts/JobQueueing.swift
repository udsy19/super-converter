import Foundation

public struct JobID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Queue classes (ux §6.4): video encodes one at a time, audio four, images and documents up to the number of
/// performance cores, archives two, one job per helper.
public enum ConcurrencyClass: Hashable, Sendable {
    case video, audio, image, document, archive
    case helper(HelperID)
}

public struct JobProgress: Hashable, Sendable {
    public var fraction: Double?
    /// "Page 3 of 12", "Slide 7 of 18": nil while only the fraction is known.
    public var unit: String?
    public var secondsLeft: Double?
    public init(fraction: Double?, unit: String? = nil, secondsLeft: Double? = nil) {
        self.fraction = fraction; self.unit = unit; self.secondsLeft = secondsLeft
    }
}

public struct ConversionResult: Hashable, Sendable {
    /// The files written (several for pages, slides and frames; a folder holds them, ux §6.3).
    public var outputs: [URL]
    public var lossNotes: [LossNote]
    public var warnings: [String]
    public var inputBytes: Int64
    public var outputBytes: Int64
    public init(outputs: [URL], lossNotes: [LossNote] = [], warnings: [String] = [], inputBytes: Int64 = 0, outputBytes: Int64 = 0) {
        self.outputs = outputs; self.lossNotes = lossNotes; self.warnings = warnings
        self.inputBytes = inputBytes; self.outputBytes = outputBytes
    }
}

public enum JobEvent: Sendable {
    case queued(JobID)
    /// Waiting for a helper that is still installing.
    case waitingForHelper(JobID, HelperID)
    case started(JobID)
    case progress(JobID, JobProgress)
    case finished(JobID, ConversionResult)
    case failed(JobID, ConversionError)
    case cancelled(JobID)
}

@MainActor
public protocol JobQueueing: AnyObject {
    /// Adds a job; `into` says where the result goes.
    func enqueue(_ plan: ConversionPlan, into place: OutputPlace) -> JobID
    /// Stops a job; partial output is deleted.
    func cancel(_ job: JobID)
    func cancelAll()
    /// Every job event, in order.
    var events: AsyncStream<JobEvent> { get }
    var activeCount: Int { get }
}
