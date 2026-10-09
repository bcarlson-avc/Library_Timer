# Pure/mocked installer-support checks. No Service, task, process, or registry changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/Deployment.ps1') -Action Library
$checks = 0
function Check([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw $Description }
    $script:checks++
}
function Reject([scriptblock]$Operation, [string]$Description) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Check $rejected $Description
}
Check ((Get-ServerEndpoint ' server.example.edu ' '5000') -eq 'http://server.example.edu:5000') 'Hostname assembly'
Check ((Get-ServerEndpoint '192.0.2.20' '65535') -eq 'http://192.0.2.20:65535') 'IPv4 and high port'
Check ((Get-ServerEndpoint 'host' '00001') -eq 'http://host:1') 'Port normalization'
foreach ($address in @('', 'http://host', 'user@host', 'host/path', 'host"', 'host&command', '-host', 'host-', 'host..edu', '256.1.1.1', '1.2.3', '01.2.3.4', '::1', 'host_name', ('a' * 64))) {
    Reject { Get-ServerEndpoint $address '5000' } 'Unsafe or malformed address accepted'
}
foreach ($port in @('', '0', '65536', '-1', '5.0', '5000;command', ' 5000', '123456')) {
    Reject { Get-ServerEndpoint 'host' $port } 'Unsafe or malformed port accepted'
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('avc-deployment-test-' + [Guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temporary
$previousProgramData = $env:ProgramData
try {
    $path = Join-Path $temporary 'appsettings.json'
    '{"PublicAccess":{"ServerAddress":"http://old-host:5000","Location":"Existing","HeartbeatSeconds":19},"Additional":{"Preserve":"sentinel"}}' | Set-Content $path
    Set-ServerConfiguration $path 'http://new-host:5001'
    $configuration = Get-Content $path -Raw | ConvertFrom-Json
    Check ($configuration.PublicAccess.ServerAddress -eq 'http://new-host:5001') 'Server update'
    Check ($configuration.PublicAccess.Location -eq 'Existing' -and $configuration.PublicAccess.HeartbeatSeconds -eq 19 -and $configuration.Additional.Preserve -eq 'sentinel') 'Upgrade settings lost'
    Check (-not (Test-Path ($path + '.installer.tmp'))) 'Configuration temporary file left behind'
    '{"Logging":{}}' | Set-Content $path
    Reject { Set-ServerConfiguration $path 'http://new-host:5001' } 'Malformed config overwritten'
    Check ((Get-Content $path -Raw | ConvertFrom-Json).PSObject.Properties.Name -eq 'Logging') 'Malformed config changed'
    [xml]$task = Get-WatchdogTaskXml (Join-Path $temporary 'PublicAccess & Pilot')
    Check ($task.Task.Principals.Principal.GroupId -eq 'S-1-5-32-545' -and $task.Task.Principals.Principal.RunLevel -eq 'LeastPrivilege') 'Task requires an elevated patron'
    Check ($task.Task.Settings.ExecutionTimeLimit -eq 'PT0S' -and $task.Task.Settings.MultipleInstancesPolicy -eq 'IgnoreNew') 'Task duration or instance policy'
    Check ($task.Task.Actions.Exec.Command -like '*AVCPublicAccess.Watchdog.exe') 'Task target'
    Check ($task.Task.Triggers.LogonTrigger.Enabled -eq 'true') 'Missing logon startup'
    $env:ProgramData = $temporary
    function Get-Service { param($Name, $ErrorAction) return $null }
    Assert-NoPatronState
    $data = Join-Path $temporary 'AVC/PublicAccess'
    $null = New-Item -ItemType Directory -Path $data -Force
    foreach ($file in @('session-state.json','session-state.json.tmp')) {
        $state = Join-Path $data $file
        'sentinel-state' | Set-Content $state
        Reject { Assert-NoPatronState } 'Patron state did not block servicing'
        Check ((Get-Content $state).Trim() -eq 'sentinel-state') 'Preflight modified state'
        Remove-Item $state
    }
    function Get-Service { param($Name, $ErrorAction) return [pscustomobject]@{ Status='Running' } }
    function Invoke-RestMethod { param($Uri,$TimeoutSec) return [pscustomobject]@{ Status='In Use' } }
    Reject { Assert-NoPatronState } 'Running patron session did not block servicing'
    function Invoke-RestMethod { param($Uri,$TimeoutSec) return [pscustomobject]@{ Status='Available' } }
    Assert-NoPatronState
    $script:InstallRoot = Join-Path $temporary 'PublicAccess'
    $script:serviceFixture = [pscustomobject]@{ Name='AVCPublicAccessService'; DisplayName='AVC Public Access Service'; PathName='"C:\Unrelated\Service.exe"' }
    function Get-CimInstance { param($ClassName,$Filter) return $script:serviceFixture }
    Reject { Assert-OwnedService } 'Conflicting Service was accepted'
    $script:serviceFixture.PathName = '"' + (Join-Path $InstallRoot 'Service\AVCPublicAccess.Service.exe') + '"'
    Assert-OwnedService
    $script:serviceFixture.Name = 'LegacyAVCService'
    Reject { Assert-OwnedService } 'Legacy Service was silently replaced'
    $script:taskFixture = [pscustomobject]@{ Actions=@([pscustomobject]@{ Execute='C:\Unrelated\Watchdog.exe' }) }
    function Get-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) return $script:taskFixture }
    Reject { Assert-OwnedTask } 'Conflicting scheduled task accepted'
    $script:taskFixture.Actions[0].Execute = Join-Path $InstallRoot 'AVCPublicAccess.Watchdog.exe'
    Assert-OwnedTask
    # Simulate an in-flight redemption persisting state while SCM stops.
    $script:taskFixture = $null
    $script:serviceStopped = $false
    $script:enforcementResumed = $false
    function Stop-OwnedProcesses { }
    function Get-Service {
        param($Name,$ErrorAction)
        $service = [pscustomobject]@{ Status=$(if ($script:serviceStopped) { 'Stopped' } else { 'Running' }) }
        $service | Add-Member ScriptMethod WaitForStatus { param($Status,$Timeout) }
        return $service
    }
    function Stop-Service {
        param($Name,[switch]$Force)
        $script:serviceStopped = $true
        'in-flight-state' | Set-Content (Join-Path $data 'session-state.json')
    }
    function Start-Service { param($Name) $script:enforcementResumed = $true }
    Reject { Stop-Deployment } 'In-flight session did not block servicing'
    Check ($script:enforcementResumed -and (Get-Content (Join-Path $data 'session-state.json')) -eq 'in-flight-state') 'In-flight enforcement was not resumed/preserved'
} finally {
    $env:ProgramData = $previousProgramData
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
Write-Host "$checks deployment helper checks passed. No Windows deployment actions executed."
