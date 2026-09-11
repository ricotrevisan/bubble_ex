# Static Dropdown capture investigation — September 11, 2026

The existing `bpqqfagk` frozen case intermittently fails its pixel gate on the
pinned Linux Playwright 1.55.1 / Chromium 140.0.7339.186 browser. Geometry,
document dimensions, computed typography, and selected value remain exact.
This investigation is open; no reference, threshold, browser launch setting,
or generated control code has been changed to turn the failure into a pass.

The first observed failed 390 × 900 capture had 4,160 material changed pixels,
maximum channel delta 232, and mean absolute error 0.226737. Its unchanged
limits are 4,500 / 100 / 0.22. The same exported package subsequently both
passed and failed. Before/after HTML, page CSS, and shared CSS for the group-data
feature are byte-identical. PR78's CI passed without retries, so the unrelated
group-data fix was released with this limitation recorded.

The selected `Beta` glyph shifts vertically by one pixel between candidate
initializations. Three consecutive screenshots within each loaded page are
stable; merely waiting for consecutive equal screenshots would not establish
repeatability across page loads. In a twenty-page diagnostic, nineteen initial
captures used one position and one used the lower position. Reassigning the same
selection did not correct the latter. Temporarily changing and restoring the
font family made all twenty use the lower position. That DOM perturbation was
diagnostic only and is not an adopted rendering fix.

Read-only checks of the authorized `tiptap-plugin` branch `83jop` found the same
declared control values and dimensions: static Alpha/Beta/Gamma choices, Beta
default, Inter 16 px / 500, 44 px height, 8 px / 12 px padding, and a 1 px border.
The source font bytes have the existing pinned SHA-256
`3100e775e8616cd2611beecfa23a4263d7037586789b43f035236a2e6fbd4c62`.
Fresh source captures at 390 and 1440 px consistently use the lower text
position. The fresh 390 px source and the failed candidate differ in only
15 raw pixels across the entire page.

There is also a separate host-rasterization difference: the older Debian source
reference has grayscale text antialiasing, whereas the current Ubuntu image
defaults to LCD subpixel antialiasing. This host difference was already recorded
in the case's pixel-allowance rationale. Eight private candidate probes with
`--disable-lcd-text` came within 2–4 material pixels of the old reference, each
with maximum channel delta 1. However, fresh source captures with that flag
still differ in the dropdown text position (153 material pixels, maximum delta
232). The flag therefore does not by itself reconcile source and reference.
Further private inline-font and font-face variants also failed to establish a
repeatable correction.

Private artifacts remain under `_build/landing-group-regression/`, including
the failed package comparison, repeated candidate captures, source probes,
and their measurement JSON. Authenticated source credentials were supplied
only through origin-scoped environment variables and are absent from artifacts.
The source app was not modified. Existing committed source references remain
the gate; neither a passing retry nor this diagnosis establishes 100% fidelity.
