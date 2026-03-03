param(
  [switch]$WithHelpTags
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command nvim -ErrorAction SilentlyContinue)) {
  throw "Neovim ('nvim') is required to run this smoke check."
}

$nvimArgs = @(
  '--headless',
  '-u',
  'NONE',
  '+set rtp+=.',
  '+runtime plugin/gh-pr.lua',
  '+lua require("gh-pr").setup({ ui = { use_neotree = false, telescope_fallback = false } })',
  '+lua assert(vim.fn.exists(":GhPrOpen") == 2, "Missing :GhPrOpen command")',
  '+lua assert(vim.fn.exists(":GhPrReviewRefresh") == 2, "Missing :GhPrReviewRefresh command")',
  '+lua assert(vim.fn.exists(":GhPRReviewRefresh") == 2, "Missing :GhPRReviewRefresh alias")',
  '+lua assert(vim.fn.maparg("<Plug>(gh-pr-open)", "n") ~= "", "Missing <Plug>(gh-pr-open)")',
  '+lua assert(vim.fn.maparg("<Plug>(gh-pr-review-refresh)", "n") ~= "", "Missing <Plug>(gh-pr-review-refresh)")',
  '+lua local ok, health = pcall(require, "gh-pr.health"); assert(ok and type(health.check) == "function", "Missing gh-pr health check entrypoint")'
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
