## What this changes

<!-- What it does and why. Link the issue if there is one. -->

## Checklist

- [ ] `swift build` compiles with no warnings
- [ ] `swift run SuperConverterSelfTest` passes, with cases added for new logic
- [ ] `swift run SuperConverterQualityBench` (fast tier) passes; a conversion change has a bench case that fails without it
- [ ] Routes come from `format-matrix.json` (regenerated with `scripts/gen-format-matrix.py`, not edited by hand) and `App.everyRouteHasAConverter` stays green
- [ ] UI changes include a render (`SUPERCONVERTER_RENDER_DIR`) and follow `docs/specs/ux.md` and the mockups
- [ ] Behaviour changes are reflected in `docs/specs/` and, if users will notice, `docs/USAGE.md`
- [ ] CHANGELOG.md has a line under *Unreleased*
- [ ] Anything that touches the network or stored data has its switch and is described in PRIVACY.md
- [ ] No GPL/AGPL code linked, loaded or ported; ports carry provenance and a THIRD_PARTY_NOTICES.md section
- [ ] Superseded code, helpers and tests are removed in this change
