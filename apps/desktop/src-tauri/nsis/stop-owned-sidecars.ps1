[CmdletBinding(SupportsShouldProcess = $true)]
param([Parameter(Mandatory = $true)][string]$InstallDir)

$ErrorActionPreference = 'Stop'
try {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw 'Helper cleanup requires native 64-bit PowerShell; 32-bit process paths are incomplete.'
    }
    $root = [IO.Path]::GetFullPath($InstallDir)
    $expected = @('opencode.exe', 'uv.exe', 'agent-browser.exe', 'osd.exe') |
        ForEach-Object { [IO.Path]::Combine($root, $_) }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $candidates = Get-CimInstance Win32_Process -Filter "Name = 'opencode.exe' OR Name = 'uv.exe' OR Name = 'agent-browser.exe' OR Name = 'osd.exe'"
    foreach ($candidate in $candidates) {
        if (-not $candidate.ExecutablePath -or $expected -notcontains $candidate.ExecutablePath) { continue }
        $owner = Invoke-CimMethod -InputObject $candidate -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne $currentSid) { continue }
        $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.HasExited) { continue }
        # Recheck the live handle before terminating; enumeration may be stale.
        if ($expected -notcontains $process.Path) { continue }
        if ($PSCmdlet.ShouldProcess($process.Path, 'Stop installation-owned helper')) {
            Stop-Process -InputObject $process -Force
            if (-not $process.WaitForExit(5000)) { throw 'Helper did not exit in time.' }
        }
    }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
