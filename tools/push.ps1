# Publish this repository to GitHub. Prefers the GitHub CLI; falls back to plain git.
#
# USAGE (works with Windows PowerShell 5.1 and PowerShell 7):
#   # Easiest: let gh create the repo and push
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1
#
#   # Private repo
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1 -Visibility private
#
#   # Local commit only, no push
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1 -NoPush
#
#   # Without gh: push to an existing remote
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/push.ps1 -Remote "https://github.com/USER/REPO.git"
#
# WHAT IT DOES
#   1. detects author name / email / GitHub login from gh and git config
#   2. replaces the placeholders <YOUR NAME>, <YOUR EMAIL>, USER/REPO
#   3. runs tools/check.ps1 and aborts if it fails
#   4. git init (if needed) -> add -> commit
#   5. creates the repo with gh (or reuses it) and pushes; otherwise uses git push
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 decodes
# .ps1 files as ANSI (GBK on Chinese Windows) unless they carry a UTF-8 BOM,
# which turns non-ASCII paths in the script into mojibake. Chinese documentation
# lives in README.md / docs/.

param(
    [string]$RepoName = "stc51-android-flasher",
    [ValidateSet("public", "private", "internal")]
    [string]$Visibility = "public",
    [string]$Description = "Flash STC89C52 (8051) from an unrooted Android phone over CH340 - userspace USB driver + pty bridge",
    [string]$Name = "",
    [string]$Email = "",
    [string]$Remote = "",
    [string]$Branch = "main",
    [switch]$NoPush,
    [switch]$SkipCheck,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Info($m) { Write-Host $m -ForegroundColor Cyan }
function Good($m) { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Die($m)  { Write-Host $m -ForegroundColor Red; exit 1 }

# Queries below deliberately run before "git init", so they must not abort the
# script when the directory is not yet a repository (git exits 128 there).
function GitTry($gitArgs) {
    $out = & cmd /c "git $gitArgs 2>nul"
    if ($LASTEXITCODE -ne 0) { return @() }
    $out | Where-Object { $_ -ne "" }
}

# ------------------------------------------------------------------ 0. toolchain
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not found. Install it first: winget install Git.Git"
}
$gh = Get-Command gh -ErrorAction SilentlyContinue
$ghOk = $false
if ($gh) {
    & gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { $ghOk = $true }
    else { Warn "gh found but not authenticated; falling back to plain git. Run: gh auth login" }
}

# ------------------------------------------------------------------ 1. author info
$ghUser = ""
if ($ghOk) {
    $ghUser = (& gh api user --jq ".login" 2>$null | Select-Object -First 1)
    if ($ghUser) { $ghUser = $ghUser.Trim() }
}
if (-not $Name) {
    $Name = (GitTry "config user.name" | Select-Object -First 1)
    if (-not $Name) { $Name = $ghUser }
}
if (-not $Email) { $Email = (GitTry "config user.email" | Select-Object -First 1) }

Info ("author name : " + $(if ($Name) { $Name } else { "<none>" }))
Info ("author email: " + $(if ($Email) { $Email } else { "<none>" }))
Info ("gh login    : " + $(if ($ghUser) { $ghUser } else { "<none>" }))
Write-Host ""

# ------------------------------------------------------------------ 2. owner / repo
$owner = ""
$existingRemote = ""
$remotes = GitTry "remote"
if ($remotes -contains "origin") {
    $existingRemote = (GitTry "remote get-url origin" | Select-Object -First 1)
    Info "existing origin: $existingRemote"
    if ($existingRemote -match "github\.com[:/]([^/]+)/(.+?)(\.git)?$") {
        $owner = $Matches[1]
        $RepoName = $Matches[2]
    }
}
if (-not $owner -and $ghUser) { $owner = $ghUser }
if (-not $owner -and $Remote -match "github\.com[:/]([^/]+)/") { $owner = $Matches[1] }

$slug = ""
if ($owner -and $RepoName) { $slug = "$owner/$RepoName" }
if (-not $Remote -and $slug) { $Remote = "https://github.com/$slug.git" }
Info ("target repo : " + $(if ($Remote) { $Remote } else { "<unknown>" }))
Write-Host ""

# ------------------------------------------------------------------ 3. placeholders
$today = (Get-Date).ToString("yyyy-MM-dd")
$placeholderFiles = @(
    "README.md", "LICENSE", "SECURITY.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
    ".github\ISSUE_TEMPLATE\config.yml"
)
$changed = @()
foreach ($f in $placeholderFiles) {
    $p = Join-Path $root $f
    if (-not (Test-Path $p)) { continue }
    $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    $orig = $t
    if ($Name  -and $t -match "<YOUR NAME>")  { $t = $t -replace "<YOUR NAME>", $Name }
    if ($Email -and $t -match "<YOUR EMAIL>") { $t = $t -replace "<YOUR EMAIL>", $Email }
    if ($slug  -and $t -match "USER/REPO")    { $t = $t -replace "USER/REPO", $slug }
    if ($t -ne $orig) {
        [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
        $changed += $f
    }
}
if ($changed) { Good ("placeholders updated in: " + ($changed -join ", ")) }
else { Warn "no placeholders needed updating (already replaced?)" }

if (-not $SkipCheck) {
    Write-Host ""
    Info "running tools/check.ps1 ..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "tools\check.ps1")
    if ($LASTEXITCODE -ne 0) {
        if ($Force) { Warn "check failed but -Force was given; continuing." }
        else { Die "check failed, aborting. Fix it, or pass -SkipCheck / -Force." }
    }
}

# ------------------------------------------------------------------ 4. git init + commit
if (-not (Test-Path (Join-Path $root ".git"))) {
    git init | Out-Null
    Good "git init done"
}
git symbolic-ref HEAD "refs/heads/$Branch" 2>$null | Out-Null

git add -A
$staged = git diff --cached --name-only
if (-not $staged) {
    Warn "nothing to commit."
} else {
    Info ("staging " + $staged.Count + " file(s):")
    $staged | ForEach-Object { "  $_" }
    $msg = "feat: flash STC89C52 from an unrooted Android phone over CH340`n`n" +
           "- userspace CH340 driver + pty bridge, stcgal/pyserial need no changes`n" +
           "- one-shot build (build.sh) and flash (flash51.sh), plus a sample led.c`n" +
           "- docs: tech notes, 14-case debugging log, protocol reference, licenses, credits`n`n" +
           "Prior art: stcgal (MIT), Linux ch341.c divisor algorithm, termux-usb, Termux-serial-tty`n" +
           "Developed with AI assistance plus on-hardware debugging; see README.`n" +
           "Date: $today"
    $commitArgs = @("commit", "-m", $msg)
    if ($Email) { $commitArgs = @("-c", "user.email=$Email") + $commitArgs }
    if ($Name)  { $commitArgs = @("-c", "user.name=$Name") + $commitArgs }
    & git @commitArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Warn "commit failed. Configure a git identity first:"
        Write-Host '  git config --global user.name "Your Name"'
        Write-Host '  git config --global user.email "you@example.com"'
        Write-Host "or pass -Name and -Email to this script."
        exit 1
    }
    Good "committed."
}

if ($NoPush) {
    Write-Host ""
    Good "local commit only (-NoPush). To publish later:"
    Write-Host "  gh repo create $RepoName --$Visibility --source . --push"
    exit 0
}

# ------------------------------------------------------------------ 5. create + push
if ($ghOk -and $slug) {
    & gh repo view $slug *> $null
    if ($LASTEXITCODE -eq 0) {
        Warn "remote repo $slug already exists; reusing it."
    } else {
        Info "creating $slug ($Visibility) with gh ..."
        & gh repo create $slug "--$Visibility" --source . --description $Description
        if ($LASTEXITCODE -ne 0) { Die "gh repo create failed; see output above." }
        Good "repository created."
    }
    Info "pushing branch $Branch ..."
    & gh repo set-default $slug *> $null
    & git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) { Die "git push failed." }
    $url = (& gh repo view $slug --json url --jq ".url" 2>$null | Select-Object -First 1)
    Write-Host ""
    Good ("done: " + $url)
    Write-Host "next: check the Actions tab - CI runs on the first push."
} else {
    if (-not $Remote) { Die "no usable gh and no -Remote; pass -Remote or run gh auth login." }
    if ($remotes -contains "origin") { git remote set-url origin $Remote } else { git remote add origin $Remote }
    Info "pushing to $Remote ..."
    git push -u origin $Branch
    if ($LASTEXITCODE -ne 0) { Die "push failed (auth or branch name)." }
    Write-Host ""
    Good "done."
}
