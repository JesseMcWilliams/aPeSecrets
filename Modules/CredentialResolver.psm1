#Requires -Version 5.1
<#
    Shared, pluggable credential resolution for any script that needs to authenticate somewhere
    without a human typing a password in.

    Supported sources: CurrentUser, PSCredential, WindowsCredentialManager, CP, CCP, Conjur.

    Extracted from aPeDiscovery's Modules\CredentialResolver.psm1 (2026-09-21), which is where the
    CurrentUser/PSCredential/CP/CCP/Conjur sources were originally built and tested. That project
    now depends on this one instead of carrying its own copy - see this repo's README for the
    reuse rationale.

    IMPORTANT - verify before production use:
    The CP, CCP, and Conjur helpers below implement each product's documented integration pattern
    (AAM Credential Provider CLI, CCP/AIMWebService REST API, and Conjur's authn + secrets REST
    API). Exact details such as install paths, web service virtual-directory names, supported
    query parameters, and authentication options vary by product version and by how your
    environment is configured. Confirm every value in Params for your own deployment (AppID, Safe,
    Object/Query, BaseUrl, ApplianceUrl, Account, etc.) before relying on this in production, and
    treat this module as a starting point rather than a verified-against-your-tenant
    implementation.

    CP specifically HAS been verified live (2026-09-17, in aPeDiscovery) against a real installed
    Credential Provider/CLIPasswordSDK.exe, and that testing found (and fixed) a real bug:
    CLIPasswordSDK's /o output is a plain comma-separated list of VALUES in the requested field
    order (e.g. "ThisIsMy_FAKE_Password6!,CAscanner2" for /o Password,PassProps.UserName) - NOT
    "Key=Value,Key=Value" pairs as an earlier version of this function incorrectly assumed (which
    would have thrown on every real call). Also found the real install path on that host was
    C:\Program Files\CyberArk\ApplicationPasswordSdk\CLIPasswordSDK.exe (64-bit Program Files, not
    the Program Files (x86) this module previously defaulted to) - the default below reflects
    that; override via ClipasswordsdkPath if your install differs. CCP and Conjur remain unverified
    against a real deployment.

    WindowsCredentialManager uses the classic Win32 CredRead/CredWrite/CredDelete API
    (advapi32.dll) via inline P/Invoke - the same API `cmdkey` and the Credential Manager Control
    Panel applet use - rather than the WinRT Windows.Security.Credentials.PasswordVault surface,
    which is UWP-oriented and awkward to call reliably from Windows PowerShell 5.1. Round-tripped
    live against a real Windows Credential Manager store as part of this module's own test suite
    (Tests\Unit\CredentialResolver.Tests.ps1) - see that file for what was actually confirmed.
#>


# Deliberately NOT Set-StrictMode -Version Latest: every source function below reads optional keys
# from the caller's $Params hashtable via dot notation (e.g. $Params.Safe) and relies on a missing
# key returning $null rather than throwing - confirmed live that Set-StrictMode -Version Latest
# turns a missing hashtable key accessed this way into a PropertyNotFoundException, which would
# break the CP/CCP/Conjur logic exactly as it was originally written and live-verified in
# aPeDiscovery. Rewriting every access to ContainsKey/[...] instead was rejected as unnecessary
# risk to already-proven code for this extraction.

