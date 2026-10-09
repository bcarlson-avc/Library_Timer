# AVC Public Access Client deployment

This package installs the current Client, production-enforcement Service, and Watchdog, plus Inno Setup's generated uninstaller. It does not install the Server. No installer is executed by the build or validation scripts.

Version **1.0.0** is controlled in `version.json`; no earlier project version scheme was found. Build tools are .NET SDK **10.0.401**, PowerShell 7, Inno Setup **7.1.0** (x64 edition), Python 3.11+ and an innoextract build supporting Inno's **7.0.0.3** data format (older stable 1.9 does not). For the Linux validation environment, innoextract PR 210 at `376a13e` (with a correction to recognize absent optional ISSig hashes; archive data checksums remain enabled) and Wine 10.0 are used outside the repository. Windows is required for deployment and runtime verification. Windows x64 10 1809+ is the installer minimum; use an OS supported by .NET 10 and the college's security policy. Published payloads are self-contained `win-x64`, so no separate .NET runtime installation is needed. Build prerequisites are not deployed.

## Build and inspect without installation

From the repository on `main`, with the pinned SDK active:

```powershell
pwsh -NoProfile -File deployment/scripts/Build-Package.ps1 `
  -Iscc 'C:\Program Files\Inno Setup 7\ISCC.exe' `
  -InnoExtract 'C:\Tools\innoextract\innoextract.exe' -Python python
pwsh -NoProfile -File deployment/tests/Test-Deployment.ps1
```

The Linux build additionally accepts `-Dotnet /path/to/dotnet -Wine /path/to/wine -Iscc /path/to/ISCC.exe -InnoExtract /path/to/innoextract -Python python3`. Set `WINEPREFIX` to a dedicated compiler prefix and provide a display if the compiler requires it. The 64-bit Inno 7 compiler avoids this cloud host’s unsupported 32-bit execution. Only ISCC is executed through Wine; the generated installer and application executables are never launched. Review official tool signatures/checksums when provisioning them. Inno Setup's license applies; obtain any required commercial license before institutional distribution.

Every invocation deletes only its own fixed `Build/Installer` directory and copies allowlisted **current tracked source files** into an empty source tree. It rejects unrelated application changes; the sole allowed installation-support edit is the Service hosting name. It freshly restores/publishes all three projects in Release, omits development settings/launch profiles and PDBs, verifies self-contained x64 executables and the exact PNG bytes in the Client DLL, generates a payload/input SHA256 manifest, compiles, and extracts the **actual installer**. All extracted payloads must match fresh staging byte for byte, with no missing/extra files; the actual embedded Inno installer/uninstaller engine is decompressed with block/engine CRC verification, and compiled header fields must confirm Uninstallable, ARP registration, AppId, publisher, version and x64 architecture. Configuration is checked against the reviewed credential-free source template. No Archive, FinalRelease, existing install, old publish, or old bin/obj outputs are inputs. Source commit and all input hashes make uncommitted installer/support changes traceable. This is repeatable fresh-input building, not a claim that timestamps/signatures produce identical installer hashes across runs.

Output: `Build/Installer/output/AVCPublicAccess-Client-Setup-1.0.0-win-x64.exe`, `SHA256SUMS.txt`. Evidence: `Build/Installer/logs/`, `stage/Deployment/payload-manifest.json`, `extracted/`. Build output is ignored by Git. The package includes no databases, Server payload, certificates, passwords, access codes, development/source files, or backups. The one packaged PowerShell script is required runtime **installation support**, not application source. Treat the initial package as unsigned until a college code-signing certificate is selected; sign, verify, and rehash the final distributed installer. No certificate or secret belongs in this repository.

## Installed layout and ownership

```text
C:\Program Files\AVC\PublicAccess\
  AVCPublicAccess.Watchdog.exe + its self-contained runtime files
  Client\AVCPublicAccess.Client.exe + dependencies/resources
  Service\AVCPublicAccess.Service.exe + dependencies + appsettings.json
  Deployment\Deployment.ps1 + payload-manifest.json
  unins000.exe + unins000.dat  (created by Inno Setup at installation)
```

The Watchdog is deliberately at the root to preserve its existing `<Watchdog directory>\Client\AVCPublicAccess.Client.exe` lookup. There is only one Client. Its existing embedded AVC logo works independently of the Server; no separate runtime logo dependency is added.

All installation/configuration operations are elevated. Normal applications do not write to Program Files. Patrons retain read/execute permissions there. The installer creates `%ProgramData%\AVC\PublicAccess` with SYSTEM/Administrators full control and Users read/execute, and precreates `watchdog.log` with Users read/write on **that file only**. No Users directory write/delete grant is added. The log ACL accommodates the existing Watchdog without changing its source; log rotation is a future application change, so monitor size while thawed. No firewall exception, external listener, HTTP URL ACL, account/password, autologon setting, or Deep Freeze exclusion is added. The LocalSystem Service owns the existing loopback-only API on `127.0.0.1:5051`.

