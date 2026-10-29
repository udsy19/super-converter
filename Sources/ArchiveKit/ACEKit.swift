// Adapted from acefile acefile.py (BSD-2-Clause)
//
// acefile - read/test/extract ACE 1.0 and 2.0 archives in pure python
// Copyright (C) 2017-2026, Daniel Roethlisberger <daniel@roe.ch>
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions, and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
// OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
// NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// NOTE: The ACE archive format and ACE compression and decompression algorithms have been designed by Marcel Lemke. The
// above copyright notice and licence does not constitute a claim of intellectual property over ACE technology beyond the
// copyright of the acefile implementation.
//
// What changed in this port: Swift, read-only, no multi-volume archives, no comment decoding, headers parsed from a
// memory-mapped file; every size and offset is checked before use, names go through SafeExtractor, and entries are
// written in blocks. The decoder lives in ACEDecoder.swift, ACELZ77.swift, ACEPredictors.swift, ACEBits.swift and
// ACEBlowfish.swift.

import Foundation
import SuperConverterCore

/// ACE 1.0 and 2.0 archives (WinACE): stored, LZ77 and the 2.0 blocked method, solid archives, password protection.
enum ACEKit {
    private static let magic: [UInt8] = Array("**ACE**".utf8)
    private static let searchLimit = 512 * 1024

    private enum HeaderType { static let main = 0, file32 = 1, recovery32 = 2, file64 = 3, recovery64a = 4, recovery64b = 5 }
    private enum Flag {
        static let addSize = 1 << 0, comment = 1 << 1, is64Bit = 1 << 2, multiVolume = 1 << 11, advert = 1 << 12
        static let continuesPrevious = 1 << 12, continuesNext = 1 << 13, password = 1 << 14, ntSecurity = 1 << 10
    }
    private static let directoryAttribute: UInt32 = 0x10

    private struct FileHeader {
        var flags: Int
        var packedSize: Int
        var size: UInt64
        var datetime: UInt32
        var attributes: UInt32
        var crc: UInt32
        var compression: Int
        var params: Int
        var name: [UInt8]
        var dataOffset: Int
        var isEncrypted: Bool { flags & Flag.password != 0 }
    }

    /// A bounds-checked cursor over one header's bytes.
    private struct Cursor {
        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, bytes.count - i >= n else { throw ArchiveError.damaged("An ACE header is cut short.") }
            defer { i += n }
            return bytes[i..<i + n]
        }

        mutating func uint(_ n: Int) throws -> UInt64 {
            try take(n).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        try read(request, into: request.extractor(windowsSeparators: true))
    }

    /// Reads into a given extractor, so the caller can ask it what was left out.
    static func read(_ request: ArchiveReadRequest, into extractor: SafeExtractor) throws -> ArchiveTree {
        let data: Data
        do { data = try Data(contentsOf: request.source, options: .alwaysMapped) } catch {
            throw ArchiveError.failed("Couldn’t read \(request.source.lastPathComponent).")
        }
        let (isMultiVolume, files) = try parseHeaders(data)
        if isMultiVolume { throw ArchiveError.unsupported("Multi-volume ACE archives") }

        let decoder = ACEDecoder(isCancelled: request.isCancelled)
        let password = request.password.flatMap { $0.isEmpty ? nil : Array($0.utf8) }
        var sawEncrypted = false
        var usedLegacyNames = false

        for (index, header) in files.enumerated() {
            if request.isCancelled() { throw ArchiveError.cancelled }
            request.report(StepProgress(fraction: Double(index) / Double(files.count), unit: "File \(index + 1) of \(files.count)"))
            if header.flags & (Flag.continuesPrevious | Flag.continuesNext) != 0 {
                throw ArchiveError.unsupported("Multi-volume ACE archives")
            }
            let (decoded, legacy) = ArchiveDOSName.decode(header.name, index: index, encoding: request.nameEncoding)
            usedLegacyNames = usedLegacyNames || legacy
            let modified = ArchiveDOSTime.date(header.datetime)

            if header.attributes & directoryAttribute != 0 {
                try extractor.directory(decoded, modified: modified)
                continue
            }
            guard header.size <= UInt64(Int64.max), Int64(header.size) <= request.limits.maxTotalBytes else {
                throw ArchiveError.tooLarge("A file in this archive is larger than Super Converter will unpack.")
            }
            if header.size == 0 {
                try extractor.file(decoded, data: Data(), modified: modified)
                continue
            }
            var cipher: ACEBlowfish?
            if header.isEncrypted {
                sawEncrypted = true
                guard let password else { throw ArchiveError.passwordRequired }
                cipher = ACEBlowfish(password: password)
            }
            try extract(header, data: data, cipher: cipher, name: decoded, modified: modified, decoder: decoder, extractor: extractor)
        }
        request.report(StepProgress(fraction: 1, unit: nil))
        return extractor.finish(wasEncrypted: sawEncrypted, nameEncoding: usedLegacyNames ? "CP437" : nil)
    }