if (-not ('aPeSecrets.Win32Credential' -as [type])) {
    Add-Type -Namespace aPeSecrets -Name Win32Credential -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public UInt32 Flags;
    public UInt32 Type;
    [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
    [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public UInt32 CredentialBlobSize;
    public IntPtr CredentialBlob;
    public UInt32 Persist;
    public UInt32 AttributeCount;
    public IntPtr Attributes;
    [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
    [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
}

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredWrite(ref CREDENTIAL credential, UInt32 flags);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredRead(string target, UInt32 type, int reservedFlag, out IntPtr credentialPtr);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CredFree(IntPtr credentialPtr);

[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool CredDelete(string target, UInt32 type, int flags);
'@ -UsingNamespace 'System.Runtime.InteropServices.ComTypes'
}

function Get-ResolvedCredential {
    <#
    .SYNOPSIS
        Resolves a PSCredential (or $null for CurrentUser) from a named source.
    .PARAMETER Source
        One of CurrentUser, PSCredential, WindowsCredentialManager, CP, CCP, Conjur.
    .PARAMETER Params
        Hashtable of source-specific parameters. See Claude_Docs\Reference_Configuration.md.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CurrentUser', 'PSCredential', 'WindowsCredentialManager', 'CP', 'CCP', 'Conjur')]
        [string] $Source,
        [hashtable] $Params = @{},
        [string] $LogPath
    )

    switch ($Source) {
        'CurrentUser'               { return $null }
        'PSCredential'              { return Get-CredentialFromFile -Params $Params }
        'WindowsCredentialManager'  { return Get-CredentialFromWindowsCredentialManager -Params $Params }
        'CP'                        { return Get-CredentialFromCP -Params $Params }
        'CCP'                       { return Get-CredentialFromCCP -Params $Params }
        'Conjur'                    { return Get-CredentialFromConjur -Params $Params }
    }
}

function Set-ResolvedCredential {
    <#
    .SYNOPSIS
        Stores a PSCredential for later retrieval via Get-ResolvedCredential. Only the two
        locally-writable sources are supported - CP/CCP/Conjur are read-only views onto a
        CyberArk-managed store, and CurrentUser has no credential to store at all.
    .PARAMETER Source
        One of PSCredential, WindowsCredentialManager.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PSCredential', 'WindowsCredentialManager')]
        [string] $Source,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential] $Credential,
        [hashtable] $Params = @{}
    )

    switch ($Source) {
        'PSCredential'             { Set-CredentialToFile -Credential $Credential -Params $Params }
        'WindowsCredentialManager' { Set-CredentialToWindowsCredentialManager -Credential $Credential -Params $Params }
    }
}

function Get-CredentialFromFile {
    param([hashtable] $Params)

    if (-not $Params.CredentialFilePath) {
        throw "PSCredential source requires 'CredentialFilePath' in Params."
    }
    if (-not (Test-Path -Path $Params.CredentialFilePath)) {
        throw "Credential file not found at '$($Params.CredentialFilePath)'."
    }

    # Export-Clixml encrypts via DPAPI for the user+machine that created it, so this file can only
    # be read back by that same Windows account, on that same machine - typically a scheduled
    # task's Run As account.
    return Import-Clixml -Path $Params.CredentialFilePath
}

function Set-CredentialToFile {
    param(
        [System.Management.Automation.PSCredential] $Credential,
        [hashtable] $Params
    )

    if (-not $Params.CredentialFilePath) {
        throw "PSCredential source requires 'CredentialFilePath' in Params."
    }

    $Credential | Export-Clixml -Path $Params.CredentialFilePath -Force
}

function Get-CredentialFromWindowsCredentialManager {
    param([hashtable] $Params)

    if (-not $Params.Target) {
        throw "WindowsCredentialManager source requires 'Target' in Params (the name the credential was stored under, e.g. via cmdkey /generic:<Target> or Set-ResolvedCredential)."
    }

    $credPtr = [IntPtr]::Zero
    $credType = 1  # CRED_TYPE_GENERIC
    $ok = [aPeSecrets.Win32Credential]::CredRead($Params.Target, $credType, 0, [ref] $credPtr)
    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "No Windows Credential Manager entry found for target '$($Params.Target)' (Win32 error $err). Confirm it was stored with cmdkey /generic:$($Params.Target) or Set-ResolvedCredential -Source WindowsCredentialManager, under the same Windows account running this."
    }

    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [type][aPeSecrets.Win32Credential+CREDENTIAL])
        $passwordBytes = New-Object byte[] ($cred.CredentialBlobSize)
        if ($cred.CredentialBlobSize -gt 0) {
            [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $passwordBytes, 0, $cred.CredentialBlobSize)
        }
        $password = [System.Text.Encoding]::Unicode.GetString($passwordBytes)

        $userName = if ($Params.UserName) { $Params.UserName } elseif ($cred.UserName) { $cred.UserName } else {
            throw "Windows Credential Manager entry for target '$($Params.Target)' has no stored UserName, and no 'UserName' fallback was provided in Params."
        }

        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $userName, $securePassword
    } finally {
        [aPeSecrets.Win32Credential]::CredFree($credPtr) | Out-Null
    }
}

function Set-CredentialToWindowsCredentialManager {
    param(
        [System.Management.Automation.PSCredential] $Credential,
        [hashtable] $Params
    )

    if (-not $Params.Target) {
        throw "WindowsCredentialManager source requires 'Target' in Params."
    }

    $passwordPlain = $Credential.GetNetworkCredential().Password
    $passwordBytes = [System.Text.Encoding]::Unicode.GetBytes($passwordPlain)
    $blobPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($passwordBytes.Length)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($passwordBytes, 0, $blobPtr, $passwordBytes.Length)

        $persist = if ($Params.Persist -eq 'Enterprise') { 3 } else { 2 }  # 2 = CRED_PERSIST_LOCAL_MACHINE, 3 = CRED_PERSIST_ENTERPRISE

        $cred = New-Object aPeSecrets.Win32Credential+CREDENTIAL
        $cred.Type = 1  # CRED_TYPE_GENERIC
        $cred.TargetName = $Params.Target
        $cred.CredentialBlobSize = [uint32] $passwordBytes.Length
        $cred.CredentialBlob = $blobPtr
        $cred.Persist = $persist
        $cred.UserName = $Credential.UserName

        $ok = [aPeSecrets.Win32Credential]::CredWrite([ref] $cred, 0)
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Failed to write Windows Credential Manager entry for target '$($Params.Target)' (Win32 error $err)."
        }
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blobPtr)
    }
}

