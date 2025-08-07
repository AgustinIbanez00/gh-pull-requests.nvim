if vim.g.loaded_gh_pr then
  return
end
vim.g.loaded_gh_pr = true

require('gh-pr').setup()
