[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [string]$PnpmCliPath,
    [string]$NodeDirectory,
    [string]$BuildDirectory,
    [switch]$SkipInstall,
    [switch]$Installer,
    [ValidateSet('internal', 'public')][string]$DistributionPurpose = 'internal'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $root '.build-cache/target' }
$env:CARGO_TARGET_DIR = [IO.Path]::GetFullPath($BuildDirectory)

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    # Windows PowerShell 5 treats native stderr warnings as ErrorRecords.
    # Preserve output, but decide success using the process exit code.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments 2>&1 | ForEach-Object { Write-Output "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { throw "$Executable failed ($code)." }
}
function Invoke-Pnpm([string[]]$Arguments) {
    if ($PnpmCliPath) { Invoke-Checked 'node' (@($PnpmCliPath) + $Arguments) }
    else { Invoke-Checked 'pnpm' $Arguments }
}

Push-Location $root
try {
    if ($NodeDirectory) {
        $nodePath = (Resolve-Path -LiteralPath $NodeDirectory).Path
        $env:Path = $nodePath + ';' + $env:Path
    }
    if ($PnpmCliPath) {
        $PnpmCliPath = (Resolve-Path -LiteralPath $PnpmCliPath).Path
        # Tauri's beforeBuildCommand also invokes pnpm.
        $pnpmBin = Join-Path (Split-Path (Split-Path (Split-Path $PnpmCliPath))) '.bin'
        $env:Path = $pnpmBin + ';' + $env:Path
    }
    $expectedNode = 'v' + (Get-Content -LiteralPath (Join-Path $root '.node-version') -Raw).Trim()
    $actualNode = & node --version
    if ($LASTEXITCODE -ne 0 -or $actualNode -ne $expectedNode) {
        throw "Expected Node $expectedNode, found $actualNode. Use prepare-node.py and -NodeDirectory."
    }
    Write-Output "Node $actualNode"
    Invoke-Checked 'cargo' @('--version')
    if (-not $SkipInstall) {
        Invoke-Pnpm @('install', '--frozen-lockfile')
        foreach ($folder in @('goal-dependencies', 'plugin-runtime')) {
            Push-Location (Join-Path $PSScriptRoot $folder)
            try { Invoke-Checked 'npm' @('ci', '--ignore-scripts', '--omit=optional', '--no-audit', '--no-fund') }
            finally { Pop-Location }
        }
    }
    Invoke-Checked 'python' @('scripts/dev/prepare-windows.py')
    Invoke-Checked 'node' @('scripts/dev/prepare-goal.mjs')
    Invoke-Checked 'node' @('scripts/dev/build-computer-use.mjs')
    Invoke-Pnpm @('--filter', '@ai4s/desktop', 'build')
    $cargoArgs = @('build', '--locked', '-p', 'osd-cli')
    if ($Configuration -eq 'Release') { $cargoArgs += '--release' }
    Invoke-Checked 'cargo' $cargoArgs
    Invoke-Checked 'python' @('scripts/dev/collect-distribution-notices.py')
    Invoke-Checked 'python' @('scripts/dev/check-distribution.py', '--purpose', $DistributionPurpose)
    $profile = $Configuration.ToLowerInvariant()
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR "$profile/osd.exe") -Destination 'apps/desktop/src-tauri/binaries/osd-x86_64-pc-windows-msvc.exe'
    $tauriArgs = @('--filter', '@ai4s/desktop', 'exec', 'tauri', 'build', '--ci', '--config', (Join-Path $PSScriptRoot 'tauri-prebuilt.json'))
    if ($Configuration -eq 'Debug') { $tauriArgs += '--debug' }
    if ($Installer) { $tauriArgs += @('--bundles', 'nsis') } else { $tauriArgs += '--no-bundle' }
    Invoke-Pnpm $tauriArgs
    Write-Output "Build complete: $env:CARGO_TARGET_DIR/$profile/chem-science-workbench.exe"
} finally { Pop-Location }
