import Foundation
import SuperConverterCore

/// The `sconv` command line (ARCHITECTURE §3): the same planner, queue and output rules as the app, for scripts and the
/// quality bench.
///
///     sconv <files…> --to jpg [--option quality=90] [--out DIR] [--look original|written|latex]
///     sconv <files…> --list-targets          what each file can become, and how
///     sconv --from heic --list-targets
///     sconv --from heic --to jpg --list-options
///
/// Converted file paths go to standard output, one per line; everything else (notes, problems) to standard error.
/// Exit status: 0 all converted, 1 something didn’t convert, 64 wrong usage, 130 stopped.
public enum SconvCommand {
    public static let usage = """
        usage: sconv <files…> --to <format> [--option key=value]… [--out DIR] [--look original|written|latex]
               sconv <files…> | --from <format> --list-targets
               sconv --from <format> --to <format> --list-options

        """

    public struct UsageError: Error, Equatable { public let message: String }

    public struct Arguments: Equatable {
        public var files: [URL] = []
        public var from: FormatID?
        public var to: FormatID?
        public var options: [(key: String, value: String)] = []
        public var out: URL?
        public var look: DocumentLook?
        public var listTargets = false
        public var listOptions = false
        public var help = false

        public static func == (a: Arguments, b: Arguments) -> Bool {
            a.files == b.files && a.from == b.from && a.to == b.to && a.out == b.out && a.look == b.look
                && a.listTargets == b.listTargets && a.listOptions == b.listOptions && a.help == b.help
                && a.options.map { "\($0.key)=\($0.value)" } == b.options.map { "\($0.key)=\($0.value)" }
        }
    }

    // MARK: Parsing

