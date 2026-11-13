# Shared Python resolver for tests/check.ps1 and tests/run-tests.ps1.
# Keep this in sync with Resolve-Python in cleanup.ps1:
# env override -> DSH runtime -> PATH python/python3 -> py.exe; skip WindowsApps.

function Resolve-Python {
    $candidates = @()
    if ($env:DSH_COOKIE_CLEANUP_PYTHON) { $candidates += $env:DSH_COOKIE_CLEANUP_PYTHON }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe')
    }
    foreach ($candidate in $candidates) {
        if ($candidate -match '(?i)\\WindowsApps\\') { continue }
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($name in @('python.exe', 'python', 'python3.exe', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd -or -not $cmd.Source) { continue }
        if ($cmd.Source -match '(?i)\\WindowsApps\\') { continue }
        return $cmd.Source
    }
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py -and $py.Source -and $py.Source -notmatch '(?i)\\WindowsApps\\') {
        return $py.Source
    }
    return $null
}
