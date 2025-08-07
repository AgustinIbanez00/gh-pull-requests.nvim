# gh-pull-requests.nvim

A Neovim plugin for reviewing GitHub pull requests without leaving the editor.

The plugin requires the GitHub CLI and must be run from inside a git repository.

The plugin lists your open pull requests in a Telescope picker. After selecting
a pull request you can choose any changed file and view the base and PR versions
side-by-side in diff mode. Buffers keep the original filetype so syntax
highlighting and other plugins work as expected. Use `:GhPrToggleReviewed`
while inspecting a file to toggle a `[reviewed]` indicator in the statusline.

