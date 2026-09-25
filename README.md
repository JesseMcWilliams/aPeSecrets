# aPeSecrets

A small, shared PowerShell module that resolves a `PSCredential` from any of several pluggable
sources, so a script can authenticate somewhere without a human typing a password in and without
that script needing to know or care where the credential actually comes from.

Windows PowerShell 5.1, matching every other `aPe*` project on this machine — no PowerShell 7
dependency.

## Sources supported

`CurrentUser`, `PSCredential` (a DPAPI-encrypted credential file), `WindowsCredentialManager`
(the classic Win32 Credential Manager store), `CP` (CyberArk Credential Provider,
`CLIPasswordSDK.exe`), `CCP` (CyberArk Central Credential Provider / `AIMWebService` REST API), and
`Conjur` (CyberArk Conjur's `authn`/`secrets` REST API). See
[Claude_Docs\Reference_Configuration.md](Claude_Docs/Reference_Configuration.md) for the full parameter reference per source, and
what's actually been live-verified vs. only implements the documented integration pattern.

## Usage

```powershell
Import-Module .\Modules\CredentialResolver.psm1

$cred = Get-ResolvedCredential -Source CP -Params @{
    AppID = 'MyAppID'
    Safe  = 'MySafe'
    Object = 'MyAccountObjectName'
}

# Or store one locally first, then read it back later:
Set-ResolvedCredential -Source WindowsCredentialManager -Credential (Get-Credential) -Params @{ Target = 'MyServiceAccount' }
$cred = Get-ResolvedCredential -Source WindowsCredentialManager -Params @{ Target = 'MyServiceAccount' }
```

## Documentation

- **Source parameters and verification status:** [Claude_Docs/Reference_Configuration.md](Claude_Docs/Reference_Configuration.md)
- **Pending user-doc updates:** [Claude_Docs/Planning_User-Docs-Backlog.md](Claude_Docs/Planning_User-Docs-Backlog.md)
- **Contributor/Claude guide:** [CLAUDE.md](CLAUDE.md)

## Origin

Extracted from [aPeDiscovery](../aPeDiscovery)'s `Modules\CredentialResolver.psm1` (2026-09-21),
where the `CurrentUser`/`PSCredential`/`CP`/`CCP`/`Conjur` sources were originally built and
tested against real infrastructure (`CP` end-to-end). `CCP` was independently live-verified here
against a real PVWA/CCP host the same day, cross-checked against `CP` retrieving the same account
(matching username, matching password length) - `Conjur` alone still only implements the
documented integration pattern and hasn't been run against a live appliance yet. aPeDiscovery now
depends on this module instead of carrying its own copy, so a fix or a newly-verified detail for any of these
sources only needs to happen once. `WindowsCredentialManager` is new here, added and live-verified
(round-tripped against a real Windows Credential Manager store, cross-checked with `cmdkey /list`)
when this project was created, for
[aPePAS](../aPePAS)'s own automation-credential use case - see aPePAS's
`Claude_Docs\Design_Automation-Credential-Sources.md` for that design's context.

## Consumers

- **aPeDiscovery** — resolves per-domain/per-computer credentials for AD and local Windows/Linux
  discovery scans.
- **aPePAS** — `Sync-AutomationCredential.ps1` uses this to seed/refresh the `.autocred` file
  `Manage-Privilege.ps1`'s automation mode reads, from whichever source an operator configures,
  instead of requiring a one-time interactive credential entry on every machine.

## Testing

```powershell
.\Tests\Run-Tests.ps1
```

`CurrentUser`/`PSCredential`/`WindowsCredentialManager` are tested with real round-trips (no
external dependency). `CP`/`CCP`/`Conjur` are tested for parameter validation only — exercising
them for real requires a real Credential Provider install, CCP endpoint, or Conjur appliance
respectively.
