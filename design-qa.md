# SSRVPN desktop titlebar design QA

## Visual sources

- Existing Windows titlebar: `/var/folders/v7/qkx534l15dz22b1zy4wr_5dh0000gn/T/codex-clipboard-d6798a20-0f46-47ad-a2c1-8f4eadbc627c.png`
- Existing macOS titlebar: `/var/folders/v7/qkx534l15dz22b1zy4wr_5dh0000gn/T/codex-clipboard-79700d8a-c493-4986-a69d-93f67f163a93.png`
- Integrated macOS reference: `/var/folders/v7/qkx534l15dz22b1zy4wr_5dh0000gn/T/codex-clipboard-f093c8c8-3ba9-4c69-a476-63034d0a0b65.png`
- Integrated Windows reference: `/var/folders/v7/qkx534l15dz22b1zy4wr_5dh0000gn/T/codex-clipboard-77a64e13-3462-4305-9e4f-532f90fedb2c.png`

## Implementation evidence

- macOS full-window capture: `/tmp/ssrvpn-titlebar-macos-final.png`
- macOS before/after comparison: `/tmp/ssrvpn-titlebar-macos-final-qa.png`
- Windows focused Flutter render: `/tmp/ssrvpn-titlebar-windows-rounded.png`
- Windows focused before/after comparison: `/tmp/ssrvpn-titlebar-windows-rounded-qa.png`

## Comparison setup

- State: dark theme, disconnected, home screen, default window state.
- macOS viewport: 380 x 796 logical window at 2x display scale; the capture includes the native shadow.
- Windows focused viewport: 638 x 240 at device-pixel ratio 1.0, covering the integrated top surface and all window controls.
- Full-view check: macOS source and implementation were normalized to the same comparison height and inspected side by side.
- Focused check: Windows source and implementation top regions were inspected side by side on a contrasting background so transparent rounded corners remain visible.

## Required fidelity surfaces

- Typography and copy: unchanged; the redundant native/custom `SSRVPN` title was removed only from the titlebar.
- Layout: existing home content remains below the desktop control safe area; the gradient now continues behind the controls.
- Color and surface: no separate gray/black titlebar or separator remains.
- Assets and controls: existing app assets remain unchanged; native macOS traffic lights and accessible Windows minimize/maximize/close controls remain available.
- Corners: Windows uses a 14 logical-pixel Flutter clip plus the Windows 11 DWM rounded-corner preference; maximized windows intentionally use square corners.

## Findings and iteration history

1. Initial comparison found a distinct native/custom titlebar surface and separator on both desktop clients.
2. The desktop backdrop was extended to the window top edge and content was protected with a platform titlebar inset.
3. The first Windows integrated render still had square outer corners. It was corrected with transparent window backing, a 14-pixel content clip, and the native DWM round preference.
4. Final side-by-side review found no remaining P0, P1, or P2 visual mismatch in the requested titlebar and corner scope.
5. Native Windows compositor behavior cannot be captured on the macOS host; it is covered by source-contract tests and remains a Windows-device release check, not a known visual defect.

## Final result

passed
