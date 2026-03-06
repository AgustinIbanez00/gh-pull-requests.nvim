param(
  [switch]$WithLuacheck,
  [switch]$WithCheckHealth
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
  throw "PowerShell ('pwsh') is required to run validation."
}

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) {
  throw "Neovim ('nvim') is required to run validation."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..')

Push-Location $repoRoot
try {
  Write-Host "[1/5] Headless smoke" -ForegroundColor Cyan
  & pwsh -File (Join-Path $scriptRoot 'headless_smoke.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw "Headless smoke failed with exit code $LASTEXITCODE."
  }

  Write-Host "[2/5] Neo-tree lazy smoke" -ForegroundColor Cyan
  & pwsh -File (Join-Path $scriptRoot 'neotree_lazy_smoke.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw "Neo-tree lazy smoke failed with exit code $LASTEXITCODE."
  }

  Write-Host "[3/5] Helptags validation" -ForegroundColor Cyan
  & nvim --headless -u NONE "+set rtp+=." "+helptags doc" "+qa"
  if ($LASTEXITCODE -ne 0) {
    throw "Helptags validation failed with exit code $LASTEXITCODE."
  }

  if ($WithLuacheck) {
    Write-Host "[4/5] luacheck (optional)" -ForegroundColor Cyan
    if (Get-Command luacheck -ErrorAction SilentlyContinue) {
      & luacheck lua plugin
      if ($LASTEXITCODE -ne 0) {
        throw "luacheck failed with exit code $LASTEXITCODE."
      }
    } else {
      Write-Host "luacheck is not installed; skipping optional lint step." -ForegroundColor Yellow
    }
  } else {
    Write-Host "[4/5] luacheck skipped (use -WithLuacheck to enable)." -ForegroundColor DarkGray
  }

  if ($WithCheckHealth) {
    Write-Host "[5/5] :checkhealth gh-pr (optional)" -ForegroundColor Cyan
    & nvim --headless -u NONE "+set rtp+=." "+checkhealth gh-pr" "+qa"
    if ($LASTEXITCODE -ne 0) {
      throw "checkhealth failed with exit code $LASTEXITCODE."
    }
  } else {
    Write-Host "[5/5] checkhealth skipped (use -WithCheckHealth to enable)." -ForegroundColor DarkGray
  }
}
finally {
  Pop-Location
}

Write-Host "Validation completed." -ForegroundColor Green
