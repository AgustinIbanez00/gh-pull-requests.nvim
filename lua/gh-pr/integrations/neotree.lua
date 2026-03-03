local M = {}

local configured_sources = {}

local function notify_error(opts, message)
  local on_error = type(opts) == "table" and opts.on_error or nil
  if type(on_error) == "function" then
    on_error(message)
  end
end

function M.ensure_source(source_name, source_module_name, opts)
  local nt_ok, neo_tree = pcall(require, "neo-tree")
  if not nt_ok then
    return false
  end

  neo_tree.ensure_config()

  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if type(neo_tree.config[source_name]) ~= "table" then
    neo_tree.config[source_name] = {}
  end

  neo_tree.config[source_name].name = source_name
  neo_tree.config[source_name].window = neo_tree.config[source_name].window or {}
  neo_tree.config[source_name].window.position = neo_tree.config[source_name].window.position or "left"
  neo_tree.config.sources = type(neo_tree.config.sources) == "table" and neo_tree.config.sources or {}

  local found_source = false
  for _, source in ipairs(neo_tree.config.sources) do
    if source == source_name then
      found_source = true
      break
    end
  end

  if not found_source then
    table.insert(neo_tree.config.sources, source_name)
  end

  if type(neo_tree.config.source_selector) == "table" and type(neo_tree.config.source_selector.sources) == "table" then
    local selector_sources = neo_tree.config.source_selector.sources
    local has_selector_source = false
    for _, item in ipairs(selector_sources) do
      if item == source_name then
        has_selector_source = true
        break
      end
      if type(item) == "table" and item.source == source_name then
        has_selector_source = true
        break
      end
    end
    if not has_selector_source then
      local display_map = {
        gh_pr = "  PR ",
        gh_pr_comments = "  Comments ",
        gh_pr_review = "  PR Review ",
      }
      local display_name = display_map[source_name] or ("  " .. tostring(source_name) .. " ")
      table.insert(selector_sources, { source = source_name, display_name = display_name })
    end
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok then
    return false
  end

  local source_ok, source_module = pcall(require, source_module_name)
  if not source_ok then
    notify_error(opts, "Unable to load " .. source_name .. " Neo-tree source")
    return false
  end

  if configured_sources[source_name] then
    return true
  end

  local setup_ok, setup_err = pcall(manager.setup, source_name, neo_tree.config[source_name], neo_tree.config, source_module)
  if not setup_ok then
    notify_error(opts, "Failed to setup " .. source_name .. " Neo-tree source: " .. tostring(setup_err))
    return false
  end

  configured_sources[source_name] = true
  return true
end

function M.open_source(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if not M.ensure_source(source_name, source_module_name, opts) then
    return false
  end

  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    return false
  end

  local status, err = pcall(command.execute, {
    source = source_name,
    toggle = opts.toggle ~= false,
    reveal = false,
    position = "left",
  })

  if not status then
    notify_error(opts, "Neo-tree source failed: " .. tostring(err))
    return false
  end

  return true
end

function M.refresh_sources()
  local source_ok, source = pcall(require, "gh-pr.neotree.source")
  if source_ok and type(source.request_refresh) == "function" then
    pcall(source.request_refresh, nil, { force = true, notify_error = false })
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok then
    pcall(manager.refresh, "gh_pr_review")
  end

  local review_ok, review_source = pcall(require, "gh-pr.neotree.review_source")
  if review_ok and type(review_source.request_refresh) == "function" then
    pcall(review_source.request_refresh, nil, { force = true, notify_error = false })
  end
end

return M
