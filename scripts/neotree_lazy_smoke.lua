local function fail(message)
  error(message, 0)
end

local function assert_true(value, message)
  if value ~= true then
    fail(message or "expected true")
  end
end

local function assert_false(value, message)
  if value ~= false then
    fail(message or "expected false")
  end
end

local function assert_equals(actual, expected, message)
  if actual ~= expected then
    fail(string.format("%s (expected=%s actual=%s)", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function contains_source(items, source_name)
  for _, item in ipairs(type(items) == "table" and items or {}) do
    if item == source_name then
      return true
    end
    if type(item) == "table" and item.source == source_name then
      return true
    end
  end
  return false
end

local function reset_ghpr_modules()
  for name, _ in pairs(package.loaded) do
    if name:match("^gh%-pr")
      or name == "gh_pr"
      or name == "gh_pr_review"
      or name == "gh_pr_comments"
      or name == "neo-tree"
      or name:match("^neo%-tree%.")
      or name == "render-markdown" then
      package.loaded[name] = nil
    end
  end
end

local function install_neotree_stubs(state)
  package.preload["render-markdown"] = function()
    return {}
  end

  package.preload["neo-tree"] = function()
    local neo_tree = {
      config = {
        sources = { "filesystem", "buffers", "git_status" },
        source_selector = {
          sources = {
            { source = "filesystem" },
            { source = "buffers" },
            { source = "git_status" },
          },
        },
        gh_pr = { window = { position = "left" } },
        gh_pr_review = { window = { position = "left" } },
        gh_pr_comments = { window = { position = "left" } },
      },
    }

    function neo_tree.ensure_config()
      state.ensure_config_calls = (state.ensure_config_calls or 0) + 1
      for _, source_name in ipairs(neo_tree.config.sources or {}) do
        if type(source_name) == "string" and source_name:match("^gh_pr") then
          local module = require(source_name)
          local source_config = neo_tree.config[source_name] or {}
          source_config.components = module.components or require(source_name .. ".components")
          source_config.commands = module.commands or require(source_name .. ".commands")
          neo_tree.config[source_name] = source_config
        end
      end
    end

    state.neo_tree = neo_tree
    return neo_tree
  end

  package.preload["neo-tree.sources.manager"] = function()
    local manager = {}

    function manager.setup(name, source_config, global_config, module)
      table.insert(state.manager_setups, {
        name = name,
        source_config = vim.deepcopy(source_config),
      })
      state.modules_by_source[name] = module
      return true
    end

    function manager.get_state_for_window(winid)
      return state.window_states[winid]
    end

    function manager.refresh(source_name)
      table.insert(state.manager_refreshes, source_name)
    end

    return manager
  end

  package.preload["neo-tree.command"] = function()
    return {
      execute = function(args)
        table.insert(state.command_calls, vim.deepcopy(args))
        if args.action == "close" then
          state.active_source = nil
          local current_buf = vim.api.nvim_get_current_buf()
          if vim.api.nvim_buf_is_valid(current_buf) then
            vim.api.nvim_set_option_value("filetype", "", { buf = current_buf })
            vim.b[current_buf].neo_tree_source = nil
          end
          state.window_states[vim.api.nvim_get_current_win()] = nil
          return
        end

        state.active_source = args.source
        local winid = vim.api.nvim_get_current_win()
        local bufnr = vim.api.nvim_get_current_buf()
        vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = bufnr })
        vim.b[bufnr].neo_tree_source = args.source
        state.window_states[winid] = {
          name = args.source,
          winid = winid,
          path = vim.fn.getcwd(),
        }
      end,
    }
  end

  package.preload["neo-tree.ui.renderer"] = function()
    return {
      redraw = function(_)
        state.redraws = state.redraws + 1
      end,
      close = function(_)
        return false
      end,
      window_exists = function(_)
        return false
      end,
    }
  end

  package.preload["neo-tree.sources.common.commands"] = function()
    return {
      _add_common_commands = function(_) end,
      toggle_node = function(_) end,
      expand_all_nodes = function(...) end,
      close_all_nodes = function(...) end,
    }
  end

  package.preload["neo-tree.ui.highlights"] = function()
    return {}
  end

  package.preload["neo-tree.sources.common.components"] = function()
    return {}
  end
end

