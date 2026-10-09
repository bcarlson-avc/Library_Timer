# Windows installation support; never run this script to validate a package on a build host.
# Library mode exposes pure helpers for non-Windows tests without changing the machine.
[CmdletBinding()]
param(
    [ValidateSet('Library','ReadSettings','Preflight','Prepare','Install','Uninstall')]
    [string]$Action,
    [string]$InstallRoot,
    [string]$ServerAddress,
    [string]$ServerPort,
    [string]$ReportPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ServiceName = 'AVCPublicAccessService'
$TaskName = 'AVC Public Access Watchdog'

function Get-ServerEndpoint([string]$Address, [string]$Port) {
    $Address = $Address.Trim()
    if ($Address.Length -eq 0 -or $Address.Length -gt 253) { throw 'Enter a hostname or IPv4 address.' }
    if ($Address -match '^[0-9.]+$') {
        $parts = $Address.Split('.')
        if ($parts.Count -ne 4) { throw 'Invalid IPv4 address.' }
        foreach ($part in $parts) {
            if ($part -notmatch '^(0|[1-9][0-9]{0,2})$' -or [int]$part -gt 255) { throw 'Invalid IPv4 address.' }
        }
    } else {
        foreach ($label in $Address.Split('.')) {
            if ($label -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') { throw 'Invalid hostname.' }
        }
    }
    if ($Port -notmatch '^[0-9]{1,5}$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) { throw 'Port must be 1 through 65535.' }
    return 'http://{0}:{1}' -f $Address, [int]$Port
}

function Set-ServerConfiguration([string]$Path, [string]$Endpoint) {
    # Read and preserve all other existing settings; do not log configuration values.
    $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $configuration.PSObject.Properties['PublicAccess']) { throw 'Missing PublicAccess configuration.' }
    if (-not $configuration.PublicAccess.PSObject.Properties['ServerAddress']) { throw 'Missing ServerAddress configuration.' }
    $configuration.PublicAccess.ServerAddress = $Endpoint
    $json = $configuration | ConvertTo-Json -Depth 100
    $temporary = $Path + '.installer.tmp'
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $false))
    try { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Get-WatchdogTaskXml([string]$Root) {
    $exe = [Security.SecurityElement]::Escape((Join-Path $Root 'AVCPublicAccess.Watchdog.exe'))
    $directory = [Security.SecurityElement]::Escape($Root)
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>AVC Public Access patron-session Watchdog</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Patron"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>true</Enabled><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>
  <Actions Context="Patron"><Exec><Command>$exe</Command><WorkingDirectory>$directory</WorkingDirectory></Exec></Actions>
</Task>
"@
}

function Invoke-Sc([string[]]$Arguments) {
    $null = & "$env:SystemRoot\System32\sc.exe" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Service management command failed (exit $LASTEXITCODE)." }
}

function Assert-OwnedService {
    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    if ($null -ne $service) {
        $expected = '"' + (Join-Path $InstallRoot 'Service\AVCPublicAccess.Service.exe') + '"'
        if ($service.PathName -ne $expected) { throw 'Service name belongs to another installation. Stop and review migration before continuing.' }
    }
    # Never silently replace earlier deployments registered under a different name.
    $legacy = @(Get-CimInstance Win32_Service | Where-Object {
        $_.Name -ne $ServiceName -and ($_.DisplayName -eq 'AVC Public Access Service' -or $_.PathName -match 'AVCPublicAccess\.Service\.exe')
    })
    if ($legacy.Count -gt 0) { throw 'An earlier AVC Service registration exists. Review and remove the legacy deployment while thawed before proceeding.' }
}

function Assert-OwnedTask {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        $expected = Join-Path $InstallRoot 'AVCPublicAccess.Watchdog.exe'
        if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ne $expected) { throw 'Watchdog task name belongs to another installation.' }
    }
}

function Assert-NoPatronState {
    $data = Join-Path $env:ProgramData 'AVC\PublicAccess'
    foreach ($path in @((Join-Path $env:ProgramData 'AVC'),$data,(Join-Path $data 'watchdog.log'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Runtime paths must not be links or junctions.'
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $data 'session-state.json')) -or
        (Test-Path -LiteralPath (Join-Path $data 'session-state.json.tmp'))) {
        throw 'Patron enforcement state exists. Do not install or freeze during a session. Perform a controlled reboot while thawed, allow the existing Service to clear prior-boot state, then verify Available and retry. Do not delete active state.'
    }
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -eq 'Running') {
        $status = Invoke-RestMethod 'http://127.0.0.1:5051/status' -TimeoutSec 5
        if ($status.Status -ne 'Available') { throw 'Service must be Available before servicing.' }
    }
}

function Stop-OwnedProcesses {
    # Match absolute executable paths; never stop unrelated processes by name alone.
    foreach ($relative in @('AVCPublicAccess.Watchdog.exe','Client\AVCPublicAccess.Client.exe')) {
        $expected = Join-Path $InstallRoot $relative
        foreach ($process in @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $expected })) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }
}

