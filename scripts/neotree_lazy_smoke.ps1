param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) {
  throw "Neovim ('nvim') is required to run this smoke check."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..')

Push-Location $repoRoot
try {
  $nvimArgs = @(
    '--headless',
    '-u',
    'NONE',
    '+set rtp+=.',
    '+lua dofile("scripts/neotree_lazy_smoke.lua")',
    '+qa'
  )

  & nvim @nvimArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Neo-tree lazy smoke failed with exit code $LASTEXITCODE."
  }
}
finally {
  Pop-Location
}

Write-Host "Neo-tree lazy smoke passed." -ForegroundColor Green
