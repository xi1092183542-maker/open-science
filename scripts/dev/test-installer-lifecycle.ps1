# Exercise the real NSIS package using a fresh, caller-owned install directory.
# Never select the uninstaller's application-data deletion option.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$project = Split-Path $repo
$root = [IO.Path]::GetFullPath($TestRoot)
$projectPrefix = $project.TrimEnd('\') + '\'
if (-not $root.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test root must be inside the project.' }
if (Test-Path -LiteralPath $root) { throw 'Use a fresh test root.' }
$install = Join-Path $root 'install with spaces'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Chem Science Workbench Dev'
$productKey = 'HKCU:\Software\chemscience\Chem Science Workbench Dev'
if ((Test-Path $uninstallKey) -or (Test-Path $productKey)) { throw 'An installation/registration already exists; refusing to replace it.' }
if (Get-Process -Name 'chem-science-workbench' -ErrorAction SilentlyContinue) { throw 'Close the development workbench before testing.' }
$state = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'org.chemscience.workbench.dev'
if (-not (Test-Path -LiteralPath $state)) { throw 'First run the desktop smoke test to create owned development state.' }
$baseRecord = Join-Path $state 'runtime/base-workspace.txt'
$expectedWorkspace = [IO.Path]::GetFullPath((Join-Path $project '.build/smoke-desktop-01/workspace'))
if (-not (Test-Path -LiteralPath $baseRecord) -or [IO.File]::ReadAllText($baseRecord).Trim() -ne $expectedWorkspace) {
    throw 'Development state is no longer the previous smoke-test state; refusing to launch against it.'
}
New-Item -ItemType Directory -Path $root, (Join-Path $root 'unrelated installation') | Out-Null
$sentinelName = '.installer-test-' + [guid]::NewGuid().ToString('N') + '.txt'
$sentinel = Join-Path $state $sentinelName
[IO.File]::WriteAllText($sentinel, 'synthetic lifecycle sentinel')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$steps = [Collections.Generic.List[object]]::new()
$helpers = @()
$child = $null

function Invoke-Installer([string]$Executable, [string]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(180000)) { throw 'Installer exceeded 180 seconds.' }
        if ($process.ExitCode -ne 0) { throw "Installer returned $($process.ExitCode)." }
    } finally { $process.Dispose() }
}
function Assert-State {
    if ([IO.File]::ReadAllText($sentinel) -ne 'synthetic lifecycle sentinel') { throw 'Application state sentinel changed.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPath) { throw 'Installer changed user PATH.' }
}
try {
    # NSIS /D must be last and is intentionally not quoted, even with spaces.
    Invoke-Installer $installerPath "/S /NS /D=$install"
    $binary = Join-Path $install 'chem-science-workbench.exe'
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Installed desktop executable missing.' }
    $registration = Get-ItemProperty $uninstallKey
    if ($registration.InstallLocation.Trim('"') -ne $install) { throw 'Installer registered an unexpected directory.' }
    $originalUvHash = (Get-FileHash -LiteralPath (Join-Path $install 'uv.exe') -Algorithm SHA256).Hash
    Assert-State
    $steps.Add(@{ step = 'install'; pass = $true; version = $registration.DisplayVersion; directory = $install })

    $notices = Join-Path $install 'third-party-notices/dependencies'
    $noticeIndex = Join-Path $notices 'index.json'
    $sourceIndex = Join-Path $repo 'runtime/third-party-notices/dependencies/index.json'
    if ((Get-FileHash -LiteralPath $noticeIndex).Hash -ne (Get-FileHash -LiteralPath $sourceIndex).Hash) { throw 'Installed distribution index differs from build input.' }
    $inventory = Get-Content -LiteralPath $noticeIndex -Raw -Encoding UTF8 | ConvertFrom-Json
    $checkedNotices = 0
    foreach ($component in $inventory.components) {
        $records = @($component.notices)
        if ($component.unmodifiedSourceArchive) { $records += $component.unmodifiedSourceArchive }
        foreach ($record in $records) {
            $file = [IO.Path]::GetFullPath((Join-Path $notices $record.path))
            if (-not $file.StartsWith($notices.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Notice path escapes the installed directory.' }
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $record.sha256) { throw "Installed notice/source archive mismatch: $($record.path)" }
            $checkedNotices++
        }
    }
    $steps.Add(@{ step = 'installed-distribution-evidence'; pass = $true; components = $inventory.components.Count; checkedFiles = $checkedNotices; distributionCleared = $inventory.distributionCleared })

    $child = Start-Process -FilePath $binary -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root 'desktop.stderr.log')
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do { Start-Sleep -Milliseconds 500; $child.Refresh() } while (-not $child.HasExited -and $child.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($child.HasExited -or $child.MainWindowHandle -eq 0) { throw 'Installed desktop did not create a window.' }
    Start-Sleep -Seconds 10
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($child.Id)" | Where-Object Name -eq 'opencode.exe')
    if ($children.Count -ne 1) { throw 'Installed desktop did not start exactly one runtime child.' }
    if (-not $child.CloseMainWindow() -or -not $child.WaitForExit(15000)) { throw 'Installed desktop did not close normally.' }
    foreach ($runtime in $children) {
        if (Get-Process -Id $runtime.ProcessId -ErrorAction SilentlyContinue) { throw 'Runtime survived desktop close.' }
    }
    $child.Dispose(); $child = $null
    $steps.Add(@{ step = 'installed-app-start-close'; pass = $true; runtimeChildrenExited = $true })

    # A disposable stub keeps an installed helper path locked. Reinstall must
    # terminate that handle, repair the file, and preserve a same-name sibling.
    $source = Join-Path $root 'stub.cs'
    [IO.File]::WriteAllText($source, 'class Stub { static void Main() { System.Threading.Thread.Sleep(300000); } }')
    $stub = Join-Path $root 'unrelated installation/uv.exe'
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$stub" $source
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile helper stub.' }
    Copy-Item -LiteralPath $stub -Destination (Join-Path $install 'uv.exe') -Force
    $helpers += Start-Process -FilePath (Join-Path $install 'uv.exe') -WindowStyle Hidden -PassThru
    $helpers += Start-Process -FilePath $stub -WindowStyle Hidden -PassThru
    Invoke-Installer $installerPath "/S /NS /UPDATE /D=$install"
    $helpers[0].Refresh(); $helpers[1].Refresh()
    if (-not $helpers[0].HasExited -or $helpers[1].HasExited) {
        throw "Reinstall helper isolation failed: ownedExited=$($helpers[0].HasExited), unrelatedExited=$($helpers[1].HasExited)."
    }
    if ((Get-FileHash -LiteralPath (Join-Path $install 'uv.exe')).Hash -ne $originalUvHash) { throw 'Reinstall did not restore the original helper bytes.' }
    Assert-State
    $steps.Add(@{ step = 'same-version-update-repair'; pass = $true; unrelatedHelperSurvived = $true; helperHashRestored = $true })

    # Lock the owned helper again so the real uninstall hook is exercised too.
    Copy-Item -LiteralPath $stub -Destination (Join-Path $install 'uv.exe') -Force
    $helpers += Start-Process -FilePath (Join-Path $install 'uv.exe') -WindowStyle Hidden -PassThru
    $uninstaller = Join-Path $install 'uninstall.exe'
    Invoke-Installer $uninstaller "/S _?=$install"
    $helpers[2].Refresh(); $helpers[1].Refresh()
    if (-not $helpers[2].HasExited -or $helpers[1].HasExited) { throw 'Uninstall helper isolation failed.' }
    if ((Test-Path -LiteralPath $binary) -or (Test-Path $uninstallKey)) { throw 'Installed executable or uninstall entry survived.' }
    Assert-State
    $steps.Add(@{ step = 'uninstall-retain-data'; pass = $true; dataPreserved = $true; unrelatedHelperSurvived = $true })
    # NSIS deliberately retains this product-specific location preference when
    # keeping app data. Remove only the key this test created and verified.
    if (Test-Path $productKey) {
        if ((Get-Item $productKey).GetValue('') -ne $install) { throw 'Unexpected product registration; leave it for review.' }
        Remove-Item -LiteralPath $productKey
    }
    [IO.File]::WriteAllText((Join-Path $root 'result.json'), (@{ steps = $steps.ToArray(); installer = $installerPath; cleanOperatingSystem = $false; appDataDeletionTested = $false; versionUpgradeTested = $false; modelPromptsSent = 0 } | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
    Write-Output "PASS: install, installed app startup/close, same-version repair, uninstall with data retention. Evidence: $root"
} finally {
    if ($null -ne $child -and -not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
    foreach ($helper in $helpers) {
        if (-not $helper.HasExited) { Stop-Process -InputObject $helper -Force }
        $helper.Dispose()
    }
    # Keep install files/registrations on failure for diagnosis; never guess at cleanup.
    [IO.File]::WriteAllText((Join-Path $root 'completed-steps.json'), (ConvertTo-Json -InputObject $steps.ToArray() -Depth 7), [Text.UTF8Encoding]::new($false))
}
