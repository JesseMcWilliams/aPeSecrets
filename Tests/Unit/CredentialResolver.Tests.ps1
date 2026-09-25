#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for Modules\CredentialResolver.psm1.

.DESCRIPTION
    CurrentUser, PSCredential, and WindowsCredentialManager are tested with real round-trips
    (DPAPI file / real Windows Credential Manager store) - no CyberArk connection needed.
    CP/CCP/Conjur are tested for parameter validation only; actually calling them requires a real
    CyberArk Credential Provider install, CCP endpoint, or Conjur appliance respectively - see
    Claude_Docs\Reference_Configuration.md for what's been live-verified and what hasn't.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\..\Modules\CredentialResolver.psm1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:TempDir = Join-Path $env:TEMP "aPeSecretsTests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
}

AfterAll {
    if ($script:TempDir -and (Test-Path $script:TempDir)) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

Describe 'Get-ResolvedCredential - CurrentUser' {
    It 'CR01 - returns $null' {
        Get-ResolvedCredential -Source CurrentUser | Should -BeNullOrEmpty
    }
}

Describe 'Get-ResolvedCredential / Set-ResolvedCredential - PSCredential (DPAPI file)' {
    It 'CR02 - requires CredentialFilePath' {
        { Get-ResolvedCredential -Source PSCredential -Params @{} } | Should -Throw '*CredentialFilePath*'
    }

    It 'CR03 - throws a clear error for a missing file' {
        $missingPath = Join-Path $script:TempDir 'does-not-exist.cred'
        { Get-ResolvedCredential -Source PSCredential -Params @{ CredentialFilePath = $missingPath } } | Should -Throw '*not found*'
    }

    It 'CR04 - Set then Get round-trips username and password' {
        $path = Join-Path $script:TempDir 'roundtrip.cred'
        $cred = [System.Management.Automation.PSCredential]::new('svc-account', (ConvertTo-SecureString 'p@ssw0rd!' -AsPlainText -Force))

        Set-ResolvedCredential -Source PSCredential -Credential $cred -Params @{ CredentialFilePath = $path }
        $loaded = Get-ResolvedCredential -Source PSCredential -Params @{ CredentialFilePath = $path }

        $loaded.UserName                       | Should -Be 'svc-account'
        $loaded.GetNetworkCredential().Password | Should -Be 'p@ssw0rd!'
    }
}

Describe 'Get-ResolvedCredential / Set-ResolvedCredential - WindowsCredentialManager' {
    # Real round-trips against this machine's actual Windows Credential Manager store (CredWrite/
    # CredRead via P/Invoke) - confirmed live, including cross-checked against `cmdkey /list`
    # seeing the same entry an independent Windows tool would.

    AfterEach {
        cmdkey /delete:aPeSecretsPesterTest 2>&1 | Out-Null
    }

    It 'CR05 - requires Target' {
        { Get-ResolvedCredential -Source WindowsCredentialManager -Params @{} } | Should -Throw '*Target*'
    }

    It 'CR06 - throws a clear error for a target that does not exist' {
        { Get-ResolvedCredential -Source WindowsCredentialManager -Params @{ Target = 'aPeSecretsPesterTestMissing' } } | Should -Throw '*No Windows Credential Manager entry*'
    }

    It 'CR07 - Set then Get round-trips username and password' {
        $cred = [System.Management.Automation.PSCredential]::new('testuser', (ConvertTo-SecureString 'T3st!Passw0rd#123' -AsPlainText -Force))

        Set-ResolvedCredential -Source WindowsCredentialManager -Credential $cred -Params @{ Target = 'aPeSecretsPesterTest' }
        $loaded = Get-ResolvedCredential -Source WindowsCredentialManager -Params @{ Target = 'aPeSecretsPesterTest' }

        $loaded.UserName                       | Should -Be 'testuser'
        $loaded.GetNetworkCredential().Password | Should -Be 'T3st!Passw0rd#123'
    }

    It 'CR08 - is independently visible to cmdkey (real Windows Credential Manager interop, not just this module reading its own write)' {
        $cred = [System.Management.Automation.PSCredential]::new('testuser', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Set-ResolvedCredential -Source WindowsCredentialManager -Credential $cred -Params @{ Target = 'aPeSecretsPesterTest' }

        $listOutput = cmdkey /list:aPeSecretsPesterTest 2>&1 | Out-String
        $listOutput | Should -Match 'aPeSecretsPesterTest'
        $listOutput | Should -Match 'testuser'
    }

    It 'CR09 - a UserName override in Params takes precedence over the stored one' {
        $cred = [System.Management.Automation.PSCredential]::new('stored-user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        Set-ResolvedCredential -Source WindowsCredentialManager -Credential $cred -Params @{ Target = 'aPeSecretsPesterTest' }

        $loaded = Get-ResolvedCredential -Source WindowsCredentialManager -Params @{ Target = 'aPeSecretsPesterTest'; UserName = 'override-user' }
        $loaded.UserName | Should -Be 'override-user'
    }
}

Describe 'Get-ResolvedCredential - CP (parameter validation only - no real Credential Provider here)' {
    It 'CR10 - requires AppID' {
        { Get-ResolvedCredential -Source CP -Params @{} } | Should -Throw '*AppID*'
    }

    It 'CR11 - requires Query or Safe/Folder/Object when ClipasswordsdkPath points at a real file' {
        # Point ClipasswordsdkPath at something that exists so the AppID/Query check, not the
        # SDK-not-found check, is what's being exercised.
        $fakeSdk = Join-Path $script:TempDir 'FakeCLIPasswordSDK.exe'
        Set-Content -LiteralPath $fakeSdk -Value 'not a real exe'

        { Get-ResolvedCredential -Source CP -Params @{ ClipasswordsdkPath = $fakeSdk; AppID = 'TestApp' } } | Should -Throw "*'Query'*"
    }

    It 'CR12 - throws a clear error when CLIPasswordSDK.exe is not found at the given/default path' {
        { Get-ResolvedCredential -Source CP -Params @{ ClipasswordsdkPath = (Join-Path $script:TempDir 'NoSuchSdk.exe'); AppID = 'TestApp'; Safe = 'TestSafe' } } | Should -Throw '*CLIPasswordSDK.exe not found*'
    }
}

Describe 'Get-ResolvedCredential - CCP (parameter validation only - no real CCP endpoint here)' {
    It 'CR13 - requires BaseUrl' {
        { Get-ResolvedCredential -Source CCP -Params @{ AppID = 'TestApp' } } | Should -Throw '*BaseUrl*'
    }

    It 'CR14 - requires AppID' {
        { Get-ResolvedCredential -Source CCP -Params @{ BaseUrl = 'https://ccp.example.com' } } | Should -Throw '*AppID*'
    }
}

Describe 'Get-ResolvedCredential - Conjur (parameter validation only - no real Conjur appliance here)' {
    It 'CR15 - requires ApplianceUrl/Account/AuthnLogin/Identifier' {
        { Get-ResolvedCredential -Source Conjur -Params @{} } | Should -Throw "*'ApplianceUrl'*"
    }

    It 'CR16 - requires ApiKeyPath or ApiKeyEnvVar once the required fields are present' {
        $params = @{
            ApplianceUrl = 'https://conjur.example.com'
            Account      = 'myaccount'
            AuthnLogin   = 'host/myhost'
            Identifier   = 'myapp/db-password'
        }
        { Get-ResolvedCredential -Source Conjur -Params $params } | Should -Throw '*ApiKeyPath*ApiKeyEnvVar*'
    }
}

Describe 'Set-ResolvedCredential - unsupported sources' {
    It 'CR17 - CP is not a valid Set-ResolvedCredential source (read-only, ValidateSet rejects it)' {
        $cred = [System.Management.Automation.PSCredential]::new('user', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
        { Set-ResolvedCredential -Source CP -Credential $cred } | Should -Throw
    }
}