function Get-CredentialFromCP {
    param([hashtable] $Params)

    $sdkPath = if ($Params.ClipasswordsdkPath) {
        $Params.ClipasswordsdkPath
    } else {
        'C:\Program Files\CyberArk\ApplicationPasswordSdk\CLIPasswordSDK.exe'
    }

    if (-not (Test-Path -Path $sdkPath)) {
        throw "CLIPasswordSDK.exe not found at '$sdkPath'. Confirm the Credential Provider (CP) is installed on this host, or set 'ClipasswordsdkPath' in Params to its actual location."
    }
    if (-not $Params.AppID) {
        throw "CP source requires 'AppID' in Params."
    }

    $query = $Params.Query
    if (-not $query) {
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($Params.Safe) { $parts.Add("Safe=$($Params.Safe)") }
        if ($Params.Folder) { $parts.Add("Folder=$($Params.Folder)") }
        if ($Params.Object) { $parts.Add("Object=$($Params.Object)") }
        if ($parts.Count -eq 0) {
            throw "CP source requires either 'Query', or one or more of 'Safe'/'Folder'/'Object', in Params."
        }
        $query = $parts -join ';'
    }

    # CLIPasswordSDK's /o output is a plain comma-separated list of VALUES in the exact order
    # requested - confirmed live against a real Credential Provider - NOT "Key=Value,Key=Value"
    # pairs. A field that doesn't apply comes back as the literal string "<na>", not empty.
    # Requesting Password alone (its own call) avoids any risk of a comma inside the password
    # itself being mistaken for a field separator - there is no documented way to know whether
    # CLIPasswordSDK escapes an embedded comma in a value, so this sidesteps the question entirely
    # rather than relying on split-by-position for the secret itself.
    $passwordOutput = & $sdkPath GetPassword /p "AppDescs.AppID=$($Params.AppID)" /p "Query=$query" /o 'Password' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "CLIPasswordSDK GetPassword failed for AppID '$($Params.AppID)' (exit code $LASTEXITCODE). Verify the AppID/Safe/Folder/Object values and that this host is registered with the CP. (Output withheld in case it echoed the query back with sensitive values.)"
    }
    $password = ($passwordOutput | Select-Object -Last 1)
    if ([string]::IsNullOrEmpty($password) -or $password -eq '<na>') {
        throw "CLIPasswordSDK did not return a usable Password value for AppID '$($Params.AppID)'. Verify the AppID/Safe/Folder/Object/Query values."
    }

    $userName = $Params.UserName
    if (-not $userName) {
        $userNameOutput = & $sdkPath GetPassword /p "AppDescs.AppID=$($Params.AppID)" /p "Query=$query" /o 'PassProps.UserName' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $candidate = ($userNameOutput | Select-Object -Last 1)
            if ($candidate -and $candidate -ne '<na>') { $userName = $candidate }
        }
    }
    if (-not $userName) {
        throw "CP did not return PassProps.UserName and no fallback 'UserName' was provided in Params."
    }

    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $userName, $securePassword
}

