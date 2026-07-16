# 模型质量矩阵 Design QA

## Evidence

- Source visual truth: `/var/folders/2w/0d5zh1115l11ghtm7jmy32mm0000gn/T/codex-clipboard-9e5a1812-372c-43e8-b9ee-94ccc7a8a622.png`
- First integrated app capture: `/var/folders/2w/0d5zh1115l11ghtm7jmy32mm0000gn/T/codex-clipboard-720a8263-0498-4b0a-bc5f-6fd53cf360fb.png`
- Selection-state feedback capture: `/var/folders/2w/0d5zh1115l11ghtm7jmy32mm0000gn/T/codex-clipboard-c4a59016-d776-4b27-93e3-fa7ab08b1598.png`
- Post-fix focused render: `/tmp/codexbar-matrix-rendered.png`
- Latest side-by-side comparison: `/tmp/codexbar-rank-comparison.png`
- Crown iteration comparison: `/tmp/codexbar-crown-comparison.png`
- Viewport: 300pt menu-bar popover; focused matrix render is 300pt wide at 2x scale.
- State: read-only matrix with no selection, CodexRadar ordering, top-three rank markers, all five standard effort columns visible, unavailable combinations disabled.

## Comparison history

### Pass 1

- P2: The integrated capture showed a thick purple keyboard-focus ring around `Terra max`, competing with the blue pinned-selection outline.
  - Fix: matrix cells are explicitly non-focusable; click and hover remain the only direct interactions.
- P2: Available values were not differentiated clearly enough by benchmark status.
  - Fix: score text and a restrained cell tint now use the existing success, warning, and danger semantic colors; selection continues to use only the blue outline.

### Pass 2

- The focused post-fix render has one unambiguous blue selection outline and no residual focus control.
- Normal values read green, warning values amber, and missing values remain neutral gray.
- Hover/click hit areas, five-column alignment, compact headers, row icons, and footer stay inside the 300pt width.

### Pass 3

- P2: User feedback rejected the remaining pinned-selection state and requested explicit first/second/third ranking.
  - Fix: removed click handling, pinned state, blue selection outline, and selected accessibility trait.
- P2: Ranking needed to follow CodexRadar's visible order when IQ scores tie.
  - Fix: rank by IQ descending, then the site's `Sol → Terra → Luna` family order and `max → xhigh → high → medium → low` effort order.
- P2: The first compact rank badge treatment collided with three-digit IQ values.
  - Fix: reserved a dedicated 12pt badge row inside each podium cell; the final comparison shows no overlap.
- Final render: first place `Sol medium`, second place `Luna max`, and third place `Sol max` are distinct, readable, and color-coded gold/silver/bronze.

### Pass 4

- P2: Numeric podium badges felt visually heavy and looked like generic notification counters.
  - Fix: replaced `1/2/3` circles with the native filled-crown symbol, colored gold, silver, and bronze by rank.
- Ranking remains available in the detail line and accessibility labels, so the icon-only treatment does not remove semantic information.
- Final comparison confirms the crowns remain distinct at 300pt width without colliding with three-digit IQ values.

### Pass 5

- P2: Crown color alone did not distinguish gold from bronze reliably at small size.
  - Fix: retained each colored crown and added its rank number as lightweight inline text, without restoring the circular notification-badge treatment.

### Pass 6

- User requested the horizontal effort scale to begin at the lowest reasoning level.
  - Fix: reversed the visible standard columns to `low → medium → high → xhigh → max`; podium tie-breaking remains aligned with CodexRadar's original ordering.

## Fidelity surfaces

- Typography: native system typography and monospaced digits match the app; hierarchy remains compact and legible.
- Spacing and layout: stable row labels, equal-width effort cells, and a single-line detail footer preserve the reference hierarchy at the narrower production width.
- Colors: semantic green/amber/red communicates benchmark status; gold/silver/bronze communicates rank without a selection color.
- Assets: native SF Symbols are used for family, refresh, and external-link icons; no raster or placeholder assets are introduced.
- Copy: localized relative time, full model/effort detail, IQ, pass count, empty state, help, and accessibility labels are present in Chinese and English.

## Result

final result: passed
