import Foundation
import SuperConverterCore

/// Every bench case, by kit.
///
/// Adding cases for a kit (ImageKit, MediaKit, TypesetKit, ArchiveKit, VectorKit, FontKit, …):
///   1. Put the kit's inputs in `Tests/Corpus/generated/` by extending `scripts/make-fixtures.swift` (small, synthetic,
///      reproducible), or list a download in `scripts/fetch-corpus.sh` (lands in `Tests/Corpus/external/`, git-ignored).
///   2. Create `Cases/<Kit>Cases.swift` with `enum <Kit>Cases { static let all: [BenchCase] = [...] }`. A case names a fixture
///      (relative to `Tests/Corpus/`), a target format, optional options/look, and `checks`, built from the reusable ones in
///      `Harness/Checks.swift` (`.producesFormat`, `.pdf`, `.textContains`, `.zipEntryContains`, `.roundTrip`, `.imageMatches`)
///      or a `Check(name:) { ctx in … }` of your own that returns `Measurement`s with the threshold from quality.md.
///      Use the noise-band constructors (`.ssim`, `.deltaE`, `.psnr`) so regressions inside the threshold are caught.
///      A new metric belongs in `Metrics/` with a published reference value in `Harness/MetricValidation.swift`.
///   3. Add `<Kit>Cases.all` to the list below. Case ids are `<kit>.<name>`, lower case.
///   4. `swift run SuperConverterQualityBench --only <id>` runs one case; `--bless <id>` writes `Tests/Golden/<id>/metrics.json`
///      (thresholds, accepted values, and output hashes when `exactOutput` is set) — say why in the PR.
/// A pair the planner cannot run on this Mac (helper missing, engine unavailable) is reported as skipped, never as passed.
enum CaseRegistry {
    static var all: [BenchCase] {
        let cases = [
            CADKitCases.all, DocKitCases.all, ImageKitCases.all, LayoutKitCases.all, OfficeKitCases.all, EbookKitCases.all, HelperKitCases.all, SampleCases.all,
        ].flatMap { $0 }
        precondition(Set(cases.map(\.id)).count == cases.count, "duplicate bench case ids")
        return cases
    }
}
