# Requires PowerShell 7, .NET SDK pinned in version.json, Inno Setup, Python 3, and innoextract.
[CmdletBinding()]
param(
    [string]$Dotnet = 'dotnet',
    [Parameter(Mandatory)][string]$Iscc,
    [Parameter(Mandatory)][string]$InnoExtract,
    [string]$Python = 'python',
    [string]$Wine
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$version = Get-Content (Join-Path $root 'deployment/version.json') -Raw | ConvertFrom-Json
$work = Join-Path $root 'Build/Installer'
$stage = Join-Path $work 'stage'
$output = Join-Path $work 'output'

function Run-Native([string]$Program, [string[]]$Arguments, [string]$Log) {
    $lines = & $Program @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $lines | Set-Content -LiteralPath $Log -Encoding utf8
    $lines | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) { throw "$Program failed with exit $exitCode; see $Log" }
}
function Compiler-Path([string]$Path) {
    if ($Wine) { return 'Z:' + [IO.Path]::GetFullPath($Path).Replace('/', '\') }
    return [IO.Path]::GetFullPath($Path)
}
if (($version.version -notmatch '^\d+\.\d+\.\d+$')) { throw 'Invalid package version.' }
if ((& $Dotnet --version).Trim() -ne $version.dotnetSdk) { throw "Use .NET SDK $($version.dotnetSdk)." }
foreach ($name in @('Client','Service','Watchdog')) {
    if (-not (Test-Path (Join-Path $root "AVCPublicAccess.$name/AVCPublicAccess.$name.csproj"))) { throw "Missing $name project." }
}
$head = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source commit.' }
$branch = (& git -C $root branch --show-current).Trim()
if ($branch -ne 'main') { throw 'Build this package from main.' }
$changes = @(& git -C $root diff --name-only HEAD -- AVCPublicAccess.Client AVCPublicAccess.Service AVCPublicAccess.Watchdog)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source changes.' }
if ($changes.Count -gt 0) {
    # Exactly one installation identity change is allowed; record its source hash.
    if ($changes.Count -ne 1 -or $changes[0] -ne 'AVCPublicAccess.Service/Program.cs') { throw 'Unexpected application source changes.' }
    $original = (& git -C $root show HEAD:AVCPublicAccess.Service/Program.cs) -join "`n"
    $current = [IO.File]::ReadAllText((Join-Path $root $changes[0])).Replace("`r`n", "`n").TrimEnd("`n")
    if ($current -ne $original.Replace('options.ServiceName = "AVC Public Access Service";', 'options.ServiceName = "AVCPublicAccessService";').TrimEnd("`n")) {
        throw 'The permitted Service name change contains additional edits.'
    }
}
# Always erase only this script's fixed work directory, never an arbitrary caller path.
if ([IO.Path]::GetFullPath($work) -ne [IO.Path]::GetFullPath((Join-Path $root 'Build/Installer'))) { throw 'Unsafe staging path.' }
if ((Test-Path (Split-Path $work)) -and (Get-Item (Split-Path $work)).LinkType) { throw 'Build directory must not be a symbolic link.' }
if ((Test-Path $work) -and (Get-Item $work).LinkType) { throw 'Staging must not be a symbolic link.' }
if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$null = New-Item -ItemType Directory -Path $stage,$output,(Join-Path $work 'source'),(Join-Path $work 'logs') -Force

$inputs = @()
foreach ($name in @('Client','Service','Watchdog')) {
    $project = "AVCPublicAccess.$name"
    $files = @(& git -C $root ls-files -- $project)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inventory tracked application source.' }
    foreach ($file in $files) {
        if ($file -match '(^|/)(bin|obj|Archive|FinalRelease|Build|Publish|publish)/|backup|working-before') { throw "Unexpected tracked source path: $file" }
        if ($file -like '*/appsettings.Development.json' -or $file -like '*/Properties/launchSettings.json') { continue }
        if ($file -notmatch '\.(cs|csproj|xaml|png)$' -and $file -ne "$project/appsettings.json") { throw "Review source input $file before packaging." }
        $from = Join-Path $root $file
        $to = Join-Path $work "source/$file"
        $null = New-Item -ItemType Directory -Path (Split-Path $to) -Force
        Copy-Item -LiteralPath $from -Destination $to
        $inputs += [ordered]@{path=$file; sha256=(Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $publish = Join-Path $stage $name
    $arguments = @('publish',(Join-Path $work "source/$project/$project.csproj"),'-c','Release','-r','win-x64','--self-contained','true','-o',$publish,
        '-p:EnableWindowsTargeting=true','-p:DebugType=None','-p:DebugSymbols=false',"-p:Version=$($version.version)",'-p:ContinuousIntegrationBuild=true')
    Run-Native $Dotnet $arguments (Join-Path $work "logs/publish-$name.log")
    foreach ($extension in @('exe','dll','deps.json','runtimeconfig.json')) {
        if (-not (Test-Path (Join-Path $publish "$project.$extension"))) { throw "Missing $project.$extension" }
    }
    if (-not (Test-Path (Join-Path $publish 'coreclr.dll'))) { throw "$name publish is not self-contained." }
}
$deployment = Join-Path $stage 'Deployment'
$null = New-Item -ItemType Directory -Path $deployment
Copy-Item (Join-Path $PSScriptRoot 'Deployment.ps1') $deployment
foreach ($file in @('deployment/version.json','deployment/installer/AVCPublicAccess.iss','deployment/scripts/Deployment.ps1','deployment/scripts/Build-Package.ps1','deployment/scripts/verify-package.py')) {
    $inputs += [ordered]@{path=$file; sha256=(Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$payloads = @()
foreach ($file in Get-ChildItem $stage -Recurse -File | Sort-Object FullName) {
    $payloads += [ordered]@{path=[IO.Path]::GetRelativePath($stage,$file.FullName).Replace('\','/'); sha256=(Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); bytes=$file.Length}
}
$manifest = [ordered]@{version=$version.version; sourceCommit=$head; applicationChanges=$changes; dotnetSdk=$version.dotnetSdk; innoSetup=$version.innoSetup; runtime='win-x64'; selfContained=$true; inputs=$inputs; files=$payloads}
$manifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $deployment 'payload-manifest.json') -Encoding utf8
Run-Native $Python @((Join-Path $PSScriptRoot 'verify-package.py'),'--stage',$stage,'--logo',(Join-Path $root 'AVCPublicAccess.Client/Images/avc-logo.png')) (Join-Path $work 'logs/stage-validation.log')

$isccArguments = @("/DStageRoot=$(Compiler-Path $stage)","/DOutputRoot=$(Compiler-Path $output)","/DPackageVersion=$($version.version)",(Compiler-Path (Join-Path $root 'deployment/installer/AVCPublicAccess.iss')))
if ($Wine) {
    Run-Native $Wine @((Compiler-Path $Iscc),'--version') (Join-Path $work 'logs/compiler-version.log')
    if ((Get-Content (Join-Path $work 'logs/compiler-version.log') -Raw) -notmatch "\b$([regex]::Escape($version.innoSetup))\b") { throw 'Unexpected Inno compiler version.' }
    Run-Native $Wine (@((Compiler-Path $Iscc)) + $isccArguments) (Join-Path $work 'logs/compiler.log')
} else {
    Run-Native $Iscc @('--version') (Join-Path $work 'logs/compiler-version.log')
    if ((Get-Content (Join-Path $work 'logs/compiler-version.log') -Raw) -notmatch "\b$([regex]::Escape($version.innoSetup))\b") { throw 'Unexpected Inno compiler version.' }
    Run-Native $Iscc $isccArguments (Join-Path $work 'logs/compiler.log')
}
$installer = Join-Path $output "AVCPublicAccess-Client-Setup-$($version.version)-win-x64.exe"
if (-not (Test-Path $installer)) { throw 'Installer was not produced.' }
$extracted = Join-Path $work 'extracted'
Run-Native $InnoExtract @('--extract','--test','--output-dir',$extracted,$installer) (Join-Path $work 'logs/extraction.log')
Run-Native $Python @((Join-Path $PSScriptRoot 'verify-package.py'),'--stage',$stage,'--extracted',$extracted,'--logo',(Join-Path $root 'AVCPublicAccess.Client/Images/avc-logo.png'),'--installer',$installer,'--compiler-log',(Join-Path $work 'logs/compiler.log')) (Join-Path $work 'logs/package-validation.log')
$hashes = @()
foreach ($name in @('Client','Service','Watchdog')) {
    $file = Join-Path $stage "$name/AVCPublicAccess.$name.exe"
    $hashes += '{0}  {1}' -f (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant(), "$name/AVCPublicAccess.$name.exe"
}
$hashes += '{0}  {1}' -f (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $installer -Leaf)
$hashes | Set-Content (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
$hashes | ForEach-Object { Write-Host $_ }
Write-Host "Package validated without executing installer: $installer"
