# gh-pull-requests.nvim

A Neovim plugin for reviewing GitHub pull requests without leaving the editor.

The plugin requires the GitHub CLI and must be run from inside a git repository.

The plugin lists your open pull requests in a Telescope picker. After selecting
a pull request you can choose any changed file and view the base and PR versions
side-by-side in diff mode. Buffers keep the original filetype so syntax
highlighting and other plugins work as expected. Use `:GhPrToggleReviewed`
while inspecting a file to toggle a `[reviewed]` indicator in the statusline.

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

## Contributing

Contributions are welcome and greatly appreciated. To contribute:

1. Fork the repository and create a branch for your feature or fix.
2. Ensure your code follows existing style and passes `luacheck`.
3. Update documentation and add tests when appropriate.
4. Open a pull request with a clear description of your changes.

For substantial changes, please open an issue to discuss them before you start.
Your feedback and suggestions help improve the project for everyone.