local function install_source_runtime_stubs(state)
  package.preload["gh-pr.cache_store"] = function()
    return {
      prune = function(...) end,
      get_repo = function(...)
        return nil
      end,
      set_repo = function(...) end,
    }
  end

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          cache = {
            gh_pr = {
              enabled = true,
              ttl_seconds = 60,
              max_cache_age_seconds = 900,
              show_stale_badge = true,
              sync_visible_buffers = true,
            },
          },
          hide_viewed_files = false,
        }
      end,
      get_path_render = function()
        return {
          mode = "tree",
          separator = "/",
          show_status_prefix = true,
        }
      end,
    }
  end

  package.preload["gh-pr.neotree.follow"] = function()
    return {
      visible_source_states = function()
        return {}
      end,
      find_file_node = function()
        return nil
      end,
      focus_node_without_steal = function()
        return false
      end,
    }
  end

  package.preload["gh-pr.highlights"] = function()
    return {
      ensure_baseline_links = function() end,
      setup = function() end,
    }
  end

  package.preload["gh-pr.path_tree"] = function()
    return {
      build_nodes = function(entries, opts)
        local nodes = {}
        for _, entry in ipairs(entries or {}) do
          nodes[#nodes + 1] = opts.create_file_node(entry)
        end
        return nodes
      end,
    }
  end

  package.preload["gh-pr.pr_service"] = function()
    return {
      resolve_repository = function()
        return { full_name = "owner/repo" }, nil
      end,
      list_queries_with_results_async = function(callback, _)
        callback({}, nil)
      end,
      fetch_details_async = function(_, callback)
        callback(nil, "unused")
      end,
    }
  end

  package.preload["gh-pr.repo"] = function()
    return {
      ensure_git_repo = function()
        return true
      end,
      in_git_repo = function()
        return true
      end,
      git_root = function()
        return vim.fn.getcwd(), nil
      end,
    }
  end

  package.preload["gh-pr.state"] = function()
    return {
      get_active_pr = function()
        return nil, nil
      end,
      is_viewed = function()
        return false
      end,
    }
  end

  package.preload["gh-pr.virtual_files"] = function()
    return {
      sync_visible_pr_buffers = function(...)
        state.synced_buffers = state.synced_buffers + 1
      end,
    }
  end

  package.preload["neo-tree.ui.renderer"] = function()
    return {
      show_nodes = function(nodes, _)
        state.show_nodes_calls = state.show_nodes_calls + 1
        state.last_nodes = vim.deepcopy(nodes)
      end,
    }
  end

  package.preload["neo-tree.sources.manager"] = function()
    return {
      get_state_for_window = function(winid)
        return state.window_states and state.window_states[winid] or nil
      end,
    }
  end
end

local function case_eager_entry_module()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  }
  install_neotree_stubs(state)

  package.loaded["gh-pr.actions"] = nil
  package.loaded["gh-pr.pr_service"] = nil
  package.loaded["gh-pr.virtual_files"] = nil

  require("gh_pr")
  require("gh_pr_review")
  require("gh_pr_comments")

  assert_equals(package.loaded["gh-pr.actions"], nil, "gh_pr loaded actions eagerly")
  assert_equals(package.loaded["gh-pr.pr_service"], nil, "gh_pr loaded pr_service eagerly")
  assert_equals(package.loaded["gh-pr.virtual_files"], nil, "gh_pr loaded virtual_files eagerly")
end

local function case_external_source_contract()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
    ensure_config_calls = 0,
  }
  install_neotree_stubs(state)

  local neo_tree = require("neo-tree")
  neo_tree.config.sources = { "filesystem", "gh_pr", "gh_pr_review", "gh_pr_comments" }
  neo_tree.ensure_config()

  assert_equals(state.ensure_config_calls, 1, "neo-tree ensure_config should be exercised once")
  assert_true(type(neo_tree.config.gh_pr.components) == "table", "gh_pr wrapper must expose components")
  assert_true(type(neo_tree.config.gh_pr.commands) == "table", "gh_pr wrapper must expose commands")
  assert_true(type(neo_tree.config.gh_pr_review.components) == "table", "gh_pr_review wrapper must expose components")
  assert_true(type(neo_tree.config.gh_pr_review.commands) == "table", "gh_pr_review wrapper must expose commands")
  assert_true(type(neo_tree.config.gh_pr_comments.components) == "table", "gh_pr_comments wrapper must expose components")
  assert_true(type(neo_tree.config.gh_pr_comments.commands) == "table", "gh_pr_comments wrapper must expose commands")
  assert_equals(package.loaded["gh-pr.actions"], nil, "top-level neo-tree wrapper contract should stay lazy for actions")
  assert_equals(package.loaded["gh-pr.pr_service"], nil, "top-level neo-tree wrapper contract should stay lazy for pr_service")
  assert_equals(package.loaded["gh-pr.virtual_files"], nil, "top-level neo-tree wrapper contract should stay lazy for virtual_files")
end

