# Pre-publish self check for this repo.
# Usage (works with Windows PowerShell 5.1 and PowerShell 7):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/check.ps1
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 reads
# .ps1 files as ANSI unless they carry a UTF-8 BOM, so non-ASCII output would
# turn into mojibake. Keep it ASCII.

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Ok($m)   { Write-Host "  OK   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  FAIL $m" -ForegroundColor Red; $script:fail++ }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }

Write-Host "repo root: $root`n"

# 1. required files
Write-Host "[1] required files"
$required = @(
    "README.md", "LICENSE", ".gitignore", "CONTRIBUTING.md", "CHANGELOG.md",
    "SECURITY.md", "CODE_OF_CONDUCT.md",
    "src\ch340_bridge.py", "src\flash51.sh", "src\build.sh", "src\led.c",
    "docs\TECH_NOTES.md", "docs\DEBUG_LOG.md", "docs\PROTOCOL.md", "docs\THIRD_PARTY.md",
    "tools\verify_divisor.py", "tools\check.ps1", "tools\push.ps1",
    ".github\workflows\ci.yml",
    ".github\ISSUE_TEMPLATE\bug_report.yml",
    ".github\ISSUE_TEMPLATE\feature_request.yml",
    ".github\ISSUE_TEMPLATE\config.yml"
)
foreach ($f in $required) {
    if (Test-Path (Join-Path $root $f)) { Ok $f } else { Bad "missing $f" }
}

# 2. line endings: shell/python/markdown must stay LF
Write-Host "`n[2] line endings (expect LF, CR count = 0)"
$lfFiles = @("src\ch340_bridge.py", "src\flash51.sh", "src\build.sh", "src\led.c",
             "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md",
             "docs\TECH_NOTES.md", "docs\DEBUG_LOG.md", "docs\PROTOCOL.md", "docs\THIRD_PARTY.md",
             "tools\verify_divisor.py", ".github\workflows\ci.yml")
foreach ($f in $lfFiles) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $cr = 0
    foreach ($x in $bytes) { if ($x -eq 13) { $cr++ } }
    if ($cr -eq 0) { Ok "$f  LF" } else { Bad "$f has $cr CR bytes (CRLF will break it in Termux)" }
}

# 3. leftover placeholders
# NOTE: README.md is skipped on purpose - it documents the publish workflow and
# therefore contains the literal placeholder strings.
Write-Host "`n[3] placeholders"
$phFiles = @("LICENSE", "SECURITY.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
             ".github\ISSUE_TEMPLATE\config.yml")
$hits = @()
foreach ($f in $phFiles) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { continue }
    $hits += Select-String -Path $p -Pattern "<YOUR NAME>|<YOUR EMAIL>|USER/REPO" -ErrorAction SilentlyContinue
}
if ($hits) {
    $hits | ForEach-Object { Warn "$($_.Filename):$($_.LineNumber)  $($_.Line.Trim())" }
    Warn "replace them before publishing (tools/push.ps1 -Name '...' -Email '...' does it for you)"
} else {
    Ok "no leftover placeholders"
}

# 4. syntax checks
Write-Host "`n[4] syntax"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if ($py) {
    $out = & $py.Source -m py_compile (Join-Path $root "src\ch340_bridge.py") 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "ch340_bridge.py compiles" } else { Bad "ch340_bridge.py: $out" }
    $out = & $py.Source (Join-Path $root "tools\verify_divisor.py") 2>&1
    if ($LASTEXITCODE -eq 0) { Ok "divisor regression passed" } else { Bad "divisor regression: $out" }
} else {
    Warn "python not found, skipping syntax checks"
}
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
    foreach ($f in @("src\flash51.sh", "src\build.sh")) {
        $out = (& $bash.Source -n (Join-Path $root $f) 2>&1) | Out-String
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { Ok "$f syntax ok" }
        elseif ($out -match "E_ACCESSDENIED|WSL|wsl|distribution") { Warn "$f skipped: local bash is a WSL stub with no distro" }
        else { Warn "$f bash -n exit=$rc" }
    }
} else {
    Warn "bash not found, skipping shell syntax check"
}

# 5. crude secret scan
Write-Host "`n[5] secret scan"
$sec = Select-String -Path (Join-Path $root "README.md"), (Join-Path $root "docs\*.md") `
                     -Pattern "ghp_|github_pat_|BEGIN .*PRIVATE KEY" -ErrorAction SilentlyContinue
if ($sec) { $sec | ForEach-Object { Bad "$($_.Filename):$($_.LineNumber) looks like a secret" } }
else { Ok "no obvious secrets" }

Write-Host ""
if ($fail -eq 0) { Write-Host "PASS - ready to commit." -ForegroundColor Green; exit 0 }
Write-Host "FAILED - $fail problem(s), fix before committing." -ForegroundColor Red
exit 1
