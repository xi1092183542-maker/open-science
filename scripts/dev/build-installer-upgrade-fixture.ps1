# Package one existing application payload under two installer versions.
# This exercises NSIS upgrade handling, not application/database migrations.
# Use zlib for these disposable fixtures to shorten repeated packaging.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BuildDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$NodeDirectory,
    [string]$PnpmCliPath
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
$projectPrefix = (Split-Path $repo).TrimEnd('\') + '\'
if (-not $output.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture output must be inside the project.' }
if (Test-Path -LiteralPath $output) { throw 'Use a fresh fixture output directory.' }
$env:CARGO_TARGET_DIR = (Resolve-Path -LiteralPath $BuildDirectory).Path
if ($NodeDirectory) { $env:Path = (Resolve-Path -LiteralPath $NodeDirectory).Path + ';' + $env:Path }
if ($PnpmCliPath) { $PnpmCliPath = (Resolve-Path -LiteralPath $PnpmCliPath).Path }
$expectedNode = 'v' + (Get-Content (Join-Path $repo '.node-version') -Raw).Trim()
if ((& node --version) -ne $expectedNode) { throw "Expected Node $expectedNode." }
$baseConfig = Get-Content (Join-Path $repo 'apps/desktop/src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json
if ($baseConfig.bundle.windows.allowDowngrades -ne $false) { throw 'Disable downgrades before building the fixtures.' }
$baseVersion = [version]$baseConfig.version
$upgradeVersion = '{0}.{1}.{2}' -f $baseVersion.Major, $baseVersion.Minor, ($baseVersion.Build + 1)
New-Item -ItemType Directory -Path $output | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$marker = Join-Path $output 'installer-fixture.json'
[IO.File]::WriteAllText($marker, (@{ installerFixtureOnly = $true; applicationPayloadVersion = $baseConfig.version; installerVersion = $upgradeVersion } | ConvertTo-Json), $utf8)
$resources = @{}; $resources[$marker] = 'installer-fixture.json'
$baseOverride = Join-Path $output 'base-config.json'
[IO.File]::WriteAllText($baseOverride, '{"bundle":{"windows":{"nsis":{"compression":"zlib"}}}}', $utf8)
$override = Join-Path $output 'upgrade-config.json'
[IO.File]::WriteAllText($override, (@{ version = $upgradeVersion; bundle = @{ resources = $resources; windows = @{ nsis = @{ compression = 'zlib' } } } } | ConvertTo-Json -Depth 6), $utf8)

function Invoke-Bundle([string]$ConfigPath) {
    $arguments = @('--filter', '@ai4s/desktop', 'exec', 'tauri', 'bundle', '--debug', '--bundles', 'nsis', '--ci')
    if ($ConfigPath) { $arguments += @('--config', $ConfigPath) }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($PnpmCliPath) { & node $PnpmCliPath @arguments 2>&1 | ForEach-Object { Write-Output "$_" } }
        else { & pnpm @arguments 2>&1 | ForEach-Object { Write-Output "$_" } }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { throw "Fixture bundling failed ($code)." }
}
Push-Location $repo
try {
    Invoke-Bundle $baseOverride
    $base = Join-Path $env:CARGO_TARGET_DIR "debug/bundle/nsis/$($baseConfig.productName)_$($baseConfig.version)_x64-setup.exe"
    Copy-Item -LiteralPath $base -Destination (Join-Path $output 'base-setup.exe')
    Invoke-Bundle $override
    $upgrade = Join-Path $env:CARGO_TARGET_DIR "debug/bundle/nsis/$($baseConfig.productName)_${upgradeVersion}_x64-setup.exe"
    Copy-Item -LiteralPath $upgrade -Destination (Join-Path $output 'upgrade-setup.exe')
    $manifest = @{ installerFixtureOnly = $true; applicationMigrationTested = $false; baseVersion = $baseConfig.version; upgradeVersion = $upgradeVersion; packages = @(
        @{ path = 'base-setup.exe'; sha256 = (Get-FileHash (Join-Path $output 'base-setup.exe')).Hash },
        @{ path = 'upgrade-setup.exe'; sha256 = (Get-FileHash (Join-Path $output 'upgrade-setup.exe')).Hash }
    ) }
    [IO.File]::WriteAllText((Join-Path $output 'fixture-manifest.json'), ($manifest | ConvertTo-Json -Depth 5), $utf8)
    Write-Output "PASS: fixture packages $($baseConfig.version) -> $upgradeVersion; unchanged application payload."
} finally { Pop-Location }
