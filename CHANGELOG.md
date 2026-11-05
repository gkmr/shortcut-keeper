# Changelog

## 1.0.0 (2026-11-05)
- First public version, taken from the setup that runs daily on the author's Mac (internal versions v1 to v109).
- `keeper_core.py`: the desired-versus-actual comparison, clash rule, snap panel generator and fix safety gate moved out of
  `keeper.py` and `scan.py` unchanged, so they run in Linux tests.
- `SHORTCUT_KEEPER_HOME` replaces the hard-coded project path in every script, Key Deck and the Raycast extension.
- Optional hooks instead of personal plumbing: `SHORTCUT_KEEPER_NOTIFY` (notifier), `SHORTCUT_KEEPER_CALL_HOOK`
  (call recorder status), `SHORTCUT_KEEPER_SCAN_JSON` (replay a saved scan).
- keeper.py writes its shortcut history to `reports/CHANGELOG.md`, so it never touches this file.
- Off macOS, rules are skipped with one info line instead of failing.
- Tests: `tests/run_all.sh` (28 unit and end-to-end tests, 168 layout checks, 38 call detection cases, 5 recheck steps).
- Examples: a 15-entry `keys.example.json`, healthy and drifted scan fixtures, layout fixture, notifier and LaunchAgent templates.
