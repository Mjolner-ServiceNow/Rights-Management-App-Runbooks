#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# The runbook requires the Microsoft Graph modules, which CI does not have, so its body is
# taken from the AST (tests/Helpers/RunbookBody.ps1) and run against stand-ins for the
# Graph cmdlets it calls.

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/RMA.Runbooks/RMA.Runbooks.psd1" -Force
    . (Join-Path $PSScriptRoot '../Helpers/RunbookBody.ps1')
    $path = Join-Path $PSScriptRoot '../../src/runbooks/Set-EntraUserAuthenticationPhoneMethod.ps1'
    $script:Body = Get-RunbookBody -Path $path
    $script:Command = Get-RunbookCommand -Path $path

    # Graph reports its errors as a plain System.Exception whose error id leads with the
    # Graph error code; this builds the same shape.
    function script:New-GraphError {
        param([string] $Code, [string] $Message, [string] $Cmdlet = 'GetMgUser_Get')
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("[$Code] : $Message"),
            "$Code,Microsoft.Graph.PowerShell.Cmdlets.$Cmdlet",
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
    }

    function global:Get-MgUser {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $Property)
    }
    function global:Get-MgUserAuthenticationPhoneMethod {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId)
    }
    function global:New-MgUserAuthenticationPhoneMethod {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $BodyParameter)
    }
    function global:Update-MgUserAuthenticationPhoneMethod {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in for a cmdlet this runner does not have installed. The parameters exist so the mock can bind them.')]
        [CmdletBinding()]
        param($UserId, $PhoneAuthenticationMethodId, $BodyParameter)
    }
}

AfterAll {
    Remove-Item -Path Function:\Get-MgUser, Function:\Get-MgUserAuthenticationPhoneMethod,
    Function:\New-MgUserAuthenticationPhoneMethod, Function:\Update-MgUserAuthenticationPhoneMethod -ErrorAction SilentlyContinue
}

