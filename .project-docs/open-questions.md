# Open questions

- The historical STT watchdog incident has no captured provider frame trace.
  Manual finalization is supported and verified on synthetic audio; whether
  the original stall was caused by the network or provider remains unknown.
- Reasoning-token counts for the historical slow cleanup were not recorded.
  New local diagnostics enable future attribution without recording content.
- The [Computer Use input-duplication bug](bugs/2026-10-20-computer-use-input-duplication.md)
  remains open. Its exact trigger and permanent fix are unknown; helper recovery
  and persistent-filter observations do not prove the native defect.
- On macOS 27.3 beta 2 the onboarding leads through + in System Settings and restarts Whytap after the grant. Not yet verified on a fresh install: the automatic restart and resume, and whether macOS still asks a new app for system audio (System Audio Recording Only). [Evidence and acceptance limits](decisions/2026-11-23-keyboard-control-protection-override.md)
