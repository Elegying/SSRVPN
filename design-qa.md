# Design QA

- Source visual truth: `C:\Users\瑞幸\AppData\Local\Temp\codex-clipboard-e6b893eb-5b62-47d2-8cce-ff253a47809b.png`
- Implementation screenshot: `C:\Users\瑞幸\Documents\Codex\2026-07-23\elegying-ssrvpn-https-github-com-elegying\work\design-qa-proxy-mode-implementation.png`
- Combined comparison: `C:\Users\瑞幸\Documents\Codex\2026-07-23\elegying-ssrvpn-https-github-com-elegying\work\design-qa-proxy-mode-comparison.png`
- Test surface viewport: 561 × 640 CSS px at device pixel ratio 1
- Source pixels: 561 × 174
- Captured implementation pixels: 404 × 123
- Density normalization: implementation capture resized to 561 × 174 with Lanczos resampling for the combined comparison
- State: dark theme, intelligent/rule mode selected, TUN disabled

## Full-view comparison evidence

The combined comparison places the supplied reference on the left and the final component render on the right. Both use the same hierarchy: title and route description on the first row, settings/TUN switch at the right, and a centered intelligent/global segmented control below. Component proportions, vertical density, selected-state emphasis, border treatment, and color hierarchy are materially aligned.

## Focused region comparison

No additional crop was needed because the source is already a focused single-component reference and all typography, icons, switch geometry, borders, radii, and selected states remain readable in the combined comparison.

## Required fidelity surfaces

- Fonts and typography: the QA render loads a Windows Chinese font and Material Icons explicitly. Weight hierarchy matches the reference: bold white title, smaller blue route description, muted TUN label, and semibold segmented labels.
- Spacing and layout rhythm: final component ratio is 3.28 versus the source ratio of 3.22. Header spacing, compact switch size, selector inset, and vertical rhythm match after the first iteration.
- Colors and visual tokens: deep indigo card, subtle white border, blue description, muted secondary text, purple selected fill, and purple outline follow the supplied palette.
- Image quality and asset fidelity: the reference contains no raster product imagery. Production uses Flutter Material icons rather than placeholder glyphs or handcrafted vector assets.
- Copy and content: `代理模式`, `国内直连，国外走代理`, `TUN`, `智能`, and `全局` match the reference.

## Comparison history

### Iteration 1

- Finding [P2]: the first implementation was 404 × 143, making the card and switch area visibly taller than the reference after normalization.
- Finding [P2]: outer and segmented-control corner radii were too prominent.
- Fix: constrained the switch to 52 × 32, reduced vertical padding and section gap, inset the segmented control, and reduced outer/inner radii.

### Iteration 2

- Post-fix evidence: implementation is 404 × 123 and normalizes closely to the source’s 561 × 174 composition.
- No actionable P0, P1, or P2 mismatch remains.
- The exact route/title icons differ slightly because the implementation uses the closest existing Material icons, which is acceptable and preserves platform rendering and accessibility.

## Additional requirement

The supplied visual does not include the bottom navigation. The requested Windows/macOS `主页 / 订阅` elevation is implemented as a shared three-layer shadow: deep ambient shadow, subtle blue environment glow, and a near contact shadow. Existing navigation interaction and accessibility behavior are unchanged.

## Final result

final result: passed