function Get-CredentialFromCCP {
    param([hashtable] $Params)

    if (-not $Params.BaseUrl) {
        throw "CCP source requires 'BaseUrl' in Params (e.g. https://ccp.contoso.com)."
    }
    if (-not $Params.AppID) {
        throw "CCP source requires 'AppID' in Params."
    }

    $queryPairs = [System.Collections.Generic.List[string]]::new()
    $queryPairs.Add("AppID=$([uri]::EscapeDataString($Params.AppID))")
    if ($Params.Query) {
        $queryPairs.Add("Query=$([uri]::EscapeDataString($Params.Query))")
    } else {
        if ($Params.Safe) { $queryPairs.Add("Safe=$([uri]::EscapeDataString($Params.Safe))") }
        if ($Params.Object) { $queryPairs.Add("Object=$([uri]::EscapeDataString($Params.Object))") }
        if ($Params.Folder) { $queryPairs.Add("Folder=$([uri]::EscapeDataString($Params.Folder))") }
    }
    if ($Params.Reason) { $queryPairs.Add("Reason=$([uri]::EscapeDataString($Params.Reason))") }

    $uri = '{0}/AIMWebService/api/Accounts?{1}' -f $Params.BaseUrl.TrimEnd('/'), ($queryPairs -join '&')

    $invokeParams = @{ Uri = $uri; Method = 'Get'; ErrorAction = 'Stop' }
    if ($Params.ClientCertificateThumbprint) {
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\My\$($Params.ClientCertificateThumbprint)" -ErrorAction SilentlyContinue
        if (-not $cert) { $cert = Get-ChildItem -Path "Cert:\CurrentUser\My\$($Params.ClientCertificateThumbprint)" -ErrorAction SilentlyContinue }
        if (-not $cert) { throw "Client certificate with thumbprint '$($Params.ClientCertificateThumbprint)' was not found in LocalMachine\My or CurrentUser\My." }
        $invokeParams.Certificate = $cert
    }

    try {
        $response = Invoke-RestMethod @invokeParams
    } catch {
        throw "CCP request for AppID '$($Params.AppID)' failed: $($_.Exception.Message). Verify BaseUrl, the AIMWebService virtual directory name, and network/TLS connectivity to the CCP server."
    }

    if (-not $response.Content) {
        throw "CCP response for AppID '$($Params.AppID)' did not include a Content (password) field. Verify Safe/Object/Query and that the account is accessible to this AppID."
    }

    $securePassword = ConvertTo-SecureString -String $response.Content -AsPlainText -Force
    return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $response.UserName, $securePassword
}

function Get-CredentialFromConjur {
    param([hashtable] $Params)

    foreach ($required in 'ApplianceUrl', 'Account', 'AuthnLogin', 'Identifier') {
        if (-not $Params[$required]) {
            throw "Conjur source requires '$required' in Params."
        }
    }

    $apiKey = $null
    if ($Params.ApiKeyPath) {
        if (-not (Test-Path -Path $Params.ApiKeyPath)) { throw "Conjur API key file not found at '$($Params.ApiKeyPath)'." }
        $apiKey = (Get-Content -Path $Params.ApiKeyPath -Raw).Trim()
    } elseif ($Params.ApiKeyEnvVar) {
        $apiKey = [Environment]::GetEnvironmentVariable($Params.ApiKeyEnvVar)
        if (-not $apiKey) { throw "Environment variable '$($Params.ApiKeyEnvVar)' is not set or is empty." }
    } else {
        throw "Conjur source requires either 'ApiKeyPath' or 'ApiKeyEnvVar' in Params to locate this host's Conjur API key."
    }

    $applianceUrl = $Params.ApplianceUrl.TrimEnd('/')
    $account = $Params.Account
    $authnLoginEncoded = [uri]::EscapeDataString($Params.AuthnLogin)

    try {
        $token = Invoke-RestMethod -Uri "$applianceUrl/authn/$account/$authnLoginEncoded/authenticate" -Method Post -Body $apiKey -ContentType 'text/plain' -ErrorAction Stop
    } catch {
        throw "Conjur authentication for host '$($Params.AuthnLogin)' failed: $($_.Exception.Message). Verify ApplianceUrl, Account, AuthnLogin, and the API key."
    }
    $tokenBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($token))

    $identifierEncoded = [uri]::EscapeDataString($Params.Identifier)
    try {
        $secretValue = Invoke-RestMethod -Uri "$applianceUrl/secrets/$account/variable/$identifierEncoded" -Method Get -Headers @{ Authorization = "Token token=`"$tokenBase64`"" } -ErrorAction Stop
    } catch {
        throw "Conjur secret retrieval for '$($Params.Identifier)' failed: $($_.Exception.Message)."
    }

    $userName = $null
    if ($Params.UserName) {
        $userName = $Params.UserName
    } elseif ($Params.UsernameIdentifier) {
        $usernameIdentifierEncoded = [uri]::EscapeDataString($Params.UsernameIdentifier)
        try {
            $userName = Invoke-RestMethod -Uri "$applianceUrl/secrets/$account/variable/$usernameIdentifierEncoded" -Method Get -Headers @{ Authorization = "Token token=`"$tokenBase64`"" } -ErrorAction Stop
        } catch {
            throw "Conjur username retrieval from '$($Params.UsernameIdentifier)' failed: $($_.Exception.Message)."
        }
    } else {
        throw "Conjur source requires either 'UserName' (literal) or 'UsernameIdentifier' (a second Conjur variable path) in Params."
    }

    $securePassword = ConvertTo-SecureString -String $secretValue -AsPlainText -Force
    return New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $userName, $securePassword
}

Export-ModuleMember -Function Get-ResolvedCredential, Set-ResolvedCredential
