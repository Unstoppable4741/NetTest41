# DEVELOPMENT — NetworkTester

White-label notes for continuing development of this project.

## Repo

- GitHub: `git@github.com:Unstoppable4741/NetTest41.git` (public, branch `main`)
- Local: `/home/kkirov/pCloudDrive/WindsurfProj/NetworkTester/`
- Remote-run (Windows 10/11): `irm https://tinyurl.com/2ahbcar4 | iex`
  or `irm https://github.com/Unstoppable4741/NetTest41/raw/main/nt.ps1 | iex`
- `nt.ps1` is a bootstrap that downloads and `iex`-es `NetworkTester.ps1`.

## Hard compatibility constraints — DO NOT BREAK

Target: Windows PowerShell 2.0 / .NET 3.5 (stock Windows 7) AND PS 5.1 (Win10/11).

- `NetworkTester.ps1` MUST stay **UTF-8 with BOM + CRLF** (Cyrillic UI text; PS2 misreads BOM-less UTF-8). After editing verify: `head -c3` → `ef bb bf`; `file` → CRLF; `grep -c $'\r\r'` → 0.
- Forbidden constructs (PS3+/newer): `[ordered]`, `::new()`, `$PSScriptRoot`, `Invoke-WebRequest`/`Invoke-RestMethod` (inside the script), `Test-NetConnection`, `Get-NetAdapter`, `Get-NetIPConfiguration`, `Get-NetRoute`, `Get-PhysicalDisk`, `Optimize-Volume`, `Get-CimInstance` (use `Get-WmiObject`), `$using:`, `Start-Job`, `[pscustomobject]` cast (use `New-Object PSObject -Property`), `ConvertTo-Json`, `Unblock-File`, `.Where()`/`.ForEach()` methods, `??`, `-in`, `-notin`, `Register-ObjectEvent`, `add_Xxx` C# event accessors (`$btn.Add_Click({...})` is the correct PS pattern).
- Single-threaded UI: every long loop must call `Do-Events` and `Stop-Check` (Stop button support). No threads/runspaces/jobs. Async I/O only via .NET `BeginXxx` + polling `IsCompleted`/`WaitOne(0)`.
- `int + "string"` throws in PS: always prefix numeric-left concat with `""`.
- External exes allowed: `netsh`, `arp`, `fsutil`, `defrag`, `dism`, `mdsched`, `powershell`.

## Architecture

One file `NetworkTester.ps1` (~3300 lines):
- Helpers at top: `Write-Log` (Info/OK/Warn/Fail/Header → colored RichTextBox + `$script:LogLines`), `Do-Events`, `Set-Status`, `Stop-Check`, `Add-Result` → `$script:Results` → `Write-Summary`, `Resolve-Target`, `Test-TcpPort`, `Save-LogToFile`, `Complete-TestRun` (restores ALL buttons + saves log to Desktop).
- Orchestrators (each follows same skeleton: `$script:Running` guard → reset flags → `Results.Clear()` → marquee → try{tests} finally{Complete-TestRun}):
  `Start-AllTests`, `Start-LoadTests`, `Start-QuickTest`, `Start-Monitor`, `Invoke-NetworkScan`, `Show-SystemInventory`, `Show-DiskMaintenance`, `Test-Memory`.
- GUI block guarded by `if (-not $env:NETWORKTESTER_NOGUI)` — logic functions can be dot-sourced headless for testing.
- Settings persisted to `%APPDATA%\NetworkTester\settings.txt` via `Load-Settings`/`Save-Settings` (key=value, 10 keys).
- Log auto-saved to `Desktop\NetworkTester_YYYY-MM-DD_HH-mm-ss.txt` after every run.

## Buttons (bottom row y=610): Запази(10,120) Копирай(140,120) Изчисти(270,120) Сканирай LAN(400,140) Машина(550,110) Дискове(662,60) RAM(726,64) — full, widen form or add row for new buttons.
## When adding a button: extend `Complete-TestRun` params (null-guarded), update ALL call sites, disable/enable consistently in every handler.

## Testing

No PowerShell on dev machine (Linux). Verify structurally: forbidden-token greps, brace/paren balance, BOM/CRLF. Real smoke test must be done on Windows (esp. Win7/PS2 for compat).

## Feature ideas backlog (discussed, not implemented)

- Comparison with previous test run; sound/visual alert options; HTML report export; scheduled monitoring; iperf-style throughput server mode.
