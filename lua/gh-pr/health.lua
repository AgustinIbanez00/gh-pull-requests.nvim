local M = {}

local function health_api()
  if vim.health and type(vim.health.start) == "function" then
    return vim.health
  end

  return {
    start = function(message)
      vim.fn["health#report_start"](message)
    end,
    ok = function(message)
      vim.fn["health#report_ok"](message)
    end,
    warn = function(message, advice)
      if advice == nil then
        vim.fn["health#report_warn"](message)
        return
      end
      local advice_list = type(advice) == "table" and advice or { advice }
      vim.fn["health#report_warn"](message, advice_list)
    end,
    error = function(message, advice)
      if advice == nil then
        vim.fn["health#report_error"](message)
        return
      end
      local advice_list = type(advice) == "table" and advice or { advice }
      vim.fn["health#report_error"](message, advice_list)
    end,
    info = function(message)
      vim.fn["health#report_info"](message)
    end,
  }
end

local function trim(value)
  return tostring(value or ""):gsub("%s+$", "")
end

local function first_line(value)
  local text = trim(value)
  if text == "" then
    return ""
  end
  for line in text:gmatch("[^\r\n]+") do
    local normalized = trim(line)
    if normalized ~= "" then
      return normalized
    end
  end
  return ""
end

local function run_system(command)
  local output = vim.fn.system(command)
  local exit_code = vim.v.shell_error
  return exit_code, trim(output)
end

local function format_version()
  local version = vim.version()
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

local function check_nvim_version(health)
  if vim.fn.has("nvim-0.9") == 1 then
    health.ok("Neovim version is supported: " .. format_version())
  else
    health.error("Neovim 0.9+ is required", {
      "Upgrade Neovim before using gh-pr.",
    })
  end

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim 0.10+ features are available (`vim.system`, `vim.ui.open`)")
  else
    health.warn("Running on Neovim < 0.10", {
      "gh-pr still runs, but 0.10+ is recommended for best compatibility.",
    })
  end
end

local function check_gh_cli(health)
  if vim.fn.executable("gh") ~= 1 then
    health.error("GitHub CLI (`gh`) is not executable", {
      "Install GitHub CLI from https://cli.github.com/.",
      "Authenticate with `gh auth login`.",
    })
    return {
      available = false,
      authenticated = false,
    }
  end

  local gh_path = vim.fn.exepath("gh")
  if gh_path ~= "" then
    health.ok("`gh` executable found: " .. gh_path)
  else
    health.ok("`gh` executable found")
  end

  local version_code, version_output = run_system("gh --version 2>&1")
  if version_code == 0 then
    local headline = first_line(version_output)
    if headline ~= "" then
      health.info(headline)
    end
  else
    health.warn("Unable to read `gh --version` output", {
      "Ensure GitHub CLI can run from your shell.",
      first_line(version_output),
    })
  end

  local auth_code, auth_output = run_system("gh auth status --hostname github.com 2>&1")
  if auth_code == 0 then
    health.ok("`gh auth status` succeeded for github.com")
    return {
      available = true,
      authenticated = true,
    }
  end

  health.warn("`gh` is installed but not authenticated for github.com", {
    "Run `gh auth login` and re-run `:checkhealth gh-pr`.",
    first_line(auth_output),
  })

  return {
    available = true,
    authenticated = false,
  }
end

local function check_lua_dependency(health, module_name, required, description)
  local ok = pcall(require, module_name)
  if ok then
    health.ok(description .. " is available (`" .. module_name .. "`)")
    return true
  end

  if required then
    health.error(description .. " is missing (`" .. module_name .. "`)", {
      "Install the dependency and ensure it is in 'runtimepath'.",
    })
  else
    health.warn(description .. " is not available (`" .. module_name .. "`)", {
      "Install it if you want this optional integration.",
    })
  end

  return false
end

local function check_config(health, deps)
  local ok_config, config_or_err = pcall(require, "gh-pr.config")
  if not ok_config then
    health.error("Failed to load `gh-pr.config`", {
      tostring(config_or_err),
    })
    return
  end

  local ok_get, options = pcall(config_or_err.get)
  if not ok_get or type(options) ~= "table" then
    health.error("Unable to read resolved gh-pr configuration", {
      "Run `require('gh-pr').setup({...})` and check your configuration for invalid values.",
      tostring(options),
    })
    return
  end

  local ui = type(options.ui) == "table" and options.ui or {}
  local use_neotree = ui.use_neotree ~= false
  local use_telescope = ui.telescope_fallback ~= false

  if not use_neotree and not use_telescope then
    health.warn("Both UI backends are disabled", {
      "Enable `ui.use_neotree` and/or `ui.telescope_fallback` so `:GhPrOpen` has a backend.",
    })
  else
    health.ok("At least one UI backend is enabled in configuration")
  end

  if use_neotree and not deps.neotree then
    health.warn("`ui.use_neotree = true` but neo-tree is unavailable", {
      "Install `nvim-neo-tree/neo-tree.nvim` or set `ui.use_neotree = false`.",
    })
  end

  if use_telescope and not deps.telescope then
    health.warn("`ui.telescope_fallback = true` but Telescope is unavailable", {
      "Install `nvim-telescope/telescope.nvim` or set `ui.telescope_fallback = false`.",
    })
  end

  local markdown = type(options.overview) == "table" and options.overview.markdown or nil
  local markdown_provider = type(markdown) == "table" and markdown.provider or nil
  if markdown_provider == "render-markdown" and not deps.render_markdown then
    health.error("`overview.markdown.provider` requires render-markdown.nvim", {
      "Install `MeanderingProgrammer/render-markdown.nvim`.",
      "Or set `overview.markdown.provider = 'builtin'`.",
    })
  end

  local remotes = type(options.remotes) == "table" and options.remotes or {}
  if #remotes == 0 then
    health.warn("No git remotes configured", {
      "Set `remotes = { 'origin', 'upstream' }` (or your preferred order).",
    })
  else
    local listed = {}
    for _, remote in ipairs(remotes) do
      if type(remote) == "string" and remote ~= "" then
        listed[#listed + 1] = remote
      end
    end
    if #listed > 0 then
      health.info("Configured remotes: " .. table.concat(listed, ", "))
    end
  end
end

function M.check()
  local health = health_api()

  health.start("gh-pr: Neovim compatibility")
  check_nvim_version(health)

  health.start("gh-pr: dependencies")
  local gh = check_gh_cli(health)
  local render_markdown = check_lua_dependency(health, "render-markdown", true, "render-markdown.nvim")
  local neotree = check_lua_dependency(health, "neo-tree", false, "neo-tree.nvim")
  local telescope = check_lua_dependency(health, "telescope", false, "telescope.nvim")

  if gh.available and gh.authenticated then
    health.info("`gh` API calls should be available to gh-pr")
  end

  health.start("gh-pr: configuration")
  check_config(health, {
    render_markdown = render_markdown,
    neotree = neotree,
    telescope = telescope,
  })
end

return M
