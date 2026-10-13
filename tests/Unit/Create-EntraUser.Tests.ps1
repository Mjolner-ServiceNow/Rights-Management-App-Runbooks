#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# three Graph cmdlets it calls. Every payload is run under StrictMode Latest, as the
# runbook runs: before #121, a payload without one of the optional fields failed there
# with a property-not-found. The payload carries a password, so the tests also show it
# never reaches a log record, a message or the write-back.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Create-EntraUser.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path
    $script:Secret = 'Initial-Pa55w0rd!'

    # Every field the runbook reads, with the New-MgUser parameter each one becomes.
    $script:Full = @{
        action                = 'Create-EntraUser'
        username              = ' jdoe '
        password              = $script:Secret
        givenname             = ' John '
        surname               = ' Doe '
        city                  = 'Springfield'
        company               = 'Contoso'
        department            = 'Finance'
        title                 = 'Accountant'
        postalcode            = '12345'
        streetaddress         = '1 Main Street'
        mobilephone           = '+1 555 0100'
        employeeid            = 'E-1001'
        physicaldelofficename = 'HQ 4.12'
        businessphone         = ' +1 555 0199 '
        usersysid             = 'a' * 32
    }
    $script:Optional = @(
        'givenname', 'surname', 'city', 'company', 'department', 'title', 'postalcode', 'streetaddress',
        'mobilephone', 'employeeid', 'physicaldelofficename', 'businessphone')

    # Graph errors are a plain System.Exception whose error id leads with the Graph error
    # code. For New-MgUser, the SDK puts the request body, password included, into the
    # error's TargetObject (seen on the test tenant with SDK 2.39.0); this builds that shape.
    function script:New-GraphError {
        param([string] $Code, [string] $Message, [string] $Cmdlet = 'GetMgUser_List', $TargetObject = $null)
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $TargetObject)
    }

    # The body under StrictMode Latest, as the runbook sets it before the loop runs.
    function script:Invoke-Body {
        param($Payload)
        Set-StrictMode -Version Latest
        & $script:Body $script:Job $Payload
    }

    function global:Get-MgDomain {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param([switch] $All)
    }
    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($Filter)
    }
    function global:New-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
            Justification = 'Mirrors the real New-MgUser parameters -UserPrincipalName and -PasswordProfile, which the mock must bind by those names.')]
        [CmdletBinding()]
        param(
            [switch] $AccountEnabled, $UserPrincipalName, $MailNickname, $DisplayName, [hashtable] $PasswordProfile,
            $GivenName, $Surname, $City, $CompanyName, $Department, $JobTitle, $PostalCode, $StreetAddress,
            $MobilePhone, $EmployeeId, $OfficeLocation, [string[]] $BusinessPhones)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgDomain, Function:\Get-MgUser, Function:\New-MgUser -ErrorAction SilentlyContinue
}

