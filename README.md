# gh-pull-requests.nvim

A Neovim plugin for reviewing GitHub pull requests without leaving the editor.

The plugin requires the GitHub CLI and must be run from inside a git repository.

The plugin lists your open pull requests in a Telescope picker. After selecting
a pull request you can browse the changed files in a directory tree and view the base and PR versions
side-by-side in diff mode. Buffers keep the original filetype so syntax
highlighting and other plugins work as expected. Use `:GhPrToggleReviewed`
while inspecting a file to toggle a `[reviewed]` indicator in the statusline.
Alternatively, `<leader>ghr` opens a side tree showing pull requests assigned to
you and all open pull requests, which can be expanded to reveal individual
files.

## Usage

The plugin defines default keymaps that all begin with `<leader>gh`:

| Mapping       | Description                |
| ------------- | -------------------------- |
| `<leader>ghl` | List pull requests         |
| `<leader>ghr` | Review tree for pull requests |
| `<leader>ght` | Toggle reviewed indicator  |
| `<leader>ghn` | Jump to next diff change   |
| `<leader>ghp` | Jump to previous change    |

## Installation

The plugin works with all major Neovim plugin managers.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "agustinibanez/gh-pull-requests.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = true,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "agustinibanez/gh-pull-requests.nvim",
  requires = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
  },
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'agustinibanez/gh-pull-requests.nvim'
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
```

## Configuration

Call `require("gh-pr").setup()` to customise the behaviour of the plugin. The
main entrypoint is the `queries` option, which controls the sections displayed
in both the Telescope picker and the review tree. Each query entry is a table
with a `label` and a `query` string. The query string is passed to
`gh search prs` and supports the placeholders `${owner}`, `${repository}`, and
`${user}`, which expand to the current repository owner, repository name, and
authenticated GitHub user respectively. Additional keys such as `limit`,
`sort`, `order`, or `args` are forwarded to the GitHub CLI command for advanced
filtering. Setting `query = "default"` instructs the plugin to use
`gh pr list` for the current repository instead of the search endpoint.

The default configuration matches the following Lua snippet:

```lua
require("gh-pr").setup({
  queries = {
    {
      label = "Waiting For My Review",
      query = "repo:${owner}/${repository} is:open review-requested:${user}",
    },
    {
      label = "Created By Me",
      query = "repo:${owner}/${repository} is:open author:${user}",
    },
    {
      label = "All Open",
      query = "repo:${owner}/${repository} is:open",
    },
  },
})
```

## Contributing

Contributions are welcome and greatly appreciated. To contribute:

1. Fork the repository and create a branch for your feature or fix.
2. Ensure your code follows existing style and passes `luacheck`.
3. Update documentation and add tests when appropriate.
4. Open a pull request with a clear description of your changes.

For substantial changes, please open an issue to discuss them before you start.
Your feedback and suggestions help improve the project for everyone.


