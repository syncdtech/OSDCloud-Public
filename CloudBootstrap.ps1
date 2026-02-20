[CmdletBinding()]
param(
  [string]$Owner      = "syncdtech",
  [string]$Repo       = "OSDCloud",
  [string]$Branch     = "main",
  [string]$RepoPath   = "",
  # CHANGED: default mirror location is now the OSDCloud root
  [string]$TargetRoot = "X:\OSDCloud",
  [switch]$SkipRun,
  [switch]$Clean,
  [int]$MaxRetries    = 3,
  [int]$TimeoutSec    = 60
)

$ErrorActionPreference = 'Stop'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072 } catch { }

$logDir  = 'X:\OSDCloud\Logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("CloudBootstrap_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
  param([string]$Message,[ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
  $line = "[{0}][{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Write-Host $line
  Add-Content -Path $logFile -Value $line
}

Write-Log "=== CloudBootstrap start ==="
Write-Log "Owner=$Owner Repo=$Repo Branch=$Branch RepoPath='$RepoPath' TargetRoot='$TargetRoot' SkipRun=$SkipRun Clean=$Clean"

# Load PAT from SetToken.ps1
$setTokenPath = "X:\OSDCloud\Scripts\SetToken.ps1"
if (Test-Path $setTokenPath) { . $setTokenPath } else { Write-Log "Warn: $setTokenPath not found" 'WARN' }
if ([string]::IsNullOrWhiteSpace($env:GITHUB_PAT)) { throw "GITHUB_PAT not set. Ensure SetToken.ps1 defines it." }

# Quick connectivity sanity
foreach ($u in "https://api.github.com","https://raw.githubusercontent.com") {
  try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 | Out-Null }
  catch { throw "Cannot reach $u : $($_.Exception.Message)" }
}

# Prepare target and optional clean
New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
if ($Clean) {
  $wipePath = if ($RepoPath) { Join-Path $TargetRoot ($RepoPath -replace '^[\\/]+','') } else { $TargetRoot }
  if (Test-Path $wipePath) { Remove-Item -LiteralPath $wipePath -Recurse -Force }
}

# Headers & retry helpers
$Headers = @{ Authorization = "token $($env:GITHUB_PAT)"; 'User-Agent' = 'OSDCloud-Bootstrap'; Accept = 'application/vnd.github+json' }

function Invoke-WithRetry {
  param([scriptblock]$Script,[int]$Max = $MaxRetries,[int]$DelayStartMs = 500)
  $try=0; $delay=[double]$DelayStartMs
  while ($true) {
    try { return & $Script }
    catch { $try++; if ($try -ge $Max) { throw }; Start-Sleep -Milliseconds [int]$delay; $delay=[Math]::Min($delay*2,8000) }
  }
}

function Get-GitHubApiJson { param([string]$ApiUrl)
  Invoke-WithRetry { Invoke-WebRequest -Uri $ApiUrl -Headers $Headers -UseBasicParsing -TimeoutSec $TimeoutSec } |
    ForEach-Object { $_.Content | ConvertFrom-Json }
}

function Save-RawFile {
  param([string]$Owner,[string]$Repo,[string]$Branch,[string]$PathInRepo,[string]$OutFile)
  $rawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/$PathInRepo"
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
  Invoke-WithRetry { Invoke-WebRequest -Uri $rawUrl -Headers $Headers -UseBasicParsing -TimeoutSec $TimeoutSec -OutFile $OutFile } | Out-Null
}

function Sync-GitHubFolder {
  param([string]$Owner,[string]$Repo,[string]$Branch,[string]$RepoFolder,[string]$TargetFolder)
  $api = "https://api.github.com/repos/$Owner/$Repo/contents"; if ($RepoFolder) { $api = "$api/$($RepoFolder -replace '^[\\/]+','')" }; $api="$api?ref=$Branch"
  $items = Get-GitHubApiJson -ApiUrl $api
  foreach ($i in $items) {
    switch ($i.type) {
      'file' {
        $rel = if ($RepoFolder) { Join-Path $RepoFolder $i.name } else { $i.name }
        Save-RawFile -Owner $Owner -Repo $Repo -Branch $Branch -PathInRepo $rel -OutFile (Join-Path $TargetFolder $i.name)
      }
      'dir' {
        $subRepo = if ($RepoFolder) { Join-Path $RepoFolder $i.name } else { $i.name }
        Sync-GitHubFolder -Owner $Owner -Repo $Repo -Branch $Branch -RepoFolder $subRepo -TargetFolder (Join-Path $TargetFolder $i.name)
      }
      default { Write-Log "Skip $($i.type): $($i.path)" 'WARN' }
    }
  }
}

# Mirror full repo (or subfolder) to X:\OSDCloud
$rootRel = ($RepoPath -replace '^[\\/]+','')
$dest    = if ($rootRel) { Join-Path $TargetRoot $rootRel } else { $TargetRoot }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Sync-GitHubFolder -Owner $Owner -Repo $Repo -Branch $Branch -RepoFolder $rootRel -TargetFolder $dest
Write-Log "Mirror complete: $dest"

# Entrypoint discovery (at X:\OSDCloud)
if ($SkipRun) { Write-Log "SkipRun specified; not launching any script."; return }

$entryToRun = $null; [string[]]$entryArgs = @()

# 1) .entrypoint at X:\OSDCloud
$entryFile = Join-Path $TargetRoot ".entrypoint"
if (Test-Path $entryFile) {
  $line = (Get-Content -Raw $entryFile).Trim()
  if ($line) {
    $matches = [regex]::Matches($line,'("[^"]*"|''[^'']*''|\S+)')
    if ($matches.Count) {
      $parts = @(); foreach ($m in $matches) { $parts += ($m.Value.Trim('"','''')) }
      $relPath = $parts[0]; $entryToRun = Join-Path $TargetRoot $relPath
      if ($parts.Count -gt 1) { $entryArgs = $parts[1..($parts.Count-1)] }
    }
  }
}

# 2) X:\OSDCloud\Scripts\Start.ps1
if (-not $entryToRun) {
  $cand = Join-Path $TargetRoot "Scripts\Start.ps1"
  if (Test-Path $cand) { $entryToRun = $cand }
}

# 3) X:\OSDCloud\Start.ps1
if (-not $entryToRun) {
  $cand = Join-Path $TargetRoot "Start.ps1"
  if (Test-Path $cand) { $entryToRun = $cand }
}

if ($entryToRun -and (Test-Path $entryToRun)) {
  Write-Log ("Launching: {0} {1}" -f $entryToRun, ($entryArgs -join ' '))
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $entryToRun) + $entryArgs
  $p = Start-Process -FilePath powershell.exe -ArgumentList $argList -PassThru
  $p.WaitForExit(); if ($p.ExitCode -ne 0) { throw "Entrypoint exit code $($p.ExitCode)" }
} else {
  Write-Log "No entrypoint found (.entrypoint, Scripts\Start.ps1, Start.ps1)."
}

Write-Log "=== CloudBootstrap complete ==="
