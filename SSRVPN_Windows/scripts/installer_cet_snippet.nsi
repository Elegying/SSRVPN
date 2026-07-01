; ──────────────────────────────────────────────────────
; SSRVPN Installer — CET Compatibility snippet
; ──────────────────────────────────────────────────────
; Include this section in your NSIS/Inno Setup script.
;
; This writes a per-process CET exemption so SSRVPN can run on
; Windows 11 25H2+ (Build 26200+), where CET Shadow Stack is
; enforced in hardware.
;
; Requires: admin install (already needed for TUN mode)
; ──────────────────────────────────────────────────────

; ── NSIS (install-time) ──
Section "CETCompatibility"
  ; Run the bundled PowerShell fix script silently during install
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$INSTDIR\ssrvpn_cet_fix.ps1" -ExeName "ssrvpn_windows.exe"'
  Pop $0
  ${If} $0 != 0
    ; Non-fatal: the launcher has its own fallback
    DetailPrint "CET fix script returned $0 (launcher fallback active)"
  ${EndIf}
SectionEnd

; ── NSIS (uninstall-time cleanup) ──
Section "un.CETCompatCleanup"
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" \
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$INSTDIR\ssrvpn_cet_fix.ps1" -Uninstall'
  Pop $0
SectionEnd