Describe 'Create-EntraUser' -Tag 'Unit', 'Security' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:context = [pscustomobject]@{ BaseUri = 'https://contoso.service-now.com'; Headers = @{ Authorization = 'Basic x' } }
        $script:DomainId = 'b' * 32

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock Get-MgDomain {
            [pscustomobject]@{ Id = 'contoso.onmicrosoft.com'; IsDefault = $false }
            [pscustomobject]@{ Id = 'contoso.com'; IsDefault = $true }
        }
        Mock Get-MgUser {}
        $script:Sent = $null
        Mock New-MgUser {
            $script:Sent = @{}
            # What the runbook sends to Graph; -ErrorAction is how the call is made, not data.
            foreach ($key in $PesterBoundParameters.Keys) {
                if ($key -notin [System.Management.Automation.PSCmdlet]::CommonParameters) { $script:Sent[$key] = $PesterBoundParameters[$key] }
            }
            $script:Sent['PasswordProfile'] = $PasswordProfile.Clone()
            [pscustomobject]@{
                Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = $UserPrincipalName
                DisplayName = $DisplayName; AccountEnabled = $true
            }
        }
        $script:WriteBack = $null
        Mock Invoke-RmaRestMethod { $script:WriteBack = @{ Method = $Method; Uri = $Uri; Body = $Body } }
    }

    It 'handles the Create-EntraUser command' {
        $script:Command | Should -Be 'Create-EntraUser'
    }

    It 'creates the user with every field the payload carries' {
        Invoke-Body ([pscustomobject]$script:Full)

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $Filter -eq "userPrincipalName eq 'jdoe@contoso.com'" }
        Should -Invoke New-MgUser -Times 1 -Exactly
        $script:Sent.Keys | Sort-Object | Should -Be @(
            'AccountEnabled', 'BusinessPhones', 'City', 'CompanyName', 'Department', 'DisplayName', 'EmployeeId',
            'GivenName', 'JobTitle', 'MailNickname', 'MobilePhone', 'OfficeLocation', 'PasswordProfile', 'PostalCode',
            'StreetAddress', 'Surname', 'UserPrincipalName')
        $script:Sent.AccountEnabled | Should -BeTrue
        $script:Sent.UserPrincipalName | Should -BeExactly 'jdoe@contoso.com'
        $script:Sent.MailNickname | Should -BeExactly 'jdoe'
        $script:Sent.DisplayName | Should -BeExactly 'John Doe'
        $script:Sent.GivenName | Should -BeExactly 'John'
        $script:Sent.Surname | Should -BeExactly 'Doe'
        $script:Sent.City | Should -BeExactly 'Springfield'
        $script:Sent.CompanyName | Should -BeExactly 'Contoso'
        $script:Sent.Department | Should -BeExactly 'Finance'
        $script:Sent.JobTitle | Should -BeExactly 'Accountant'
        $script:Sent.PostalCode | Should -BeExactly '12345'
        $script:Sent.StreetAddress | Should -BeExactly '1 Main Street'
        $script:Sent.MobilePhone | Should -BeExactly '+1 555 0100'
        $script:Sent.EmployeeId | Should -BeExactly 'E-1001'
        $script:Sent.OfficeLocation | Should -BeExactly 'HQ 4.12'
        @($script:Sent.BusinessPhones).Count | Should -Be 1
        $script:Sent.BusinessPhones[0] | Should -BeExactly '+1 555 0199'
        $script:Sent.PasswordProfile.Keys | Sort-Object | Should -Be @('ForceChangePasswordNextSignIn', 'Password')
        $script:Sent.PasswordProfile.Password | Should -BeExactly $script:Secret
        $script:Sent.PasswordProfile.ForceChangePasswordNextSignIn | Should -BeExactly $true

        $script:Logged[-1].Message | Should -Be 'Entra user created'
        $script:Logged[-1].Data.upn | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be '44444444-4444-4444-4444-444444444444'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)

        $script:WriteBack.Method | Should -Be 'PUT'
        $script:WriteBack.Uri | Should -Be "https://contoso.service-now.com/api/x_autps_active_dir/domain/$('b' * 32)/user"
        $sent = $script:WriteBack.Body | ConvertFrom-Json
        $sent.sysid | Should -Be ('a' * 32)
        $sent.userprincipalname | Should -Be 'jdoe@contoso.com'
        $sent.displayname | Should -Be 'John Doe'
        $sent.objectguid | Should -Be '44444444-4444-4444-4444-444444444444'
        $sent.enabled | Should -BeTrue
    }

    It 'creates the user from the required fields alone when every optional field is absent' {
        Invoke-Body ([pscustomobject]@{ action = 'Create-EntraUser'; username = 'jdoe'; password = $script:Secret })

        $script:Sent.Keys | Sort-Object | Should -Be @(
            'AccountEnabled', 'DisplayName', 'MailNickname', 'PasswordProfile', 'UserPrincipalName')
        $script:Sent.DisplayName | Should -BeExactly 'jdoe'
        ($script:WriteBack.Body | ConvertFrom-Json).sysid | Should -BeNullOrEmpty
    }

    It 'leaves out an optional field that is empty or blank' {
        $payload = [ordered]@{ username = 'jdoe'; password = $script:Secret }
        foreach ($name in $script:Optional) { $payload[$name] = '  ' }
        $payload['city'] = $null

        Invoke-Body ([pscustomobject]$payload)

        $script:Sent.Keys | Sort-Object | Should -Be @(
            'AccountEnabled', 'DisplayName', 'MailNickname', 'PasswordProfile', 'UserPrincipalName')
    }

    It 'creates the user when only ''<Name>'' is absent' -ForEach @(
        'givenname', 'surname', 'city', 'company', 'department', 'title', 'postalcode', 'streetaddress',
        'mobilephone', 'employeeid', 'physicaldelofficename', 'businessphone', 'usersysid' | ForEach-Object { @{ Name = $_ } }
    ) {
        $payload = $script:Full.Clone()
        $payload.Remove($Name)

        Invoke-Body ([pscustomobject]$payload)

        Should -Invoke New-MgUser -Times 1 -Exactly
        $script:Sent.Keys.Count | Should -Be $(if ($Name -eq 'usersysid') { 17 } else { 16 })
    }

    It 'names the user after the given name alone when there is no surname' {
        Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret; givenname = 'John' })

        $script:Sent.DisplayName | Should -BeExactly 'John'
    }

    It 'sends a password with leading and trailing spaces as it is' {
        Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = " $script:Secret " })

        $script:Sent.PasswordProfile.Password | Should -BeExactly " $script:Secret "
    }

    It 'escapes an apostrophe in the existence filter' {
        Invoke-Body ([pscustomobject]@{ username = "o'brien"; password = $script:Secret })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $Filter -eq "userPrincipalName eq 'o''brien@contoso.com'" }
        $script:Sent.UserPrincipalName | Should -BeExactly "o'brien@contoso.com"
    }

    It 'creates the user when the existence check finds nobody' {
        # An empty result is how a filter says "no match"; it is not an error.
        Mock Get-MgUser { @() }

        Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'Stop' }
        Should -Invoke New-MgUser -Times 1 -Exactly
        Should -Invoke Invoke-RmaRestMethod -Times 1 -Exactly
    }

    It 'fails with Graph''s reason, before creating anything, when the existence check fails with <Code>' -ForEach @(
        @{ Code = 'Authorization_RequestDenied'; Message = 'Insufficient privileges to complete the operation.' }
        @{ Code = 'TooManyRequests'; Message = 'Too many requests.' }
        @{ Code = 'InvalidAuthenticationToken'; Message = 'Lifetime validation failed, the token is expired.' }
    ) {
        # Raised as Graph raises it: non-terminating, which -ErrorAction SilentlyContinue
        # used to discard, so the body read it as "no such user" and went on to create (#144).
        $ErrorActionPreference = 'Continue'
        Mock Get-MgUser { Write-Error -ErrorRecord (New-GraphError -Code $Code -Message $Message) }

        { Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret }) } |
        Should -Throw "*$Code*$Message"
        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'Stop' }
        Should -Invoke New-MgUser -Times 0 -Exactly
        Should -Invoke Invoke-RmaRestMethod -Times 0 -Exactly
        $script:Logged | Should -BeNullOrEmpty
    }

    It 'completes without creating anything when the user already exists' {
        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' } }

        Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret })

        Should -Invoke New-MgUser -Times 0 -Exactly
        Should -Invoke Invoke-RmaRestMethod -Times 0 -Exactly
        $script:Logged[-1].Level | Should -Be 'Warning'
        $script:Logged[-1].Message | Should -Be 'User already exists; treating as success'
    }

    It 'passes a Graph failure on create through, without a write-back' {
        Mock New-MgUser { throw 'Another object with the same value for property userPrincipalName already exists.' }

        { Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret }) } |
        Should -Throw '*already exists*'
        Should -Invoke Invoke-RmaRestMethod -Times 0 -Exactly
    }

    It 'fails with Graph''s reason, and without the request body, when the create is refused' {
        # A Graph cmdlet raises a refusal as a non-terminating error, and the runbook's
        # $ErrorActionPreference does not reach it: Write-Error under Continue is that shape.
        # Without -ErrorAction Stop the body went on to $created.Id and failed with a
        # property-not-found (#157).
        $ErrorActionPreference = 'Continue'
        $script:Raised = $null
        Mock New-MgUser {
            $script:Raised = New-GraphError -Code 'Request_BadRequest' -Cmdlet 'NewMgUser_CreateExpanded' `
                -Message 'The specified password does not comply with password complexity requirements. Please provide a different password.' `
                -TargetObject @{ body = @{ userPrincipalName = $UserPrincipalName; passwordProfile = $PasswordProfile.Clone() } }
            Write-Error -ErrorRecord $script:Raised
        }

        $record = $null
        try { Invoke-Body ([pscustomobject]@{ username = 'jdoe'; password = $script:Secret }) } catch { $record = $_ }

        # The stand-in's error does carry the password, as the SDK's does.
        ($script:Raised.TargetObject | ConvertTo-Json -Depth 5) | Should -Match ([regex]::Escape($script:Secret))

        Should -Invoke New-MgUser -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters['ErrorAction'] -eq 'Stop' }
        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -BeExactly '[Request_BadRequest] : The specified password does not comply with password complexity requirements. Please provide a different password.'
        $record.Exception.InnerException | Should -BeNullOrEmpty
        $record.TargetObject | Should -BeNullOrEmpty
        ($record | Format-List * -Force | Out-String) | Should -Not -Match ([regex]::Escape($script:Secret))
        ($record.Exception | Format-List * -Force | Out-String) | Should -Not -Match ([regex]::Escape($script:Secret))
        Should -Invoke Invoke-RmaRestMethod -Times 0 -Exactly
        $script:Logged | Where-Object Message -EQ 'Entra user created' | Should -BeNullOrEmpty
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing username'; Payload = @{ action = 'Create-EntraUser'; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'a null username'; Payload = @{ username = $null; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'an empty username'; Payload = @{ username = '   '; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'a control character in the username'; Payload = @{ username = "jd`noe"; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'a username with a domain'; Payload = @{ username = 'jdoe@contoso.com'; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'a username with a filter quote and space'; Payload = @{ username = "x' or 1 eq 1"; password = 'x' }; Message = "Payload field 'username' is empty*Correct the ServiceNow record." }
        @{ Case = 'a missing password'; Payload = @{ action = 'Create-EntraUser'; username = 'jdoe' }; Message = "Payload field 'password' is empty or contains control characters. Correct the ServiceNow record." }
        @{ Case = 'a null password'; Payload = @{ username = 'jdoe'; password = $null }; Message = "Payload field 'password' is empty or contains control characters. Correct the ServiceNow record." }
        @{ Case = 'an empty password'; Payload = @{ username = 'jdoe'; password = '' }; Message = "Payload field 'password' is empty or contains control characters. Correct the ServiceNow record." }
        @{ Case = 'a control character in the password'; Payload = @{ username = 'jdoe'; password = "Pa55`tw0rd!" }; Message = "Payload field 'password' is empty or contains control characters. Correct the ServiceNow record." }
    ) {
        { Invoke-Body ([pscustomobject]$Payload) } | Should -Throw $Message
        Should -Invoke Get-MgDomain -Times 0 -Exactly
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke New-MgUser -Times 0 -Exactly
        Should -Invoke Invoke-RmaRestMethod -Times 0 -Exactly
    }

    It 'never puts the password or the payload into a log record, a message or the write-back' {
        $payload = $script:Full.Clone()
        $payload['note'] = 'should not appear'
        Invoke-Body ([pscustomobject]$payload)
        $writeBack = $script:WriteBack.Body

        Mock Get-MgUser { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' } }
        Invoke-Body ([pscustomobject]@{ username = 'exists'; password = $script:Secret })
        Mock Get-MgUser {}

        $errors = foreach ($bad in @(
                [pscustomobject]@{ password = $script:Secret }
                [pscustomobject]@{ username = "bad`nname"; password = $script:Secret }
                [pscustomobject]@{ username = 'jdoe'; password = "$script:Secret`n" })) {
            try { Invoke-Body $bad } catch { $_ | Format-List * -Force | Out-String }
        }

        $errors.Count | Should -Be 3
        $errors | ForEach-Object { $_ | Should -Not -Match ([regex]::Escape($script:Secret)) }
        $script:Logged.Count | Should -BeGreaterThan 1
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match ([regex]::Escape($script:Secret))
        ($script:Logged | ConvertTo-Json -Depth 5) | Should -Not -Match 'should not appear'
        $writeBack | Should -Not -Match ([regex]::Escape($script:Secret))
        $writeBack | Should -Not -Match 'should not appear'
    }
}