## Prompts, configuration and upgrades

Interactive Setup prompts for a hostname/IPv4 address (initially blank) and numeric TCP port (default 5000; range 1–65535). URI syntax, credentials, paths, invalid IPv4 and unsafe characters are rejected. No pilot hostname is embedded in the package. An optional **Test Connection** sends an unauthenticated HTTP GET `/`, with redirects disabled; any HTTP response proves connectivity only, not that AVC redemption works. It does not send access codes or credentials. Deployment is HTTP because that is the current application protocol; TLS architecture is outside this change.

Existing `Service\appsettings.json` is read to prepopulate the host/port; invalid or unsupported existing configuration is not silently replaced. Inno copies the source template only if missing. The deployment helper atomically updates **only** `PublicAccess.ServerAddress` to `http://<address>:<port>`, retaining Location, HeartbeatSeconds, Logging and additional existing settings. Existing secret values, if any, are not printed or packaged. The script is not a general configuration/credential manager.

Setup requires the administrator to confirm the machine is **THAWED** with no active patron. That is an administrative confirmation, not automated Faronics-state detection. Unattended installation is disabled so the prompts cannot be bypassed accidentally. Upgrades reuse the Inno AppId and prior installation path; address/port need not be reentered. Preflight rejects conflicting Service/task ownership, legacy differently named AVC Services, active sessions, and either saved enforcement-state file. It does not cancel a pending reboot or erase patron state. A controlled real reboot while thawed must let the existing Service remove prior-boot state; malformed/legacy state needs administrator review before servicing. Legacy deployments in another directory require a separately reviewed migration; this package never silently takes over them.

Before file replacement, Setup disables/stops its task, stops only Watchdog/Client processes with exact installed executable paths, rechecks session state, and stops the owned Service. If an in-flight redemption persisted state during Service shutdown, the helper resumes existing same-boot enforcement and refuses replacement/removal; it never clears the state. Interrupting a failed upgrade can leave startup stopped/disabled; do not freeze it or consider it deployed. Repair by rerunning Setup while thawed after reviewing state/configuration. The installer does not promise transactional rollback of Windows configuration or configuration values.

## Service and interactive startup

The helper uses `sc.exe create` or `sc.exe config` to register **AVCPublicAccessService**, display name **AVC Public Access Service**, executable `"<root>\Service\AVCPublicAccess.Service.exe"`, own process, Automatic, LocalSystem. The only application-source change aligns `AddWindowsService`'s hosting name with this SCM name; no enforcement, session, timer, UI, accessibility, Service protocol or reboot code changes. Application Event Log sources are registered for the SCM identity and the existing .NET logging source `AVCPublicAccess.Service`.

After registration, Setup starts the Service, waits up to 30 seconds for Running, then up to 30 seconds for the local `/status` API to report **Available**, **TestMode=false**, with the Service still Running. Failure is an explicit setup error, not a success screen; consult the Windows Service/Application logs and keep the workstation thawed. A later service crash is not ruled out by this installation-time check and must be covered by runtime tests.

The installer registers one root scheduled task, **AVC Public Access Watchdog**, triggered at interactive logon, group principal Builtin Users (`S-1-5-32-545`), least privilege, no password, no execution time limit, IgnoreNew instances, and restart-on-failure. It starts the Watchdog on the logged-on patron's desktop; the unchanged Watchdog starts the Client and checks for it every three seconds. Setup does not launch it on the elevated administrator desktop. Log off and log on as the actual public-computer user to verify startup. Existing college Windows autologon/GPO must supply the patron logon after reboot; configuring Windows autologon is outside this installer.

The current Watchdog checks Client processes globally, so this design requires a **single interactive patron session** per workstation. Multiuser/RDP behavior requires a future architecture change and is not claimed supported. A logon-trigger task running under a group principal and least-privilege log permissions must be tested with the actual pilot account before freezing.

## Add/Remove Programs and uninstall

Inno Setup creates the Windows Add/Remove Programs registration under its fixed AppId: DisplayName **AVC Public Access**, Publisher **Antelope Valley College**, DisplayVersion **1.0.0**, UninstallString pointing to the **actual generated `unins000.exe`** in the root. There is no custom uninstaller executable.

