# Development

How the sources are laid out, how to change them, and how to try a change without touching an installed copy. Releasing is in [releasing.md](releasing.md); how the parts work together is in [architecture.md](architecture.md).

## Source layout

```
VERSION                          the release version, the one place it is written (2.3.0)
contracts/
  runtime-status.json            heartbeat keys (engine -> Control Center, page, launcher)
  config-schema.json             config rules, presets and account-vault settings
  window-layout.json             golden vectors for the window layout planner (engine and page)
src/saver/
  engine/00-header.ps1 ...       the engine, in 27 modules by concern (config, process, logs,
    26-main-loop.ps1             executor signal, policy and journal, native accounts, windows,
                                 Volt control, farm freeze, remote session, outcomes, status,
                                 closure, pagefile, version check, startup, native types,
                                 console and graphics, state, logging, privileges, UI, main loop)
  control-center/                the page: 00-head.html, 01-styles.css, 02-body.html, 03-app.js, 04-end.html
  Arkuzo-Memory-Saver.ps1        GENERATED from engine/ (checked in)
  Arkuzo-Control-Center.html     GENERATED from control-center/ (checked in)
  Arkuzo-Control-Center.py       hand-written; its PRESETS/SCHEMA/VAULT_SETTINGS blocks are GENERATED
                                 from contracts/config-schema.json
  Arkuzo-Volt-Control.ps1, Arkuzo-Volt-Probe.py, 00-arkuzo-signal.luau
src/launcher/                    the launcher (C#); Directory.Build.props takes the version from VERSION
build/
  bundle.ps1                     builds the generated files; -Check fails when one is out of date
  dev.ps1                        runs the Control Center and the engine from the sources (below)
  test.ps1, lint.ps1, package.ps1, launcher-build.ps1, verify-release.py
```

The generated files stay checked in under their old names, so the tests, `Arkuzo-Control-Center.cmd`, the package and the launcher use the same single files as before. Bundling is plain concatenation in the order listed in `build/bundle.ps1` (a module missing from that list is an error), plus a one-line "GENERATED" notice and the version from `VERSION`. The engine stays one script because its functions share script-scope state; dot-sourcing modules at run time would change their scope.

## Workflow

1. Edit a module in `src/saver/engine/` or `src/saver/control-center/`, or `contracts/config-schema.json`; never the generated files.
2. `powershell -NoProfile -ExecutionPolicy Bypass -File build/bundle.ps1` rebuilds them.
3. `build/test.ps1 -Filter <names>` while you work, `build/test.ps1` before you commit. `Bundle.Tests.ps1` fails when a generated file is out of date; `test_config_schema.py`, `WindowLayout.Tests.ps1` / `test_window_layout.py` and `test_version.py` fail when a copy drifts from its contract.
4. Commit the modules together with the regenerated files. `build/package.ps1` refuses stale generated files.

Line numbers in error messages and in `lint-math.ps1` findings refer to the generated engine; the function name tells you the module. Save engine modules as UTF-8 with a byte order mark (Windows PowerShell 5.1 needs it for the non-ASCII characters); `Bundle.Tests.ps1` checks it.

## Run from source: `build/dev.ps1`

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build/dev.ps1            # Control Center + monitor-only engine
powershell -NoProfile -ExecutionPolicy Bypass -File build/dev.ps1 -Engine None
powershell -NoProfile -ExecutionPolicy Bypass -File build/dev.ps1 -ForSec 60 -NoWindow
```

It bundles the sources into a fresh copy under `%TEMP%\arkuzo-dev-<id>\runtime`, then starts:

- the Control Center from that copy on a free port (never 48650), with a new data folder `%TEMP%\arkuzo-dev-<id>\data` (seeded from `config/defaults.json`), autopilot off and the saver not started with it. `-DataDirectory` may name a new or empty folder, or one `dev.ps1` made before (it leaves a `.arkuzo-dev` marker); any other folder, the repository's `data` folder and a folder with `accounts.json` are refused, so a real install's data (and its Control Center settings) is never touched. The installed Control Center is never asked to quit: a Control Center only takes over one on its own port serving the same data folder.
- the engine with `-MonitorOnly -Headless` for `-RunForSec` seconds (600 by default). It watches the clients and logs to the dev data folder, but writes no heartbeat, takes no controller lock and never changes, closes or launches a client. In the dev copy the executor `autoexec` sync is switched off, because those folders are shared with any farm on the same PC.

Press Enter (or wait `-ForSec` seconds) to stop both; the data folder is kept. The page of the dev Control Center shows the saver as stopped, because a monitor-only engine writes no heartbeat. Its **Start** button would run a full, controlling engine from the dev copy: it refuses while another controller holds the lock, but never press it on a PC where clients run without one.

`Arkuzo-Control-Center.cmd` still starts the Control Center from `src\saver` against the real `data` folder and port; it is the way to run the sources as *the* farm controller, not next to one.
