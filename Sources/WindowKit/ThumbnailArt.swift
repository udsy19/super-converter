import SuperConverterCore
import SwiftUI

/// Drawn stand-ins for Quick Look thumbnails (ux §8): what a card shows until the real thumbnail arrives, and what the
/// empty window's fan of sample cards shows. Sizes follow the mockups.
struct ThumbnailArt: View {
    let category: FormatCategory
    var duration: String?

    var body: some View {
        switch category {
        case .image: PhotoArt()
        case .video: VideoArt(duration: duration)
        case .audio: AudioArt()
        case .spreadsheet: SheetArt()
        case .presentation: DeckArt()
        case .ebook: BookArt()
        case .vector: VectorArt()
        case .font: FontArt()
        case .archive: SymbolArt(symbol: "archivebox.fill", category: .archive)
        case .cad: SymbolArt(symbol: "ruler.fill", category: .cad)
        case .document: DocumentArt()
        }
    }
}

private extension Color {
    init(_ hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

private struct ArtShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.12), radius: 2.5, y: 2)
    }
}

struct PhotoArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color("#FFB454"), Color("#F1789B"), Color("#7A5A9A")], startPoint: .top, endPoint: .bottom))
            Circle().fill(Color("#FFE6B8")).frame(width: 26, height: 26).offset(x: 26, y: -20)
            Mountains(peaks: [(0.18, 0.35), (0.33, 0.58), (0.47, 0.40), (0.62, 0.66), (0.85, 0.34)]).fill(Color("#8A5C86")).offset(y: 4)
            Mountains(peaks: [(0.08, 0.7), (0.5, 0.45), (0.9, 0.7)]).fill(Color("#3B2B5B")).frame(height: 20).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .frame(width: 127, height: 90).modifier(ArtShadow())
    }
}

/// A ridge line: peaks are (x, height) fractions; fills down to the bottom edge.
private struct Mountains: Shape {
    let peaks: [(CGFloat, CGFloat)]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.15))
        for peak in peaks.sorted(by: { $0.0 < $1.0 }) {
            p.addLine(to: CGPoint(x: rect.minX + rect.width * peak.0, y: rect.maxY - rect.height * peak.1))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.2))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct DocumentArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(Color("#3D6CF2")).frame(width: 34, height: 5)
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(Color("#C9CFDD")).frame(width: i == 0 ? 52 : (i == 7 ? 36 : 58), height: 2.5)
            }
            RoundedRectangle(cornerRadius: 2).fill(Color("#C9D6FB")).frame(height: 7).padding(.top, 2)
        }
        .padding(11).frame(width: 76, height: 98, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 3).fill(.white))
        .modifier(ArtShadow())
    }
}

struct VideoArt: View {
    var duration: String?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color("#2A2160"), Color("#5B3FD0")], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().fill(Color("#F5C66B")).frame(width: 15, height: 15).offset(x: -42, y: -17)
                Mountains(peaks: [(0.4, 0.4), (0.9, 0.5)]).fill(Color("#2A2160").opacity(0.9)).frame(height: 28).frame(maxHeight: .infinity, alignment: .bottom)
                Circle().fill(.white).frame(width: 30, height: 30)
                    .overlay { ArrowHead().fill(Color("#5132C2")).frame(width: 10, height: 12).offset(x: 1) }
            }
            if let duration {
                Text(duration).font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1.5).background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.55)))
                    .padding(4)
            }
        }
        .frame(width: 132, height: 76).clipShape(RoundedRectangle(cornerRadius: 6)).modifier(ArtShadow())
    }
}

struct AudioArt: View {
    private static let heights: [CGFloat] = [14, 26, 38, 22, 46, 30, 54, 36, 24, 48, 58, 40, 30, 52, 34, 20, 44, 28, 50, 36, 24, 42, 30, 18, 26, 14]
    var body: some View {
        HStack(spacing: 2.3) {
            ForEach(Self.heights.indices, id: \.self) { i in
                Capsule().fill(Color("#FF8A1F")).frame(width: 2.4, height: Self.heights[i])
            }
        }
        .frame(width: 124, height: 76).background(RoundedRectangle(cornerRadius: 8).fill(.white)).modifier(ArtShadow())
    }
}