The Inno uninstaller confirms THAWED/no patron session and performs preflight before removal. The helper disables/stops the owned task, stops exact installed Watchdog/Client processes, stops and deletes the owned Service, unregisters its task, and waits for Service deletion. A failure aborts removal and must be investigated before freezing. Inno removes only its logged installed payloads and generated uninstaller/registration, then removes directories if empty. No broad recursive deletion is used. Existing `Service\appsettings.json` is retained intentionally so reinstall/upgrade can recover the endpoint; therefore the installation directory remains when configuration or unrelated files remain. ProgramData and Event Log source are retained for administrator review; no session state is deleted. No URL ACL/firewall rule was created to remove. Verify actual registration and file removal on Windows; static package extraction cannot prove installed ARP state.

## Deep Freeze procedure and runtime writes

**THAW → INSTALL/UPDATE → CONFIGURE → VERIFY → TEST → FREEZE**. Do not freeze with an active patron, state files, pending reboot, failed install, disabled task or stopped Service. No persistent volume, ThawSpace or exclusion is required or created. Configuration, binaries, Service/task registrations and initial permissions are part of the verified clean frozen baseline.

| Writer / location | Purpose | Persistence requirement |
|---|---|---|
| Service: `%ProgramData%\AVC\PublicAccess\session-state.json` and `.tmp` | Atomic authoritative session/deadline/reboot marker; survives Service/process restart during the **same boot** | Must survive process failure in the current boot; must **not** preserve a previous patron across reboot. Service rejects malformed state, removes valid prior-boot state; Deep Freeze restores the clean no-session baseline. |
| Watchdog: same directory, `watchdog.log` | Append startup/recovery diagnostics | Disposable across Deep Freeze reboot; log file and ACL exist in baseline. No directory write needed by patrons. |
| Service: Windows Application Event Log | Startup/enforcement/failure diagnostics | Disposable locally across restore; collect pilot evidence while thawed. No new persistent logging mechanism. |
| Client | Inspected code writes no application files during sessions | In-memory UI/session values are disposable. WPF/.NET/Windows may use user TEMP/cache/crash/WER locations; disposable, no exclusions needed. |
| Service / Watchdog runtimes | OS-managed TEMP, .NET diagnostics/crash dumps if enabled externally | Disposable; no repository code requests a persistent crash dump or writes to Program Files. |
| Installer: Service config, Program Files, task/SCM/ARP registry, `%TEMP%` Setup log, runtime directory/log ACL | Installation/admin changes only while thawed | Verified installation/configuration must be in the clean frozen baseline. Setup logs/temp are disposable. |

If future requirements mandate persistent audit logs, explain the retention need and secure an external destination separately. This package does not invent persistence solely for Deep Freeze. Session expiration's forced automatic reboot is intentional and unchanged.

Pilot: Server **MH109-04886**, Client **MH125-01182**. No deployment on either machine occurs during this build stage. When Windows installation is separately authorized, enter the Server name and actual port in the wizard. Future updates use the same thaw/reboot/no-state/preflight/install/configure/patron-logon/test/freeze sequence.

### Required Windows runtime validation before deployment approval

1. While thawed, record installed version/hash, Deep Freeze state, any legacy services/tasks/paths, and no patron state. Ensure no scheduled shutdown. Verify network and separate Server health. Save configuration securely.
2. Install as admin. Verify actual ARP Publisher/Version/UninstallString, `unins000.exe`, exact payload hashes, only one Client, embedded logo on both screens, config endpoint, Service identity/Automatic/LocalSystem/Running and local Available/TestMode=false. Verify Users cannot alter binaries/config/state or replace log, but the patron can append the log.
3. Log on as the real least-privilege patron. Verify Watchdog/task and Client appear on the correct desktop; kill only Client and verify Watchdog relaunch. Exercise existing access-code UI, screen reader, keyboard, warnings and session flow. Build-only inspection does **not** prove this behavior.
4. While thawed, test controlled expiration/reboot and same-boot Service restart/recovery with safe test data, without clearing enforcement state. Verify independent Service expiration, real forced reboot and clean Available/no prior patron after boot and patron logon.
5. Test an upgrade with a nondefault configured port and confirm preservation; test invalid address/ports, unreachable Server, Service startup failure, ownership collisions and saved-state blocking; confirm failed installs are clearly reported and remain thawed. Test generated uninstall and reinstall while thawed, actual SCM/task/ARP removal, retained config and unrelated files, and no Watchdog relaunch after uninstall.
6. Reinstall/verify a clean no-session baseline, freeze, then test **FROZEN → patron session → expiration → Windows reboot → Deep Freeze restore → automatic Service + patron Watchdog/Client startup → Available/no prior patron**. Confirm frozen restoration preserves configured endpoint and baseline log ACL but discards patron state/log additions. Collect results externally before reboot if needed. No installer execution, reboot, or Deep Freeze test is claimed by static validation.
