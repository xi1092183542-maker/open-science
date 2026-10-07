[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Binary, [Parameter(Mandatory = $true)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$binaryPath = (Resolve-Path -LiteralPath $Binary).Path
$root = [IO.Path]::GetFullPath($TestRoot)
$state = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'org.chemscience.workbench.dev'
# This test must never adopt an existing installation's state.
if (Test-Path -LiteralPath $state) { throw "Development state already exists; refusing to overwrite: $state" }
if (Test-Path -LiteralPath $root) { throw 'Use a fresh test directory.' }
$workspace = Join-Path $root 'workspace'
New-Item -ItemType Directory -Path $workspace, (Join-Path $state 'runtime') | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
foreach ($record in @('base-workspace.txt', 'active-workspace.txt')) {
    [IO.File]::WriteAllText((Join-Path $state "runtime/$record"), $workspace, $utf8)
}
$pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$child = Start-Process -FilePath $binaryPath -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'desktop.stdout.log') -RedirectStandardError (Join-Path $root 'desktop.stderr.log')
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $child.Refresh()
        if ($child.HasExited) { throw "Desktop exited with $($child.ExitCode)." }
    } while ($child.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($child.MainWindowHandle -eq 0) { throw 'No desktop window appeared.' }
    Start-Sleep -Seconds 12
    $child.Refresh()
    $window = [Windows.Automation.AutomationElement]::FromHandle($child.MainWindowHandle)
    $elements = $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $names = @($window.Current.Name)
    foreach ($element in $elements) {
        if ($element.Current.Name) { $names += $element.Current.Name }
    }
    [IO.File]::WriteAllText((Join-Path $root 'window-text.json'), ($names | ConvertTo-Json), $utf8)
    if (-not ($names -match 'Chem Science')) { throw 'Fork identity missing from window.' }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $pathBefore) { throw 'Startup unexpectedly modified user PATH.' }
    $runtimeProcesses = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($child.Id)" | Where-Object { $_.Name -eq 'opencode.exe' })
    $result = @{ window = $child.MainWindowTitle; windowPresent = $true; accessibilityNodes = $elements.Count; directRuntimeChildren = $runtimeProcesses.Count; userPathUnchanged = $true; modelCalls = 0; dataDirectory = $state; workspace = $workspace }
    if (-not $child.CloseMainWindow()) { throw 'Window did not accept close request.' }
    if (-not $child.WaitForExit(15000)) { throw 'Desktop did not exit within 15 seconds.' }
    foreach ($runtime in $runtimeProcesses) {
        if (Get-Process -Id $runtime.ProcessId -ErrorAction SilentlyContinue) { throw 'Runtime child survived desktop close.' }
    }
    $result['normalClose'] = $true
    [IO.File]::WriteAllText((Join-Path $root 'result.json'), ($result | ConvertTo-Json), $utf8)
    $result | ConvertTo-Json
} finally {
    if (-not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
    $child.Dispose()
    # Retain the new development state and test evidence for inspection.
}