    // MARK: Entries

    private static func extract(_ header: FileHeader, data: Data, cipher: ACEBlowfish?, name: String, modified: Date?,
                                decoder: ACEDecoder, extractor: SafeExtractor) throws {
        let size = Int(header.size)
        let sink = try extractor.file(name, size: Int64(size), modified: modified)
        let source = ACEPackedSource(data: data, range: header.dataOffset..<header.dataOffset + header.packedSize, cipher: cipher)
        let dictionarySize = 1 << ((header.params & 15) + 10)
        var crc = ACECRC.Sum()
        let emit: ([UInt8]) throws -> Void = { chunk in
            crc.add(chunk)
            try chunk.withUnsafeBytes { try sink?.write($0) }
        }
        do {
            switch header.compression {
            case 0: try decoder.stored(source, size: size, dictionarySize: dictionarySize, emit: emit)
            case 1: try decoder.lz77Only(source, size: size, dictionarySize: dictionarySize, emit: emit)
            case 2: try decoder.blocked(source, size: size, dictionarySize: dictionarySize, emit: emit)
            default: throw ArchiveError.unsupported("ACE compression type \(header.compression)")
            }
            guard crc.sum == header.crc else { throw ArchiveError.damaged("A file’s checksum doesn’t match.") }
            try sink?.close()
        } catch {
            sink?.abort()
            // A wrong password only shows as garbage, which decoders and checksums report as damage.
            if header.isEncrypted, case ArchiveError.damaged = error { throw ArchiveError.passwordRequired }
            throw error
        }
    }

    // MARK: Headers

    private static func parseHeaders(_ data: Data) throws -> (isMultiVolume: Bool, files: [FileHeader]) {
        var offset = 0
        var mainFlags: Int?
        var files: [FileHeader] = []

        func parse(at start: Int) throws -> Int {
            try parseHeader(data, at: start, mainFlags: &mainFlags, files: &files)
        }

        var found = false
        if data.count >= 14, Array(data[7..<14]) == magic {
            let saved = (mainFlags, files)
            if let next = try? parse(at: 0) { offset = next; found = true } else { (mainFlags, files) = saved }
        }
        if !found {
            let window = Array(data.prefix(searchLimit))
            var from = 8
            while let at = find(magic, in: window, from: from) {
                from = at + 1
                guard at >= 7 else { continue }
                let saved = (mainFlags, files)
                if let next = try? parse(at: at - 7) { offset = next; found = true; break }
                (mainFlags, files) = saved
            }
        }
        guard found else { throw ArchiveError.damaged("This isn’t an ACE archive, or its header is damaged.") }
        while offset < data.count { offset = try parse(at: offset) }
        guard let mainFlags else { throw ArchiveError.damaged("This ACE archive has no main header.") }
        return (mainFlags & Flag.multiVolume != 0, files)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard haystack.count >= needle.count, from <= haystack.count - needle.count else { return nil }
        for i in from...(haystack.count - needle.count) where haystack[i] == needle[0] && Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }

