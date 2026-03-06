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
  '+lua require("gh-pr").setup({ ui = { use_neotree = false, telescope_fallback = false }, diff_view = { prefetch = { enabled = true, concurrency = 2, text_extensions = { "lua", ".md" } } } })',
  '+lua local cfg = require("gh-pr.config").get(); local prefetch = cfg.diff_view.prefetch or {}; assert(vim.fn.exists(":GhPrOpen") == 2, "Missing :GhPrOpen command"); assert(vim.fn.exists(":GhPrReviewRefresh") == 2, "Missing :GhPrReviewRefresh command"); assert(vim.fn.exists(":GhPRReviewRefresh") == 2, "Missing :GhPRReviewRefresh alias"); assert(vim.fn.maparg("<Plug>(gh-pr-open)", "n") ~= "", "Missing <Plug>(gh-pr-open)"); assert(vim.fn.maparg("<Plug>(gh-pr-review-refresh)", "n") ~= "", "Missing <Plug>(gh-pr-review-refresh)"); assert(prefetch.enabled == true, "Missing diff_view.prefetch.enabled"); assert(prefetch.concurrency == 2, "Missing diff_view.prefetch.concurrency"); assert(prefetch.text_extensions[1] == "lua" and prefetch.text_extensions[2] == "md", "Missing diff_view.prefetch.text_extensions"); local ok, health = pcall(require, "gh-pr.health"); assert(ok and type(health.check) == "function", "Missing gh-pr health check entrypoint")'
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