function Stop-Deployment {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        $null = Disable-ScheduledTask -TaskName $TaskName -TaskPath '\'
        Stop-ScheduledTask -TaskName $TaskName -TaskPath '\'
    }
    Stop-OwnedProcesses
    # Close the UI first, then recheck before stopping enforcement. A redemption
    # already in flight must not be mistaken for an idle workstation.
    Assert-NoPatronState
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    try { Assert-NoPatronState }
    catch {
        # If a session was persisted during shutdown, resume the existing
        # same-boot enforcement before refusing file replacement/removal.
        if ($null -ne $service) { Start-Service -Name $ServiceName }
        throw
    }
}

function Initialize-RuntimeDirectory {
    $data = Join-Path $env:ProgramData 'AVC\PublicAccess'
    $null = New-Item -ItemType Directory -Path $data -Force
    $system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $users = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    # No patron directory write access: patrons cannot replace session state or the log.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    foreach ($sid in @($system,$admins)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -LiteralPath $data -AclObject $acl
    $log = Join-Path $data 'watchdog.log'
    if (-not (Test-Path -LiteralPath $log)) { [IO.File]::WriteAllText($log, '') }
    $fileAcl = New-Object Security.AccessControl.FileSecurity
    $fileAcl.SetAccessRuleProtection($true, $false)
    $fileAcl.SetOwner($admins)
    foreach ($sid in @($system,$admins)) {
        $fileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','Allow')))
    }
    $fileAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users,'Read,Write','Allow')))
    Set-Acl -LiteralPath $log -AclObject $fileAcl
}

if ($Action -eq 'Library') { return }
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Deployment actions require Windows.' }
    if (-not $Action -or -not $InstallRoot -or -not $ReportPath) { throw 'Missing deployment arguments.' }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $config = Join-Path $InstallRoot 'Service\appsettings.json'
    if ($Action -eq 'ReadSettings') {
        $output = "[Server]`r`nAddress=`r`nPort=5000`r`n"
        if (Test-Path -LiteralPath $config) {
            $settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
            $uri = New-Object Uri $settings.PublicAccess.ServerAddress
            if ($uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) { throw 'Existing endpoint needs administrator review.' }
            $null = Get-ServerEndpoint $uri.Host ([string]$uri.Port)
            $output = "[Server]`r`nAddress=$($uri.Host)`r`nPort=$($uri.Port)`r`n"
        }
        [IO.File]::WriteAllText($ReportPath, $output, [Text.Encoding]::Unicode)
        exit 0
    }
    Assert-OwnedService
    Assert-OwnedTask
    if ($Action -ne 'Uninstall') { Assert-NoPatronState }
    switch ($Action) {
        'Preflight' { }
        'Prepare' { Stop-Deployment; Assert-NoPatronState }
        'Install' {
            $endpoint = Get-ServerEndpoint $ServerAddress $ServerPort
            Set-ServerConfiguration $config $endpoint
            Initialize-RuntimeDirectory
            $binary = '"' + (Join-Path $InstallRoot 'Service\AVCPublicAccess.Service.exe') + '"'
            if ($null -eq (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
                Invoke-Sc @('create',$ServiceName,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','AVC Public Access Service')
            } else {
                Invoke-Sc @('config',$ServiceName,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','AVC Public Access Service')
            }
            # LocalSystem can register the fixed loopback listener without a URL ACL grant.
            # No external listener, firewall rule, or patron networking privilege is added.
            foreach ($source in @($ServiceName,'AVCPublicAccess.Service')) {
                if (-not [Diagnostics.EventLog]::SourceExists($source)) { New-EventLog -LogName Application -Source $source }
            }
            $null = Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml (Get-WatchdogTaskXml $InstallRoot) -Force
            Start-Service -Name $ServiceName
            $service = Get-Service -Name $ServiceName
            $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            $ready = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                try {
                    $status = Invoke-RestMethod 'http://127.0.0.1:5051/status' -TimeoutSec 2
                    $service.Refresh()
                    if ($service.Status -eq 'Running' -and $status.Status -eq 'Available' -and $status.TestMode -eq $false) { $ready = $true; break }
                } catch { }
                Start-Sleep -Milliseconds 500
            } while ([DateTime]::UtcNow -lt $deadline)
            if (-not $ready) { throw 'Service did not become ready with production enforcement.' }
            # Do not start a patron Watchdog on the elevated installer desktop.
        }
        'Uninstall' {
            Assert-NoPatronState
            Stop-Deployment
            if ($null -ne (Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
                Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
            }
            if ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
                Invoke-Sc @('delete',$ServiceName)
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                do {
                    if ($null -eq (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                } while ([DateTime]::UtcNow -lt $deadline)
                if ($null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { throw 'Service deletion is pending. Close management consoles and retry.' }
            }
            # Configuration and ProgramData are intentionally retained; never delete patron state.
        }
    }
    [IO.File]::WriteAllText($ReportPath, 'OK', [Text.Encoding]::Unicode)
    exit 0
} catch {
    # Exceptions may contain configuration values. Do not emit them into installer logs.
    $message = 'AVC deployment action ' + $Action + ' failed. Verify there is no patron session or saved enforcement state, no conflicting legacy Service/task, and that the machine is thawed. Review Windows Service/Application event logs. Installation is not verified; do not freeze this workstation.'
    if ($ReportPath) { [IO.File]::WriteAllText($ReportPath, $message, [Text.Encoding]::Unicode) }
    exit 1
}
