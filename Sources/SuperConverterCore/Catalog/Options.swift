import Foundation

/// One option's value. Stored as a plain JSON scalar so saved options stay readable (`defaults read`).
public enum OptionValue: Hashable, Codable, Sendable, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                         ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var int: Int? { switch self { case .int(let v): v; case .double(let v): Int(v); default: nil } }
    public var double: Double? { switch self { case .double(let v): v; case .int(let v): Double(v); default: nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// The values a person set for one conversion, by option key. Only differences from the defaults are stored.
public struct OptionValues: Hashable, Codable, Sendable {
    public var values: [String: OptionValue]

    public init(_ values: [String: OptionValue] = [:]) { self.values = values }

    public subscript(key: String) -> OptionValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public init(from decoder: Decoder) throws { values = try decoder.singleValueContainer().decode([String: OptionValue].self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    public var isEmpty: Bool { values.isEmpty }

    /// The value for `definition`: what was set, else its default.
    public func value(for definition: OptionDefinition) -> OptionValue? { values[definition.key] ?? definition.defaultValue }
}

/// A choice in a popup.
public struct OptionChoice: Hashable, Sendable {
    public let id: String
    public let label: String
    public init(_ id: String, _ label: String) { self.id = id; self.label = label }
}

/// How an option is edited.
public enum OptionKind: Hashable, Sendable {
    case toggle
    case choice([OptionChoice])
    case integer(ClosedRange<Int>, unit: String?)
    case number(ClosedRange<Double>, unit: String?)
    case text
    case secret
    case pageRange
    case colour
    case file(extensions: [String])
}

/// One option of a profile (formats §5): its key, the plain label, the type and default, the CloudConvert name it matches,
/// and whether it sits under "More options".
public struct OptionDefinition: Hashable, Sendable, Identifiable {
    public let key: String
    /// Plain words (ux §1.1): "Smaller file ↔ Best quality", not "CRF".
    public let label: String
    public let kind: OptionKind
    public let defaultValue: OptionValue?
    /// The CloudConvert option this matches, so people moving over find the same control; nil for options we add (⁺).
    public let cloudConvertName: String?
    /// Technical name shown in brackets under More options ("quality", "CRF").
    public let technicalName: String?
    /// Shown under "More options".
    public let isMore: Bool
    public var id: String { key }

    public init(_ key: String, _ label: String, _ kind: OptionKind, default defaultValue: OptionValue? = nil,
                cc: String? = nil, technical: String? = nil, more: Bool = false) {
        self.key = key; self.label = label; self.kind = kind; self.defaultValue = defaultValue
        self.cloudConvertName = cc; self.technicalName = technical; self.isMore = more
    }

    /// True for options CloudConvert does not offer (⁺ in formats §5).
    public var isAddition: Bool { cloudConvertName == nil }
}

/// A resolved profile: a base plus modifiers (`O-IMG+Q+DPI` is O-IMG, the quality module and the render-density module).
public struct OptionProfile: Hashable, Sendable {
    public let id: String
    public let options: [OptionDefinition]

    public var primary: [OptionDefinition] { options.filter { !$0.isMore } }
    public var more: [OptionDefinition] { options.filter(\.isMore) }
    public func definition(_ key: String) -> OptionDefinition? { options.first { $0.key == key } }
    /// The defaults of every option that has one.
    public var defaults: OptionValues {
        OptionValues(Dictionary(uniqueKeysWithValues: options.compactMap { o in o.defaultValue.map { (o.key, $0) } }))
    }
}
