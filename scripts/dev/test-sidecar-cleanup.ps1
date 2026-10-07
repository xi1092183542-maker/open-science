# Spawn disposable helper stubs; verify exact-path isolation against a sibling.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('chem-cleanup-' + [guid]::NewGuid().ToString('N'))
$owned = Join-Path $root 'install'
$other = Join-Path $root 'install-other'
$processes = @()
try {
    New-Item -ItemType Directory -Path $owned, $other | Out-Null
    $source = Join-Path $root 'stub.cs'
    Set-Content -LiteralPath $source -Encoding ASCII -Value 'class Stub { static void Main() { System.Threading.Thread.Sleep(120000); } }'
    $binary = Join-Path $owned 'uv.exe'
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$binary" $source
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile helper stub.' }
    Copy-Item -LiteralPath $binary -Destination (Join-Path $other 'uv.exe')
    $processes += Start-Process -FilePath $binary -WindowStyle Hidden -PassThru
    $processes += Start-Process -FilePath (Join-Path $other 'uv.exe') -WindowStyle Hidden -PassThru
    $hook = Join-Path $PSScriptRoot '../../apps/desktop/src-tauri/nsis/stop-owned-sidecars.ps1'
    & powershell.exe -NoProfile -NonInteractive -File $hook -InstallDir $owned
    if ($LASTEXITCODE -ne 0) { throw 'Cleanup hook failed.' }
    $processes[0].Refresh()
    $processes[1].Refresh()
    if (-not $processes[0].HasExited) { throw 'Installation-owned helper survived.' }
    if ($processes[1].HasExited) { throw 'Unrelated helper was terminated.' }
    Write-Output 'PASS: owned helper exited; same-name helper in sibling installation survived.'
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { Stop-Process -InputObject $process -Force }
        $process.Dispose()
    }
    # Only remove the exact GUID directory created above, using native PowerShell.
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