    /// Parses the header at `start` and returns where the next one begins (after any data that belongs to it).
    private static func parseHeader(_ data: Data, at start: Int, mainFlags: inout Int?, files: inout [FileHeader]) throws -> Int {
        guard start >= 0, data.count - start >= 4 else { throw ArchiveError.damaged("An ACE header is cut short.") }
        let storedCRC = Int(data[start]) | Int(data[start + 1]) << 8
        let size = Int(data[start + 2]) | Int(data[start + 3]) << 8
        let bodyStart = start + 4
        guard data.count - bodyStart >= size else { throw ArchiveError.damaged("An ACE header is cut short.") }
        let body = Array(data[bodyStart..<bodyStart + size])
        guard Int(ACECRC.crc16(body)) == storedCRC else { throw ArchiveError.damaged("An ACE header’s checksum doesn’t match.") }

        var c = Cursor(body)
        let type = Int(try c.uint(1))
        let flags = Int(try c.uint(2))
        let after = bodyStart + size

        func skipData(_ n: UInt64) throws -> Int {
            guard n <= UInt64(data.count - after) else { throw ArchiveError.damaged("An ACE archive is cut short.") }
            return after + Int(n)
        }

        switch type {
        case HeaderType.main:
            guard flags & Flag.addSize == 0 else { throw ArchiveError.damaged("The ACE main header claims extra data.") }
            guard Array(try c.take(7)) == magic else { throw ArchiveError.damaged("The ACE main header has no signature.") }
            _ = try c.take(1 + 1 + 1 + 1 + 4 + 8)
            let advertSize = Int(try c.uint(1))
            _ = try c.take(advertSize)
            guard (flags & Flag.advert != 0) == (advertSize > 0) else { throw ArchiveError.damaged("The ACE advert flag is inconsistent.") }
            if flags & Flag.comment != 0 { _ = try c.take(Int(try c.uint(2))) }
            guard mainFlags == nil else { throw ArchiveError.damaged("An ACE archive has two main headers.") }
            mainFlags = flags
            return after

        case HeaderType.file32, HeaderType.file64:
            guard flags & Flag.addSize != 0 else { throw ArchiveError.damaged("An ACE file header has no data size.") }
            let is64 = flags & Flag.is64Bit != 0
            guard is64 == (type == HeaderType.file64) else { throw ArchiveError.damaged("An ACE file header’s size flag is inconsistent.") }
            let packed = try c.uint(is64 ? 8 : 4)
            let original = try c.uint(is64 ? 8 : 4)
            let datetime = UInt32(try c.uint(4))
            let attributes = UInt32(try c.uint(4))
            let crc = UInt32(try c.uint(4))
            let compression = Int(try c.uint(1))
            _ = try c.uint(1)
            let params = Int(try c.uint(2))
            _ = try c.uint(2)
            let nameSize = Int(try c.uint(2))
            let name = Array(try c.take(nameSize))
            if flags & Flag.comment != 0 { _ = try c.take(Int(try c.uint(2))) }
            if flags & Flag.ntSecurity != 0 { _ = try c.take(Int(try c.uint(2))) }
            let next = try skipData(packed)
            files.append(FileHeader(flags: flags, packedSize: Int(packed), size: original, datetime: datetime, attributes: attributes,
                                    crc: crc, compression: compression, params: params, name: name, dataOffset: after))
            return next

        case HeaderType.recovery32, HeaderType.recovery64a, HeaderType.recovery64b:
            guard flags & Flag.addSize != 0 else { throw ArchiveError.damaged("An ACE recovery header has no data size.") }
            let is64 = flags & Flag.is64Bit != 0
            guard is64 == (type != HeaderType.recovery32) else { throw ArchiveError.damaged("An ACE recovery header’s size flag is inconsistent.") }
            let recoverySize = try c.uint(is64 ? 8 : 4)
            return try skipData(recoverySize)

        default:
            var extra: UInt64 = 0
            if flags & Flag.addSize != 0 { extra = try c.uint(flags & Flag.is64Bit != 0 ? 8 : 4) }
            return try skipData(extra)
        }
    }
}

/// MS-DOS date and time packed into 32 bits (date in the high half), as ACE and ARC store them.
enum ArchiveDOSTime {
    /// Out-of-range values give 1 January 1980, like the DOS tools.
    static func date(_ packed: UInt32) -> Date? {
        let parts = DateComponents(year: Int((packed >> 25) & 0x7F) + 1980, month: Int((packed >> 21) & 0xF), day: Int((packed >> 16) & 0x1F),
                                   hour: Int((packed >> 11) & 0x1F), minute: Int((packed >> 5) & 0x3F), second: Int(packed & 0x1F) * 2)
        let calendar = Calendar(identifier: .gregorian)
        if let date = calendar.date(from: parts),
           calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == DateComponents(
            year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute, second: parts.second) {
            return date
        }
        return calendar.date(from: DateComponents(year: 1980, month: 1, day: 1))
    }
}

/// File names stored by DOS and Windows tools.
enum ArchiveDOSName {
    /// The name cut at its first NUL: UTF-8 when it is valid and the person did not pick a code page, else CP437. A name
    /// that is empty gets `file0000`-style number. The flag says the code page was needed.
    static func decode(_ stored: [UInt8], index: Int, encoding: NameEncoding) -> (String, Bool) {
        let raw = Array(stored.prefix { $0 != 0 })
        if raw.isEmpty { return (String(format: "file%04d", index), false) }
        if let chosen = encoding.swiftEncoding, let s = String(bytes: raw, encoding: chosen) { return (s, false) }
        if let s = String(bytes: raw, encoding: .utf8) { return (s, false) }
        return (String(bytes: raw, encoding: NameEncoding.cp437.swiftEncoding ?? .isoLatin1) ?? String(decoding: raw, as: UTF8.self), true)
    }
}
