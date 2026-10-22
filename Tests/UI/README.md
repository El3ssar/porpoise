# UI tests

Two ways to drive the real app:

- **`acceptance.py`: isolated acceptance run, light and dark.**
  - Builds nothing itself; run it against a test build, `CONFIG=debug scripts/make-app.sh`.
  - It drives the app through its debug bridge: first run (the welcome sheet, Full Disk Access, Not Now), browsing (into
    a folder, Back, view modes), split and resize, a copy and the Activity window, the Connect sheet, and Settings.
  - Each run has its own defaults suite, bridge channel and scratch folder, so it never touches your settings or
    another Porpoise. It stops only the process it started, by PID, also on failure or Ctrl-C.
  - It waits for conditions with deadlines instead of sleeping. Each step has a time limit, and the run stops after
    `--max-failures` failed steps.
  - It keeps `results.json`, `SUMMARY.md` and screenshots under `build/ui-acceptance/<run>/`, plus each failed step's state
    and capture in `failures/`.
  - `SUMMARY.md` keeps three things apart:
    - structural checks, asserted from the app's state;
    - captures for visual review, which aren't asserted;
    - attended checks (keyboard and VoiceOver by hand), which a script can't do.
  - On CI it's `.github/workflows/ui-acceptance.yml`: run it from the Actions tab; it also runs weekly and on pull
    requests that touch this folder. The screenshots are a workflow artifact.
  - Window-server captures need the screen: under Stage Manager, run with the app frontmost (the captures activate it).
    A runner without screen recording gives no captures, which is noted, not failed.

  ```sh
  CONFIG=debug scripts/make-app.sh
  python3 Tests/UI/acceptance.py              # light and dark
  python3 Tests/UI/acceptance.py --looks dark # one look
  python3 -I Tests/UI/test_acceptance.py      # the runner's own self-tests, no app
  ```

- **`smoke.py`: real input events** (scripts/ui.swift) on fixed screen positions, for a person watching. It is older and
  interactive: it uses fixed waits and one shared defaults suite, so it's not part of CI.