local function case_open_pending_and_idempotent()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  }
  install_neotree_stubs(state)

  local gh = require("gh-pr")
  gh.setup({
    ui = {
      use_neotree = true,
      telescope_fallback = false,
      neotree_sources = {
        pr = {
          auto_register = true,
          gate = "github_repo",
          workspace = "cwd",
        },
      },
    },
  })

  local repo_mod = require("gh-pr.repo")
  local probe_calls = {}
  repo_mod.probe_workspace_async = function(opts, callback)
    table.insert(probe_calls, {
      opts = vim.deepcopy(opts),
      callback = callback,
    })
  end

  gh.open_pull_requests()
  gh.open_pull_requests()

  assert_equals(#probe_calls, 1, "GhPrOpen should dedupe inflight workspace probe")
  assert_equals(#state.command_calls, 0, "GhPrOpen should not execute source before workspace probe resolves")

  probe_calls[1].callback({
    eligible = true,
    status = "eligible",
    git_root = vim.fn.getcwd(),
    repository = { full_name = "owner/repo" },
  })

  assert_equals(#state.manager_setups, 1, "gh_pr source should register once after probe resolves")
  assert_equals(#state.command_calls, 1, "GhPrOpen should execute once when pending probe resolves")
  assert_equals(state.command_calls[1].action, "show", "First GhPrOpen should show source while it is hidden")
  assert_false(state.command_calls[1].toggle, "GhPrOpen must not use toggle=true")

  gh.open_pull_requests()
  assert_equals(#state.command_calls, 2, "GhPrOpen should focus again after cache hit")
  assert_false(state.command_calls[2].toggle, "Repeated GhPrOpen must remain idempotent")
end

local function case_github_gate_hides_source()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  }
  install_neotree_stubs(state)

  local gh = require("gh-pr")
  gh.setup({
    ui = {
      use_neotree = true,
      telescope_fallback = false,
      neotree_sources = {
        pr = {
          auto_register = true,
          gate = "github_repo",
          workspace = "cwd",
        },
      },
    },
  })

  local repo_mod = require("gh-pr.repo")
  repo_mod.probe_workspace_async = function(_, callback)
    callback({
      eligible = false,
      status = "no_github_remote",
    })
  end

  require("neo-tree")
  require("gh-pr.integrations.neotree").handle_neotree_filetype({})
  assert_false(contains_source(state.neo_tree.config.sources, "gh_pr"), "gh_pr should stay hidden when gate=github_repo and probe fails")
  assert_false(
    contains_source(state.neo_tree.config.source_selector.sources, "gh_pr"),
    "source selector should not show gh_pr when GitHub repo probe fails"
  )
end

local function case_manual_gate_skips_auto_registration()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  }
  install_neotree_stubs(state)

  local gh = require("gh-pr")
  gh.setup({
    ui = {
      use_neotree = true,
      telescope_fallback = false,
      neotree_sources = {
        pr = {
          auto_register = true,
          gate = "manual",
          workspace = "cwd",
        },
      },
    },
  })

  local repo_mod = require("gh-pr.repo")
  local probe_count = 0
  repo_mod.probe_workspace_async = function(_, _)
    probe_count = probe_count + 1
  end

  require("neo-tree")
  require("gh-pr.integrations.neotree").handle_neotree_filetype({})
  assert_equals(probe_count, 0, "gate=manual must skip auto-registration probe")
  assert_false(contains_source(state.neo_tree.config.sources, "gh_pr"), "gate=manual must not auto-add gh_pr")
end

local function case_review_tree_keeps_toggle()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  }
  install_neotree_stubs(state)

  local gh = require("gh-pr")
  gh.setup({
    ui = {
      use_neotree = true,
      telescope_fallback = false,
    },
  })

  local repo_mod = require("gh-pr.repo")
  repo_mod.ensure_git_repo = function()
    return true
  end

  gh.open_review_tree()

  assert_equals(#state.command_calls, 1, "GhPrReviewTree should execute neo-tree command")
  assert_equals(state.command_calls[1].source, "gh_pr_review", "GhPrReviewTree should target gh_pr_review")
  assert_true(state.command_calls[1].toggle, "GhPrReviewTree must keep toggle=true")
end

local function case_refresh_outside_focus_avoids_render()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
  }
  install_source_runtime_stubs(state)

  local source = require("gh-pr.neotree.source")
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = source_buf })
  vim.b[source_buf].neo_tree_source = "gh_pr"

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source_buf)
  vim.api.nvim_set_current_win(current_win)

  local tree_state = {
    winid = source_win,
    path = vim.fn.getcwd(),
  }
  state.window_states[source_win] = tree_state

  source.navigate(tree_state, vim.fn.getcwd())

  assert_equals(state.show_nodes_calls, 1, "initial navigate should render once")

  source.render_cached_states()
  assert_equals(state.show_nodes_calls, 2, "cached render should be available after background refresh without extra out-of-focus paint")

  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_win_close(source_win, true)
  end
end

local function case_initial_navigate_renders_without_live_state()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
  }
  install_source_runtime_stubs(state)

  local source = require("gh-pr.neotree.source")
  local tree_state = {
    path = vim.fn.getcwd(),
  }

  source.navigate(tree_state, vim.fn.getcwd())

  assert_equals(state.show_nodes_calls, 1, "initial navigate should render even before neo-tree buffer is attached")
end

case_eager_entry_module()
case_external_source_contract()
case_open_pending_and_idempotent()
case_github_gate_hides_source()
case_manual_gate_skips_auto_registration()
case_review_tree_keeps_toggle()
case_refresh_outside_focus_avoids_render()
case_initial_navigate_renders_without_live_state()
