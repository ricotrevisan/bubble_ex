# Frozen Input validation audit — 2026-09-10

The user reported seven Bubble editor errors on the generated fixture pages.
The authorized investigation and repairs used `tiptap-plugin`, branch `83jop`
(`bubble-ex`). No changes were made to Test or Live.

## Findings

The screenshot was correct: the percentage and decimal controls stored invalid
format enums and consequently failed Bubble's initial-content type checks.
Screenshot parity with those invalid controls did not establish support for the
intended formats. BubbleEx's normalizer repeated the invalid names, rejecting
valid Bubble definitions instead. Eight existing normalization/export tests
failed when changed to the real enums; all pass with the corrected mappings.

| Case | Intended control | Invalid frozen value | Verified Bubble value |
| --- | --- | --- | --- |
| `bpqkcldq` | Integer Input | `integer` | `int_number` |
| `bpjehwxg` | Decimal Input | `decimal` | `float_number` |
| `bpjehwxg` | Percentage Input | `percent` | `percentage` |
| `bpjehwxg` | Euro date Input | `euro_date` | `date_2` |
| `bpizatjd` | Address Input | `address` | `geographic_address` |
| `bpoyzixi` | Numbers-only Input | `numbers` | `numerical_ref` |
| `bpoyzixi` | Date-and-time picker | `datetime` | `date_time` |

On `83jop`, integer and euro-date had already become plain Text, so they did not
appear in the seven-error screenshot. They still needed restoration to match
their stated cases. Integer now has numeric initial content `12345`; percentage
has numeric initial content `0.25`, visibly rendered as `25%`.

The current Buildprint generated declarations supplied the enum contract; the
applied snapshot confirmed the stored values. `buildprint check` on the four
changed page files passes, but its full check did **not** catch the original
invalid enums. It also reports unrelated errors in existing plugin demo pages.
It is not evidence of a zero-issue Bubble editor. Native editor access was not
available in this session, so no zero-issue editor claim is made.

Subsequent editor verification on the same day resolved the remaining displayed
errors as stale issue-checker results. Visiting the three affected pages reduced
the count from seven to three, then two, then zero, without further source edits.
The user also confirmed that all seven issues were fixed. This later check
supersedes the initial editor-access limitation above.

## Repairs and evidence

- Replaced all four affected frozen payloads with selected-page snapshots from
  the corrected branch, preserving actual Bubble IDs, expressions, and map keys.
- Recaptured both declared viewports for each case in Playwright 1.55.1,
  Chromium 140.0.7339.186 on Linux x86-64. No candidate screenshots became references.
- The source audit records literal Input values; the runner checks them exactly
  against candidate DOM values independently of pixel tolerances.
- Added a source-format validity gate before export, plus offline tests for all
  committed cases and the rejected historical enum names.
- Corrected static percentage, currency, and ten-digit US phone presentation.
  The normalized model retains the underlying values. This is static en-US
  presentation, not Bubble's interactive masking, validation, or locale engine.
- Fixed control-default CSS overriding explicit source border/background paint.
- Removed the percentage case's tolerance for missing format masks. Its corrected
  Linux reference and candidate pass with zero material pixel differences.

The four cases previously proved only parity with incorrectly configured pages;
their former format-support claims should not be relied on. The corrected
references now exercise valid definitions. The audit found no other invalid
Input/DateInput enums in the committed frozen sources.

## Verification

`mix quality` passes: 6 doctests, 672 tests, zero failures (37 excluded).
The production-package consumer smoke test passes. GitHub CI passes all 18
fidelity cases and both Elixir/OTP configurations (1.17/27 and 1.18.4/28.0).
Native secret scanning reports no findings in the four replacement payloads.

Linux ARM reproduced an existing complex-case raster overage on the untouched
commit; Linux x86-64 CI passes. The Docker helper explicitly selects x86-64 and
allows five minutes per test for emulation on Apple Silicon. These runtime
settings do not change any fidelity threshold.
