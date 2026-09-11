---
source: "delegate-20260910-191536/verify/notes.md — round 1 simulator verification attempt, 2026-09-10 22:23"
---

Notes start Thu 10 Sep 2026 21:55:45 AEST
Device booted: iPad Pro 11-inch (M5) UDID=057AEF13-C378-44C3-8909-158E17858EE0
BUILD SUCCEEDED - proceeding to install
install and spawn hung >5min - simulator server unresponsive (consistent with prior -308 server-died issue). Killing and doing shutdown+erase+reboot once per brief.
bootstatus -b hung despite device list showing Booted; killed it and proceeded. This matches known simulator server flakiness.
Second install attempt (after erase+reboot) also hung >2min with zero CPU progress. This is the server-died pattern manifesting as install hang rather than launch failure.
Device SHUT ITSELF DOWN during 3rd install attempt (spontaneous, not initiated by us). This confirms the underlying CoreSimulator server-died instability from the brief - it recurred even after the one authorized erase+reboot retry.
Killed my own stuck xcodebuild test (pid 48179) after finding it deadlocked on kelpie-dd/CompilationCache.noindex/generic/lock, held concurrently by another process (pid 44276, xcodebuild test -only-testing:HeelerTests/TerminalMouseReportingTests, running since 10:05PM using the SAME derivedDataPath/clonedSourcePackagesDirPath given in this brief). This is almost certainly another agent/session sharing the same scratchpad paths. Did not touch pid 44276 (out of scope - not mine).
Confirmed actual -308 error in test.log: 'Mach error -308 - (ipc/mig) server died' during installApplication. Device now Shutdown. Retrying once per brief (shutdown already done, booting now).
test2 (my retry) FAILED with 'database is locked... two concurrent builds running in same filesystem location' on kelpie-dd/Build/Intermediates.noindex/XCBuildData/build.db - NOT a -308 error.
Discovered pid 49817: ANOTHER concurrent xcodebuild test process using the IDENTICAL derivedDataPath/clonedSourcePackagesDirPath given in my brief, already running -destination iPhone 17 -only-testing:HeelerTests/TerminalMouseReportingTests - i.e. another run of this exact same task, already at the iPhone-17-fallback stage. Stopping further attempts to avoid sabotaging that concurrent run via more lock contention.

=== FINAL SUMMARY ===
1. Build: SUCCEEDED (verify/build.log)
2. Install/launch on iPad: FAILED. Repeated "Mach error -308 - (ipc/mig) server died". Performed the one authorized erase+reboot retry (xcrun simctl erase then boot) - failure recurred (device spontaneously shut down mid-install). Kelpie was never successfully installed on the device.
3. No app screenshots exist (01-launch.png etc were never reachable). Only diagnostic screenshots of the iOS boot screen exist: debug-simstate.png, debug-simstate2.png.
4. Test run: first attempt (test.log) failed with the same -308 error. Retried once per brief authorization (test2.log) - failed differently: "database is locked ... two concurrent builds running in the same filesystem location" on kelpie-dd/Build/Intermediates.noindex/XCBuildData/build.db.
5. Root cause of #4: discovered pid 49817, ANOTHER xcodebuild test process using the IDENTICAL clonedSourcePackagesDirPath/derivedDataPath given in this brief, already executing this exact brief's own iPhone-17-fallback step (-destination iPhone 17 -only-testing:HeelerTests/TerminalMouseReportingTests). This is a concurrent/duplicate execution of this same task sharing scratchpad paths, not a Kelpie defect. Did not touch that process (out of scope).
6. Final iPad simulator state: Booted, left running per instructions. Kelpie app is NOT installed on it (install never completed cleanly).
    iPad Pro 11-inch (M5) (057AEF13-C378-44C3-8909-158E17858EE0) (Booted) 
