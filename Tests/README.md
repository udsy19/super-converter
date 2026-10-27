# Tests

Layout of the quality bench's data (`Sources/SuperConverterQualityBench`, quality §9):

- `Corpus/generated/` — small committed fixtures, written by `swift scripts/make-fixtures.swift` (synthetic images with known
  colours, test tones, SMPTE-style bars, DOCX/ODT/XLSX/EPUB/CBZ/DXF/PDF samples). Under 40 MB in total.
- `Corpus/external/` — larger third-party files, git-ignored, fetched on request by `scripts/fetch-corpus.sh` and pinned by
  SHA-256 in `Corpus/corpus.lock`. Nothing in the tests runs it; cases that need a file that is not there are skipped.
- `Golden/<case-id>/` — what `--bless <case-id>` wrote: `metrics.json` (thresholds, accepted values, output hashes for
  `exactOutput` cases) and any expected outputs. A PR that blesses says why.

Run it: `swift run SuperConverterQualityBench [--tier fast|full] [--only <id>[,<id>…]] [--bless <id>] [--list] [--validate-only]`.
The metrics are checked against published values first (CIEDE2000: the 34 pairs of Sharma et al.; SSIM and MS-SSIM: analytic
cases; PSNR; THD+N: 6.02 N + 1.76 dB; loudness: EBU Tech 3341 tone via `ffmpeg ebur128`; SHA-256: FIPS 180-2). The report is
`.build/quality/index.html` (and `report.json`).

## Adding cases for a kit

1. Fixtures: add a function to `scripts/make-fixtures.swift` (or a line to `Corpus/corpus.lock`), re-run the script, commit the output.
2. Cases: `Sources/SuperConverterQualityBench/Cases/<Kit>Cases.swift`, an `enum <Kit>Cases { static let all: [BenchCase] }`.
   Each `BenchCase` names a fixture, a target format and `checks`; build the checks from `Harness/Checks.swift` or write
   `Check(name:) { ctx in … }` returning `Measurement`s with the threshold from quality.md. Use `route:` to run converters
   straight through when the planner route needs a kit that is not built yet.
3. Register: add `<Kit>Cases.all` to the list in `Cases/CaseRegistry.swift`.
4. A new metric goes in `Metrics/` with a published reference value in `Harness/MetricValidation.swift`.

A pair the planner cannot run on this Mac (helper missing, engine unavailable) is reported as skipped, never as passed.
