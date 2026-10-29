import ColorSync
import CoreGraphics
import Foundation

/// A colour space with its exact ICC bytes (quality §2.2: profiles are kept byte for byte, so the bytes travel with the
/// pixels rather than being regenerated from a `CGColorSpace`).
struct ColourSpace: @unchecked Sendable, Equatable {
    enum Model: String, Sendable { case gray = "Gray", rgb = "RGB", cmyk = "CMYK", lab = "Lab" }

    let cg: CGColorSpace
    let icc: Data
    let model: Model

    var components: Int {
        switch model {
        case .gray: 1
        case .rgb, .lab: 3
        case .cmyk: 4
        }
    }

    static func == (a: ColourSpace, b: ColourSpace) -> Bool { a.icc == b.icc }

    /// A space from ICC bytes; nil when ColorSync cannot use them.
    init?(icc: Data) {
        guard let cg = CGColorSpace(iccData: icc as CFData), let model = Self.model(of: cg) else { return nil }
        self.cg = cg; self.icc = icc; self.model = model
    }

    /// A space from Core Graphics; spaces without ICC data (device spaces) become the untagged assumption of their model.
    init?(cg: CGColorSpace) {
        guard let model = Self.model(of: cg) else { return nil }
        if let data = cg.copyICCData() as Data?, !Self.isDevice(cg) {
            self.cg = cg; self.icc = data; self.model = model
        } else {
            self = Self.assumed(for: model)
        }
    }

    private init(named name: CFString) {
        let cg = CGColorSpace(name: name)!
        self.cg = cg
        self.icc = cg.copyICCData()! as Data
        self.model = Self.model(of: cg)!
    }

    private static func model(of cg: CGColorSpace) -> Model? {
        switch cg.model {
        case .monochrome: .gray
        case .rgb: .rgb
        case .cmyk: .cmyk
        case .lab: .lab
        default: nil
        }
    }

    private static func isDevice(_ cg: CGColorSpace) -> Bool {
        cg == CGColorSpaceCreateDeviceRGB() || cg == CGColorSpaceCreateDeviceGray() || cg == CGColorSpaceCreateDeviceCMYK()
    }

    static let sRGB = ColourSpace(named: CGColorSpace.sRGB)
    static let displayP3 = ColourSpace(named: CGColorSpace.displayP3)
    static let adobeRGB = ColourSpace(named: CGColorSpace.adobeRGB1998)
    static let proPhoto = ColourSpace(named: CGColorSpace.rommrgb)
    static let grayGamma22 = ColourSpace(named: CGColorSpace.genericGrayGamma2_2)
    static let genericCMYK = ColourSpace(named: CGColorSpace.genericCMYK)
    static let bt2020 = ColourSpace(named: CGColorSpace.itur_2020)

    /// What an untagged source means (quality §2.2): RGB = sRGB IEC 61966-2.1, gray = Gray Gamma 2.2, CMYK = Generic CMYK.
    static func assumed(for model: Model) -> ColourSpace {
        switch model {
        case .gray: grayGamma22
        case .cmyk: genericCMYK
        case .rgb, .lab: sRGB
        }
    }

    /// The same primaries and white point with a linear transfer (quality §2.1: resampling and compositing maths);
    /// nil for spaces Core Graphics cannot linearise (CMYK, LUT-based RGB), which are then resampled as encoded.
    var linear: ColourSpace? {
        guard model == .rgb || model == .gray, let lin = CGColorSpaceCreateLinearized(cg), let data = lin.copyICCData() as Data? else { return nil }
        return ColourSpace(icc: data)
    }
}

/// Profiles AVIF and HEIC carry as nclx code points (quality §2.2), recognised by what they do, not by their bytes.
enum KnownProfile: Equatable {
    case sRGB, displayP3, bt2020, bt2100PQ, bt2100HLG

    /// (colour primaries, transfer characteristics, matrix coefficients) as ISO/IEC 23091-2 numbers.
    var nclx: (primaries: UInt16, transfer: UInt16, matrix: UInt16) {
        switch self {
        case .sRGB: (1, 13, 6)
        case .displayP3: (12, 13, 6)
        case .bt2020: (9, 1, 9)
        case .bt2100PQ: (9, 16, 9)
        case .bt2100HLG: (9, 18, 9)
        }
    }

    /// The known profile a space is equivalent to: the same bytes as ColorSync's, or the same colours on a grid
    /// (other vendors' sRGB profiles with sampled curves count as sRGB).
    static func identify(_ space: ColourSpace) -> KnownProfile? {
        guard space.model == .rgb else { return nil }
        if CGColorSpaceUsesITUR_2100TF(space.cg) {
            if let name = space.cg.name, (name as String).contains("HLG") { return .bt2100HLG }
            return .bt2100PQ
        }
        let known: [(KnownProfile, ColourSpace)] = [(.sRGB, .sRGB), (.displayP3, .displayP3), (.bt2020, .bt2020)]
        if let hit = known.first(where: { $0.1.icc == space.icc }) { return hit.0 }
        return known.first { ColourTransform.equivalent(space, $0.1) }?.0
    }
}