struct SheetArt: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) { ForEach(0..<4, id: \.self) { _ in Rectangle().fill(Color("#3DB878")) } }.frame(height: 9)
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 1) { ForEach(0..<4, id: \.self) { _ in Rectangle().fill(Color("#F3F5F8")) } }.padding(.top, 1)
            }
        }
        .padding(8).frame(width: 104, height: 76).background(RoundedRectangle(cornerRadius: 4).fill(.white)).modifier(ArtShadow())
    }
}

struct DeckArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(Color("#FDEFED"))
            RoundedRectangle(cornerRadius: 2).fill(Color("#F2554B")).frame(width: 46, height: 6).offset(x: 10, y: 12)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(Color("#C9CFDD")).frame(width: 34, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(Color("#C9CFDD")).frame(width: 46, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(Color("#C9CFDD")).frame(width: 30, height: 3)
            }.offset(x: 10, y: 26)
            PieShape(fraction: 0.75).fill(Color("#F2554B")).frame(width: 28, height: 28).offset(x: 86, y: 22)
            PieShape(fraction: 0.25).fill(Color("#F9B3AD")).frame(width: 28, height: 28).rotationEffect(.degrees(-270)).offset(x: 86, y: 22)
        }
        .frame(width: 124, height: 70).modifier(ArtShadow())
    }
}

private struct PieShape: Shape {
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.midY))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct BookArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).fill(Color("#12ADA6"))
            Rectangle().fill(Color("#0D8C86")).frame(width: 6).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(.white).frame(width: 40, height: 5)
                Capsule().fill(.white.opacity(0.85)).frame(width: 24, height: 4)
            }.offset(x: 14, y: 14)
            Circle().fill(Color("#4FC6C0")).frame(width: 22, height: 22).overlay { Circle().trim(from: 0.55, to: 0.95).stroke(.white, lineWidth: 2).rotationEffect(.degrees(40)) }
                .offset(x: 24, y: 46)
            Capsule().fill(.white.opacity(0.85)).frame(width: 24, height: 3).offset(x: 24, y: 82)
        }
        .frame(width: 68, height: 96).modifier(ArtShadow())
    }
}

struct VectorArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.white)
            Path { p in
                p.move(to: CGPoint(x: 26, y: 62))
                p.addQuadCurve(to: CGPoint(x: 82, y: 62), control: CGPoint(x: 54, y: -2))
            }.stroke(Color("#B04FE0"), lineWidth: 2.5)
            Path { p in
                p.move(to: CGPoint(x: 26, y: 62)); p.addLine(to: CGPoint(x: 40, y: 14))
                p.move(to: CGPoint(x: 82, y: 62)); p.addLine(to: CGPoint(x: 70, y: 14))
            }.stroke(Color("#B04FE0").opacity(0.6), lineWidth: 1)
            ForEach([CGPoint(x: 26, y: 62), CGPoint(x: 82, y: 62)], id: \.x) { point in
                Circle().fill(.white).overlay(Circle().stroke(Color("#B04FE0"), lineWidth: 1.5)).frame(width: 7, height: 7).position(point)
            }
            Rectangle().fill(Color("#B04FE0")).frame(width: 6, height: 6).position(x: 54, y: 13)
        }
        .frame(width: 108, height: 84).modifier(ArtShadow())
    }
}

struct FontArt: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("Aa").font(.system(size: 44, weight: .regular, design: .serif)).foregroundStyle(Color("#7DAB3E"))
            Rectangle().fill(Color("#7DAB3E")).frame(width: 56, height: 2)
        }
        .frame(width: 104, height: 80).background(RoundedRectangle(cornerRadius: 8).fill(Color("#FBFDF6"))).modifier(ArtShadow())
    }
}

private struct SymbolArt: View {
    let symbol: String
    let category: FormatCategory
    var body: some View {
        PaletteReader(category) { p in
            Image(systemName: symbol).font(.system(size: 40, weight: .regular)).foregroundStyle(p.deep)
                .frame(width: 96, height: 80).background(RoundedRectangle(cornerRadius: 8).fill(.white)).modifier(ArtShadow())
        }
    }
}
