param(
  [switch]$WithHelpTags
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) {
  throw "Neovim ('nvim') is required to run this smoke check."
}

$luaScript = ((Resolve-Path (Join-Path $PSScriptRoot 'headless_smoke.lua')).Path -replace '\\', '/')

$nvimArgs = @(
  '--headless',
  '-u',
  'NONE',
  "+lua local ok, err = pcall(dofile, [[$luaScript]]); if not ok then vim.api.nvim_err_writeln(err); vim.cmd('cquit 1') end"
)

if ($WithHelpTags) {
  $nvimArgs += '+helptags doc'
}

$nvimArgs += '+qa'

& nvim @nvimArgs
if ($LASTEXITCODE -ne 0) {
  throw "Headless smoke failed with exit code $LASTEXITCODE."
}

Write-Host "Headless smoke passed." -ForegroundColor Green