Describe 'Set-EntraUserAuthenticationPhoneMethod' -Tag 'Unit' {

    BeforeEach {
        $script:Job = [pscustomobject]@{ sys_id = 'f' * 32 }
        $script:Id = '44444444-4444-4444-4444-444444444444'
        $script:MobileId = '3179e48a-750b-4051-897c-87b9720928f7'
        $script:Number = '+1 5555550101'

        $script:Logged = [System.Collections.Generic.List[object]]::new()
        Mock Write-RmaLog { $script:Logged.Add([pscustomobject]@{ Level = $Level; Message = $Message; Data = $Data }) }
        Mock New-MgUserAuthenticationPhoneMethod {}
        Mock Update-MgUserAuthenticationPhoneMethod {}
        Mock Get-MgUserAuthenticationPhoneMethod {}
        Mock Get-MgUser {
            [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444'; UserPrincipalName = 'jdoe@contoso.com' }
        }
    }

    It 'handles the Set-EntraUserAuthenticationPhoneMethod command' {
        $script:Command | Should -Be 'Set-EntraUserAuthenticationPhoneMethod'
    }

    It 'adds a mobile method to a user who has none, looked up by user principal name and set by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ action = 'Set-EntraUserAuthenticationPhoneMethod'; useridforauth = ' jdoe@contoso.com '; mobile = " $script:Number " })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq 'jdoe@contoso.com' }
        Should -Invoke Get-MgUserAuthenticationPhoneMethod -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $script:Id -and $BodyParameter.phoneType -eq 'mobile' -and $BodyParameter.phoneNumber -eq $script:Number -and $BodyParameter.Count -eq 2
        }
        Should -Invoke Update-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Be 'Mobile phone authentication method added'
        $script:Logged[-1].Data.userPrincipalName | Should -Be 'jdoe@contoso.com'
        $script:Logged[-1].Data.id | Should -Be $script:Id
        $script:Logged[-1].Data.phoneType | Should -Be 'mobile'
        $script:Logged[-1].Data.queueSysId | Should -Be ('f' * 32)
    }

    It 'adds a mobile method when the user has only other phone types' {
        Mock Get-MgUserAuthenticationPhoneMethod {
            [pscustomobject]@{ Id = 'b6332ec1-7057-4abe-9331-3d72feddfe41'; PhoneType = 'alternateMobile'; PhoneNumber = '+1 5555550101' }
            [pscustomobject]@{ Id = 'e37fc753-ff3b-4958-9484-eaa9425c82bc'; PhoneType = 'office'; PhoneNumber = '+1 5555550199' }
        }

        & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number })

        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 1 -Exactly
        Should -Invoke Update-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'sets the method for a user named by object id' {
        & $script:Body $script:Job ([pscustomobject]@{ useridforauth = $script:Id.ToUpperInvariant(); mobile = $script:Number })

        Should -Invoke Get-MgUser -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 1 -Exactly -ParameterFilter { $UserId -eq $script:Id }
    }

    It 'changes the mobile method in place when it holds another number' {
        Mock Get-MgUserAuthenticationPhoneMethod {
            [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = '+1 5555550100' }
        }

        & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number })

        Should -Invoke Update-MgUserAuthenticationPhoneMethod -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $script:Id -and $PhoneAuthenticationMethodId -eq $script:MobileId -and
            $BodyParameter.phoneType -eq 'mobile' -and $BodyParameter.phoneNumber -eq $script:Number
        }
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Be 'Mobile phone authentication method changed'
    }

    It 'completes without change when the mobile method already holds <Case>' -ForEach @(
        @{ Case = 'the same spelling'; Stored = '+1 5555550101'; Asked = '+1 5555550101' }
        @{ Case = 'the number spelt without a space'; Stored = '+1 5555550101'; Asked = '+15555550101' }
        @{ Case = 'the number with dashes and brackets'; Stored = '+1 5555550101'; Asked = '+1 (555) 555-0101' }
        @{ Case = 'the number with its extension'; Stored = '+1 5555550101 x12'; Asked = '+1 5555550101X12' }
    ) {
        Mock Get-MgUserAuthenticationPhoneMethod {
            [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = $Stored }
        }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $Asked }) } | Should -Not -Throw

        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        Should -Invoke Update-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        $script:Logged[-1].Message | Should -Match 'already has this mobile'
    }

    It 'treats <Case> as a different number' -ForEach @(
        @{ Case = 'the number without its extension'; Stored = '+1 5555550101 x12'; Asked = '+1 5555550101' }
        @{ Case = 'the number without the plus sign'; Stored = '+1 5555550101'; Asked = '1 5555550101' }
    ) {
        Mock Get-MgUserAuthenticationPhoneMethod {
            [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = $Stored }
        }

        & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $Asked })

        Should -Invoke Update-MgUserAuthenticationPhoneMethod -Times 1 -Exactly
    }

    It 'fails with an actionable message when the user does not exist' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Request_ResourceNotFound' -Message "Resource 'nobody@contoso.com' does not exist.") }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'nobody@contoso.com'; mobile = $script:Number }) } |
        Should -Throw "No Entra ID user 'nobody@contoso.com'. Correct the ServiceNow record."
        Should -Invoke Get-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'passes any other lookup failure through unchanged' {
        Mock Get-MgUser { throw (New-GraphError -Code 'Authorization_RequestDenied' -Message 'Insufficient privileges to complete the operation.') }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } |
        Should -Throw '*Authorization_RequestDenied*Insufficient privileges*'
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'says to queue again when Graph''s authentication methods do not know the user yet' {
        Mock Get-MgUserAuthenticationPhoneMethod {
            throw (New-GraphError -Code 'resourceNotFound' -Message 'The specified user could not be found.' -Cmdlet 'GetMgUserAuthenticationPhoneMethod_List')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } |
        Should -Throw "*'jdoe@contoso.com' exists*queue the job again."
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'says to queue again when Graph''s authentication methods refuse the <Case> for a user they do not know yet' -ForEach @(
        @{ Case = 'add'; Existing = $null }
        @{ Case = 'change'; Existing = '+1 5555550100' }
    ) {
        Mock Get-MgUserAuthenticationPhoneMethod {
            if ($Existing) { [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = $Existing } }
        }
        $missing = { throw (New-GraphError -Code 'resourceNotFound' -Message "Resource '44444444-4444-4444-4444-444444444444' does not exist or one of its queried reference-property objects are not present." -Cmdlet 'NewMgUserAuthenticationPhoneMethod_Create') }
        Mock New-MgUserAuthenticationPhoneMethod $missing
        Mock Update-MgUserAuthenticationPhoneMethod $missing

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } |
        Should -Throw "*'jdoe@contoso.com' exists*queue the job again."
        $script:Logged.Count | Should -Be 0
    }

    It 'passes any other failure to read the methods through unchanged' {
        Mock Get-MgUserAuthenticationPhoneMethod {
            throw (New-GraphError -Code 'accessDenied' -Message 'Request Authorization failed' -Cmdlet 'GetMgUserAuthenticationPhoneMethod_List')
        }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } |
        Should -Throw '*accessDenied*Request Authorization failed*'
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'fails with Graph''s own reason when Graph refuses the number on <Case>' -ForEach @(
        @{ Case = 'an add'; Existing = $null }
        @{ Case = 'a change'; Existing = '+1 5555550100' }
    ) {
        Mock Get-MgUserAuthenticationPhoneMethod {
            if ($Existing) { [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = $Existing } }
        }
        $refusal = { throw (New-GraphError -Code 'invalidPhoneNumber' -Message 'The provided phone number is formatted properly, but is an invalid phone number.' -Cmdlet 'NewMgUserAuthenticationPhoneMethod_Create') }
        Mock New-MgUserAuthenticationPhoneMethod $refusal
        Mock Update-MgUserAuthenticationPhoneMethod $refusal

        $thrown = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = '+1 555' }) } catch { $thrown = $_ }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.FullyQualifiedErrorId | Should -BeLike 'invalidPhoneNumber,*'
        $thrown.Exception.Message | Should -BeLike '*invalid phone number*'
        $script:Logged.Message | Should -Not -Contain 'Mobile phone authentication method added'
    }

    It 'cuts the number out of a Graph error that quotes it' {
        Mock New-MgUserAuthenticationPhoneMethod { throw "[invalidPhoneNumber] : '+1 5555550101' is not a valid phone number." }

        $thrown = $null
        try { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } catch { $thrown = $_ }

        $thrown.Exception.Message | Should -Be "[invalidPhoneNumber] : '<mobile>' is not a valid phone number."
    }

    It 'changes nothing when Graph returns a different user than the one asked for' {
        Mock Get-MgUser { [pscustomobject]@{ Id = $script:Id; UserPrincipalName = 'admin@contoso.com' } }

        { & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number }) } |
        Should -Throw '*different user*Nothing was changed*'
        Should -Invoke Get-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'rejects <Case> before contacting Graph' -ForEach @(
        @{ Case = 'a missing user field'; Field = 'useridforauth'; Payload = [pscustomobject]@{ action = 'Set-EntraUserAuthenticationPhoneMethod'; mobile = '+1 5555550101' } }
        @{ Case = 'an empty user'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = '   '; mobile = '+1 5555550101' } }
        @{ Case = 'a control character in the user'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = "jdoe`n" + 'x@contoso.com'; mobile = '+1 5555550101' } }
        @{ Case = 'a user without a domain'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = 'jdoe'; mobile = '+1 5555550101' } }
        @{ Case = 'a path separator'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com/manager'; mobile = '+1 5555550101' } }
        @{ Case = 'a query string'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com?$select=id'; mobile = '+1 5555550101' } }
        @{ Case = 'a percent sign'; Field = 'useridforauth'; Payload = [pscustomobject]@{ useridforauth = 'jdoe%2fx@contoso.com'; mobile = '+1 5555550101' } }
        @{ Case = 'a missing mobile field'; Field = 'mobile'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com' } }
        @{ Case = 'an empty mobile'; Field = 'mobile'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = '  ' } }
        @{ Case = 'a null mobile'; Field = 'mobile'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $null } }
        @{ Case = 'a control character in the mobile'; Field = 'mobile'; Payload = [pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = "+1 555`t5550101" } }
    ) {
        # The runbook runs under StrictMode Latest, where reading a missing property throws.
        Set-StrictMode -Version Latest
        { & $script:Body $script:Job $Payload } | Should -Throw "*Payload field '$Field'*Correct the ServiceNow record."
        Should -Invoke Get-MgUser -Times 0 -Exactly
        Should -Invoke New-MgUserAuthenticationPhoneMethod -Times 0 -Exactly
    }

    It 'keeps the number out of every log record and error on <Case>' -ForEach @(
        @{ Case = 'an add'; Existing = $null; Fail = $false }
        @{ Case = 'a change'; Existing = '+1 5555550100'; Fail = $false }
        @{ Case = 'a repeat'; Existing = '+1 5555550101'; Fail = $false }
        @{ Case = 'a refusal'; Existing = $null; Fail = $true }
    ) {
        Mock Get-MgUserAuthenticationPhoneMethod {
            if ($Existing) { [pscustomobject]@{ Id = '3179e48a-750b-4051-897c-87b9720928f7'; PhoneType = 'mobile'; PhoneNumber = $Existing } }
        }
        if ($Fail) {
            Mock New-MgUserAuthenticationPhoneMethod { throw (New-GraphError -Code 'invalidPhoneNumber' -Message 'The provided phone number is formatted properly, but is an invalid phone number.' -Cmdlet 'NewMgUserAuthenticationPhoneMethod_Create') }
        }

        $thrown = $null
        try {
            & $script:Body $script:Job ([pscustomobject]@{ useridforauth = 'jdoe@contoso.com'; mobile = $script:Number; note = 'should not appear' })
        } catch { $thrown = $_ }

        $text = ($script:Logged | ConvertTo-Json -Depth 5) + "`n" + "$thrown"
        $script:Logged.Count | Should -Be ([int] -not $Fail)
        $text | Should -Not -Match 'should not appear'
        $text | Should -Not -Match '555'
        ([bool] $thrown) | Should -Be $Fail
    }
}
