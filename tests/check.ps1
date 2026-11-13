#requires -Version 5.1
<#
.SYNOPSIS
  Fast/full checks for the DSH cookie cleanup tool.

.DESCRIPTION
  -Fast runs static checks only: PowerShell/Python syntax, parameter/help
  coverage, and a scan for encoding-fragile console assertions in tests.
  -Full also runs tests\run-tests.ps1.  The default is -Full.

  The full suite temporarily registers a random scheduled task and starts
  temporary watchers.  It cleans them up before exiting.  Run it on a
  development machine, not against a production DSH profile.

.PARAMETER Fast
  Run static checks only.

.PARAMETER Full
  Run static checks and the full test suite.  This is the default.

.PARAMETER SkipPython
  Skip the Python syntax check (for machines without a usable Python 3).
#>
[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Full,
    [switch]$SkipPython
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tests = $PSScriptRoot
. (Join-Path $PSScriptRoot 'resolve-python.ps1')
$script:failures = 0

if ($Fast -and $Full) {
    Write-Host 'Use either -Fast or -Full.' -ForegroundColor Red
    exit 1
}
$runFull = $Full -or (-not $Fast)

function Write-CheckPass([string]$Message) {
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-CheckFail([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    $script:failures++
}

function Test-PowerShellSyntax {
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)
    $bad = @()
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors -and $errors.Count -gt 0) {
            foreach ($e in $errors) {
                $bad += ('{0}:{1}: {2}' -f $file.Name, $e.Extent.StartLineNumber, $e.Message)
            }
        }
    }
    if ($bad.Count -eq 0) {
        Write-CheckPass ('PowerShell syntax ({0} files)' -f $files.Count)
    } else {
        foreach ($line in $bad) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-CheckFail ('PowerShell syntax ({0} error(s))' -f $bad.Count)
    }
}

function Test-PythonSyntax {
    if ($SkipPython) {
        Write-Host '[SKIP] Python syntax (explicitly skipped)' -ForegroundColor Yellow
        return
    }
    $python = Resolve-Python
    if (-not $python) {
        Write-CheckFail 'Python 3 is required for the Python syntax check (use -SkipPython to omit it).'
        return
    }
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.py' -File -Recurse -ErrorAction SilentlyContinue)
    $bad = @()
    foreach ($file in $files) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $python -B -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" $file.FullName 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        if ($code -ne 0) { $bad += $file.Name }
    }
    if ($bad.Count -eq 0) {
        Write-CheckPass ('Python syntax ({0} files)' -f $files.Count)
    } else {
        Write-CheckFail ('Python syntax: {0}' -f ($bad -join ', '))
    }
}

function Get-HelpCoverage([string]$File) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if (-not $ast.ParamBlock -or $ast.ParamBlock.Parameters.Count -eq 0) { return $null }
    $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $help = @(Get-Content -LiteralPath $File | Select-String -Pattern '^\.PARAMETER\s+(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $missing = @($params | Where-Object { $help -notcontains $_ })
    $extra = @($help | Where-Object { $params -notcontains $_ })
    return [pscustomobject]@{
        Params  = $params.Count
        Help    = $help.Count
        Missing = $missing
        Extra   = $extra
    }
}

function Test-HelpCoverage {
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)
    $bad = @()
    foreach ($file in $files) {
        $coverage = Get-HelpCoverage -File $file.FullName
        if (-not $coverage) { continue }
        if ($coverage.Missing.Count -gt 0 -or $coverage.Extra.Count -gt 0) {
            $bad += ('{0}: params={1} help={2} missing=[{3}] extra=[{4}]' -f
                $file.Name, $coverage.Params, $coverage.Help,
                ($coverage.Missing -join ','), ($coverage.Extra -join ','))
        }
    }
    if ($bad.Count -eq 0) {
        Write-CheckPass 'Parameter/help coverage'
    } else {
        foreach ($line in $bad) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-CheckFail 'Parameter/help coverage'
    }
}

function Test-ConsoleAssertions {
    $files = @(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $bad = @()
    foreach ($file in $files) {
        $lineNo = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            $lineNo++
            if ($line -match '\.Output\s+-(match|notmatch|like|notlike|contains)\b' -and $line -match '[^\x00-\x7F]') {
                $bad += ('{0}:{1}' -f $file.Name, $lineNo)
            }
        }
    }
    if ($bad.Count -eq 0) {
        Write-CheckPass 'Console assertions use ASCII markers'
    } else {
        foreach ($line in $bad) { Write-Host "  $line" -ForegroundColor Yellow }
        Write-CheckFail ('Console assertions use non-ASCII text: {0}' -f ($bad -join ', '))
    }
}

function Invoke-FullSuite {
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
        $psExe = Join-Path $PSHOME 'pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
        Write-CheckFail 'Cannot find a PowerShell executable for the full suite.'
        return
    }
    $suite = Join-Path $tests 'run-tests.ps1'
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File $suite 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    $pass = @($output | Where-Object { [string]$_ -match '^\s*PASS:' }).Count
    $fail = @($output | Where-Object { [string]$_ -match '^\s*FAIL:' }).Count
    $skip = @($output | Where-Object { [string]$_ -match '^\s*SKIP:' }).Count
    $groups = @($output | Where-Object { [string]$_ -match '^Test: ' }).Count
    if ($code -eq 0 -and $fail -eq 0) {
        $skipNote = ''
        if ($skip -gt 0) { $skipNote = "; $skip skipped" }
        Write-CheckPass ('Full test suite ({0} groups / {1} assertions passed{2})' -f $groups, $pass, $skipNote)
    } else {
        foreach ($line in $output | Where-Object { [string]$_ -match '^\s*FAIL:|unexpected error|test\(s\) failed' }) {
            Write-Host "  $line" -ForegroundColor Yellow
        }
        Write-CheckFail ('Full test suite (exit={0}, {1} failed)' -f $code, $fail)
    }
}

try {
    Test-PowerShellSyntax
    Test-PythonSyntax
    Test-HelpCoverage
    Test-ConsoleAssertions
    if ($runFull) {
        Invoke-FullSuite
    }
} catch {
    Write-CheckFail ('Unexpected error: {0}' -f $_.Exception.Message)
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ('{0} check(s) failed.' -f $script:failures) -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