    public static func parse(_ arguments: [String], currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Arguments {
        var parsed = Arguments()
        var queue = arguments[...]
        var onlyFiles = false
        func path(_ text: String, directory: Bool = false) -> URL { URL(fileURLWithPath: text, isDirectory: directory, relativeTo: currentDirectory).absoluteURL }
        func format(_ text: String) -> FormatID { FormatID(text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) }

        while let argument = queue.popFirst() {
            if onlyFiles || !argument.hasPrefix("-") || argument == "-" { parsed.files.append(path(argument)); continue }
            var name = argument
            var inline: String?
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals]); inline = String(argument[argument.index(after: equals)...])
            }
            func value() throws -> String {
                if let inline { return inline }
                guard let next = queue.popFirst() else { throw UsageError(message: "\(name) needs a value") }
                return next
            }
            switch name {
            case "--": onlyFiles = true
            case "-h", "--help": parsed.help = true
            case "--to", "-t": parsed.to = format(try value())
            case "--from": parsed.from = format(try value())
            case "--out", "-o": parsed.out = path(try value(), directory: true)
            case "--option", "-O":
                let pair = try value()
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw UsageError(message: "an option looks like key=value, not “\(pair)”")
                }
                parsed.options.append((String(pair[..<equals]), String(pair[pair.index(after: equals)...])))
            case "--look":
                let text = try value()
                guard let look = ["original": DocumentLook.original, "written": .asWritten, "latex": .latex][text.lowercased()] else {
                    throw UsageError(message: "--look is original, written or latex")
                }
                parsed.look = look
            case "--list-targets": parsed.listTargets = true
            case "--list-options": parsed.listOptions = true
            default: throw UsageError(message: "unknown option \(argument)")
            }
        }
        return parsed
    }

    /// Reads `text` as the value of `definition` (“yes”, “90”, a choice’s id or label…).
    public static func optionValue(_ text: String, for definition: OptionDefinition) throws -> OptionValue {
        let bad = { UsageError(message: "“\(text)” isn’t a valid value for \(definition.key)") }
        switch definition.kind {
        case .toggle:
            switch text.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: throw bad()
            }
        case .choice(let choices):
            guard let choice = choices.first(where: { $0.id.lowercased() == text.lowercased() || $0.label.lowercased() == text.lowercased() }) else {
                throw UsageError(message: "\(definition.key) is one of: \(choices.map(\.id).joined(separator: ", "))")
            }
            return .string(choice.id)
        case .integer(let range, _):
            guard let number = Int(text) else { throw bad() }
            guard range.contains(number) else { throw UsageError(message: "\(definition.key) is between \(range.lowerBound) and \(range.upperBound)") }
            return .int(number)
        case .number(let range, _):
            guard let number = Double(text) else { throw bad() }
            guard range.contains(number) else { throw UsageError(message: "\(definition.key) is between \(range.lowerBound) and \(range.upperBound)") }
            return .double(number)
        case .text, .secret, .pageRange, .colour, .file:
            return .string(text)
        }
    }

    // MARK: Running

    /// Runs a command and returns the exit status. `write` receives (text, isError).
    @MainActor
    public static func run(_ arguments: [String], planner: Planning? = nil, queue: JobQueueing? = nil, sniffer: FormatSniffing? = nil,
                           write: @escaping (String, Bool) -> Void) async -> Int32 {
        let planner = planner ?? Services.planner!, queue = queue ?? Services.queue!, sniffer = sniffer ?? Services.sniffer!
        let out = { write($0 + "\n", false) }, err = { write($0 + "\n", true) }
        let parsed: Arguments
        do { parsed = try parse(arguments) } catch let error as UsageError {
            err("sconv: \(error.message)"); write(usage, true); return 64
        } catch { return 64 }
        if parsed.help { write(usage, false); return 0 }

        if parsed.listTargets { return listTargets(parsed, planner: planner, sniffer: sniffer, out: out, err: err) }
        if parsed.listOptions { return listOptions(parsed, planner: planner, sniffer: sniffer, out: out, err: err) }
        guard let target = parsed.to, !parsed.files.isEmpty else { write(usage, true); return 64 }

        // Plan every file first, so a bad option or a missing file is reported before anything runs.
        var requests: [(file: URL, plan: ConversionPlan)] = []
        var status: Int32 = 0
        for file in parsed.files {
            do {
                let sniffed = try sniffer.sniff(file)
                guard let source = sniffed.format else { err("\(file.lastPathComponent): \(Strings.problem(.notReadableYet).message)"); status = 1; continue }
                if sniffed.mismatch { err("\(file.lastPathComponent): \(Strings.Card.mismatch(source))") }
                var request = ConversionRequest(source: file, sourceFormat: source, target: target, look: parsed.look)
                let plan = planner.plan(for: request)
                request.options = try options(parsed.options, profile: plan.optionProfile)
                requests.append((file, planner.plan(for: request)))
            } catch let error as UsageError {
                err("sconv: \(error.message)"); return 64
            } catch {
                err("\(file.lastPathComponent): \(error.localizedDescription)"); status = 1
            }
        }

        let place: OutputPlace = parsed.out.map { .folder($0) } ?? .nextToOriginal
        let events = queue.events
        var jobs: [JobID: URL] = [:]
        for (file, plan) in requests { jobs[queue.enqueue(plan, into: place)] = file }
        if jobs.isEmpty { return status == 0 ? 1 : status }
        for await event in events {
            switch event {
            case .finished(let id, let result):
                guard let file = jobs.removeValue(forKey: id) else { continue }
                result.outputs.forEach { out($0.path) }
                for note in result.lossNotes { err("\(file.lastPathComponent): \(note.headline)" + (note.detail.isEmpty ? "" : " (\(note.detail))")) }
                for warning in result.warnings { err("\(file.lastPathComponent): \(warning)") }
            case .failed(let id, let error):
                guard let file = jobs.removeValue(forKey: id) else { continue }
                err("\(file.lastPathComponent): \(Strings.problem(error).message)")
                status = 1
            case .cancelled(let id):
                guard jobs.removeValue(forKey: id) != nil else { continue }
                status = 130
            default: break
            }
            if jobs.isEmpty { break }
        }
        return status
    }

    @MainActor
    private static func listTargets(_ parsed: Arguments, planner: Planning, sniffer: FormatSniffing, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        var sources: [(label: String, format: FormatID)] = parsed.from.map { [($0.pill, $0)] } ?? []
        for file in parsed.files {
            guard let format = try? sniffer.sniff(file).format else { err("\(file.lastPathComponent): \(Strings.Card.unreadable)"); return 1 }
            sources.append((file.lastPathComponent, format))
        }
        guard !sources.isEmpty else { err("sconv: --list-targets needs files or --from <format>"); return 64 }
        for source in sources {
            if sources.count > 1 { out("# \(source.label) (\(source.format.pill))") }
            for (format, choice) in planner.targets(for: source.format) {
                out("\(format.rawValue)\t\(FormatCatalog.format(format)?.name ?? format.pill)\t\(describe(choice))")
            }
        }
        return 0
    }

    @MainActor
    private static func listOptions(_ parsed: Arguments, planner: Planning, sniffer: FormatSniffing, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        let from = parsed.from ?? parsed.files.first.flatMap { try? sniffer.sniff($0).format }
        guard let from, let to = parsed.to else { err("sconv: --list-options needs --to and a file or --from"); return 64 }
        let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/"), sourceFormat: from, target: to))
        guard let profile = OptionProfiles.profile(plan.optionProfile) else { err("sconv: \(from.pill) → \(to.pill) has no options"); return 1 }
        for option in profile.options {
            let kind: String = {
                switch option.kind {
                case .toggle: "yes/no"
                case .choice(let choices): choices.map(\.id).joined(separator: "|")
                case .integer(let range, _): "\(range.lowerBound)-\(range.upperBound)"
                case .number(let range, _): "\(range.lowerBound)-\(range.upperBound)"
                default: "text"
                }
            }()
            out("\(option.key)\t\(kind)\t\(option.defaultValue.map(describe) ?? "")\t\(option.label)")
        }
        return 0
    }

    private static func options(_ given: [(key: String, value: String)], profile id: String) throws -> OptionValues {
        guard !given.isEmpty else { return OptionValues() }
        guard let profile = OptionProfiles.profile(id) else { throw UsageError(message: "this conversion has no options") }
        var values = OptionValues()
        for (key, text) in given {
            guard let definition = profile.definition(key) else {
                throw UsageError(message: "no option “\(key)” here; the options are: \(profile.options.map(\.key).joined(separator: ", "))")
            }
            values[key] = try optionValue(text, for: definition)
        }
        return values
    }

    private static func describe(_ choice: RouteChoice) -> String {
        switch choice {
        case .builtin: "built in"
        case .helper(_, _, let missing): missing.isEmpty ? "with a helper" : "needs " + missing.map { HelperCatalog.info($0).name }.joined(separator: " and ")
        case .unavailable(let reason):
            switch reason {
            case .notOffered(let note): "not offered" + (note.isEmpty ? "" : ": \(note)")
            case .engineUnavailable(_, let why): "unavailable: \(why)"
            }
        }
    }

    private static func describe(_ value: OptionValue) -> String {
        switch value {
        case .bool(let v): v ? "yes" : "no"
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .string(let v): v
        }
    }
}
