# Dev Control - fix log

Build / install problems that were hit and fixed. Add new entries as FIX-00N.

### FIX-001 - rebuilding fails while Dev Control is running (icon file locked)
**Symptom:**
```
At %LOCALAPPDATA%\Programs\DevControl\Install.ps1:63 char:5
+     $fs = [System.IO.File]::Create($path)
    + FullyQualifiedErrorId : IOException
```
A rebuild (`Deploy.ps1 -Build`) stops before compiling the exe; nothing else is installed.
**Root cause:** the running app holds `DevControl.ico` open (WPF `$win.Icon` and the tray `NotifyIcon`) and `DevControl.png` (`$ui.AppIcon.Source`). `Write-Ico` opened the same path for writing with `[IO.File]::Create`, which is a sharing violation.
**Fix:** `Update-IconFile` (in `src/Install.ps1`) writes to `<path>.new` and `Move-Item -Force`s it over the original; a sharing violation there leaves the existing icon in place, prints `... is in use (Dev Control is running) - kept the existing one.` and the build continues. It still throws if the .ico is missing altogether (csc needs it for `/win32icon:`). The launcher is compiled the same way (to `%TEMP%\devcontrol-build\DevControl.exe`, then swapped in); if the swap fails the build stops with "close Dev Control and run Deploy.ps1 again".
**Prevention:** never write a file the running app may hold open in place - write a temp file and swap.

### FIX-002 - SmartScreen blocks DevControl.exe ("Windows protected your PC", grey dialog)
**Symptom:** double-clicking the shortcut shows a grey SmartScreen dialog and the app never starts. No powershell process, no new line in `app.log`. Nothing in the Defender threat log and no `Zone.Identifier` stream on any installed file.
**Root cause:** `DevControl.exe` is compiled locally by `csc.exe` and was unsigned, so SmartScreen has no publisher and no reputation for it. Every rebuild changes the hash, so an earlier "Run anyway" is forgotten.
**Fix:** `Deploy.ps1 -Sign` creates (or reuses) a self-signed `CN=KD Dev Tools` code-signing certificate in `Cert:\CurrentUser\My`, trusts it in `CurrentUser\Root` + `CurrentUser\TrustedPublisher` (no admin, this user only - Windows asks to confirm the Root import) and signs the exe. `Install.ps1` re-signs on every rebuild with SHA256 + a DigiCert timestamp, falling back to an untimestamped signature when offline.
**Prevention:** keep the certificate - it survives rebuilds. `Get-AuthenticodeSignature DevControl.exe` must say `Valid`. Undo with `Uninstall-DevControl.ps1 -RemoveCertificate`, or:
`Get-ChildItem Cert:\CurrentUser\My, Cert:\CurrentUser\Root, Cert:\CurrentUser\TrustedPublisher | ? { $_.Subject -eq 'CN=KD Dev Tools' } | Remove-Item`
