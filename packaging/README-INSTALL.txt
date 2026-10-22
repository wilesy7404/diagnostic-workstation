Diagnostic Workstation setup
============================

Extract this zip and run Setup.exe from the extracted folder. Setup.exe
uses the installer, catalog, keys, and tools beside it. Windows asks for
administrator approval once (UAC). Setup.exe then runs the bundled
Install-Master.ps1 in that same run. There is no second installer and no
extra confirmation screen.

This package is unsigned. ECDSA P-256 signing comes later. Until then,
Microsoft SmartScreen or Microsoft Defender may flag Setup.exe. If Windows
shows a warning, choose More info, then Run anyway.

PS2EXE output is not byte-reproducible. Setup.exe differs from one build to
the next. The SHA-256 of DiagnosticWorkstation-Setup.zip from the CI artifact
is the attested value.

Choose a brand
--------------

Double-click Setup.exe, or from an elevated command prompt run:

  Setup.exe -Brand mercedes
  Setup.exe -Brand bmw

Approved brands are mercedes (Mercedes-Benz) and bmw (BMW).
The default channel is beta.

If you do not pass -Brand, Setup.exe prints the approved brands and asks:

  Brand (mercedes or bmw):

That question is never a blank "Install " prompt. If no brand is resolved,
Setup.exe stops with a clear error and installs nothing.

These parameters are passed through to Install-Master.ps1:

  -Channel beta|stable
  -Tag <approved tag>
  -Source <folder>
  -OfflineOnly
  -VerifyOnly
  -AllowDowngrade

Setup.exe runs Install-Master.ps1 in a child powershell.exe and returns
that process exit code.

  0   Windows Update is disabled and Defender preferences plus policy
      values are applied. WinDefend and MDCoreSvc are left running.
  2   Windows Update was not disabled
  10  Tamper Protection stayed on, so Defender was not changed
  11  A Defender preference or policy write failed
  1   No brand was resolved, or the installer stopped before those codes

Report only
-----------

  Setup.exe -Brand mercedes -WhatIf
  Setup.exe -Brand bmw /report

This prints the resolved brand and the package file list. It does not
download, install, or change Windows Update or Defender.

Online install
--------------

For the resolved brand, Install-Master.ps1 downloads the approved
workstation.zip and update-manifest.json from:

  https://github.com/wilesy7404/diagnostic-workstation/releases/download/<tag>/

The current approved tags are mercedes-v0.1.3-beta.4 and bmw-v1.0.2-beta.1.
catalog\catalog.json pins the tag, size, and SHA-256. A file that does
not match the pin is not installed.

Offline install
---------------

The brand zip is not inside this package. To install with no network,
put these two files next to Setup.exe:

  offline\<tag>\workstation.zip
  offline\<tag>\update-manifest.json

Examples:

  offline\mercedes-v0.1.3-beta.4\workstation.zip
  offline\mercedes-v0.1.3-beta.4\update-manifest.json
  offline\bmw-v1.0.2-beta.1\workstation.zip
  offline\bmw-v1.0.2-beta.1\update-manifest.json

Install-Master.ps1 checks that pair against catalog\catalog.json for size
and SHA-256 the same way it checks a download. Pass -OfflineOnly to skip
the network. -Source <folder> is also accepted and is checked the same way.

Windows Update and Windows Defender
------------------------------------

After the brand files are in place, the existing installer turns Windows
Update off with the pinned tools\security\wub Windows Update Blocker.
It turns real-time protection off with Set-MpPreference, and it writes
the Defender policy DWORD values under:

  HKLM\SOFTWARE\Policies\Microsoft\Windows Defender

It does not stop the WinDefend or MDCoreSvc services.

If Tamper Protection is on, the existing installer asks for it to be
turned off in Windows Security before it changes Defender. That check is
unchanged.

Check this package
------------------

SHA256SUMS.txt lists every file in this zip except itself and Setup.exe.
Setup.exe contains the SHA-256 of SHA256SUMS.txt, so that file cannot list
Setup.exe. On startup, before anything else, Setup.exe checks SHA256SUMS.txt
against the embedded hash, then checks every listed file. It stops with a
nonzero exit if a hash does not match, a listed file is missing, or an
unlisted extra file is present. Nothing is installed after a failed check.

The .sha256 file published next to the zip is the SHA-256 of
DiagnosticWorkstation-Setup.zip, which includes SHA256SUMS.txt and Setup.exe.
That CI artifact hash is the attested value. catalog\catalog.sha256 is the
pin for catalog\catalog.json.

Do not run this on a live shop PC. Use a throwaway Windows VM.
