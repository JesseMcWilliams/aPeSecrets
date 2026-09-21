# Configuration reference

`Get-ResolvedCredential -Source <name> -Params @{ ... }` (and, for the two locally-writable
sources, `Set-ResolvedCredential -Source <name> -Credential $cred -Params @{ ... }`) accept the
same `Params` shape described below regardless of what's calling them.

| Source | Readable (`Get-ResolvedCredential`) | Writable (`Set-ResolvedCredential`) |
|---|---|---|
| `CurrentUser` | Yes - always returns `$null` | No - nothing to store |
| `PSCredential` | Yes | Yes |
| `WindowsCredentialManager` | Yes | Yes |
| `CP` | Yes | No - CyberArk-managed |
| `CCP` | Yes | No - CyberArk-managed |
| `Conjur` | Yes | No - CyberArk-managed |

## CurrentUser

Run as whatever account is already running the calling script. `Params` is ignored.

## PSCredential

A `PSCredential` DPAPI-encrypted to disk via `Export-Clixml` (the same mechanism .NET Framework
PowerShell uses everywhere DPAPI-at-rest is needed). Because `Export-Clixml` encrypts with DPAPI,
the file can only be read back by the same Windows account, on the same machine, that created it -
typically a scheduled task's Run As account.

| `Params` key | Required | Description |
|---|---|---|
| `CredentialFilePath` | Yes | Path to the `.cred`/`.xml`/etc. file. |

## WindowsCredentialManager

Uses the classic Win32 `CredRead`/`CredWrite`/`CredDelete` API (`advapi32.dll`), the same API
`cmdkey` and the Credential Manager Control Panel applet use - not the WinRT
`Windows.Security.Credentials.PasswordVault` surface, which is UWP-oriented and awkward to call
reliably from Windows PowerShell 5.1. Generic (not domain/certificate) credentials only.
**Live-verified** (2026-09-21): a `Set-ResolvedCredential`/`Get-ResolvedCredential` round-trip, and
independently confirmed visible via `cmdkey /list` - real Windows Credential Manager interop, not
just this module reading back its own write.

| `Params` key | Required | Description |
|---|---|---|
| `Target` | Yes | The name the credential is stored under (matches `cmdkey /generic:<Target>`). |
| `UserName` | No (`Get` only) | Overrides the stored username, if the entry's own username field isn't the one you want returned. |
| `Persist` | No (`Set` only) | `LocalMachine` (default) or `Enterprise`, matching the Win32 `CRED_PERSIST_*` values. |

## CP

CyberArk's Application Access Manager Credential Provider, via `CLIPasswordSDK.exe`.
**Live-verified end-to-end** (2026-09-17, in aPeDiscovery before this module was extracted): real
password retrieval for two test accounts against a real installed Credential Provider.

| `Params` key | Required | Description |
|---|---|---|
| `AppID` | Yes | The registered Application ID. |
| `Query` | One of these | A raw CLIPasswordSDK query string. |
| `Safe`/`Folder`/`Object` | One of these | Built into a query string if `Query` isn't given directly. |
| `ClipasswordsdkPath` | No | Defaults to `C:\Program Files\CyberArk\ApplicationPasswordSdk\CLIPasswordSDK.exe` (confirmed live; older/other installs may use `Program Files (x86)`). |
| `UserName` | No | Fallback if the CP doesn't return `PassProps.UserName` for this account. |

## CCP

CyberArk's Central Credential Provider REST web service (`AIMWebService`). Implements the
documented integration pattern; **not yet verified against a live CCP endpoint** - confirm every
value against your own deployment (the `AIMWebService` virtual directory name in particular can
differ by install) before relying on this in production.

| `Params` key | Required | Description |
|---|---|---|
| `BaseUrl` | Yes | e.g. `https://ccp.contoso.com`. |
| `AppID` | Yes | The registered Application ID. |
| `Query` | One of these | A raw AIM query string. |
| `Safe`/`Folder`/`Object` | One of these | Built into a query string if `Query` isn't given directly. |
| `Reason` | No | Passed through as the `Reason` query parameter, if your CCP policy requires one. |
| `ClientCertificateThumbprint` | No | For mutual-TLS AppIDs. The certificate must already be installed in `LocalMachine\My` or `CurrentUser\My`. |

## Conjur

CyberArk Conjur's `authn` + `secrets` REST API. Implements the documented integration pattern;
**not yet verified against a live Conjur appliance** - confirm your Conjur account name, host
identity, and API version against your own deployment before relying on this in production.

| `Params` key | Required | Description |
|---|---|---|
| `ApplianceUrl` | Yes | Base URL of the Conjur appliance/Conjur Cloud tenant. |
| `Account` | Yes | The Conjur account name. |
| `AuthnLogin` | Yes | This host's identity (e.g. `host/my-app-host`). |
| `Identifier` | Yes | The Conjur variable ID holding the password. |
| `ApiKeyPath` | One of these | Path to a file containing this host's Conjur API key. |
| `ApiKeyEnvVar` | One of these | Name of an environment variable containing the API key. |
| `UserName` | One of these | A literal username to pair with the retrieved password. |
| `UsernameIdentifier` | One of these | A second Conjur variable ID holding the username. |

> **Verify before production use.** The CP/CCP/Conjur helpers implement each product's publicly
> documented integration pattern, but exact details - CLI install path, the CCP web service's
> virtual directory name, supported query parameters, TLS/certificate requirements, Conjur API
> version - vary by product version and by how your environment is configured. Confirm every
> value against your own CyberArk deployment before relying on this for a production run.
