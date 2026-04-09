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

local function find_first_file_node(nodes)
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    if type(node) == "table" then
      local extra = type(node.extra) == "table" and node.extra or nil
      if type(extra) == "table" and extra.kind == "file" then
        return node
      end

      local child = find_first_file_node(node.children)
      if child then
        return child
      end
    end
  end

  return nil
end

local function find_first_node_by_kind(nodes, kind)
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    if type(node) == "table" then
      local extra = type(node.extra) == "table" and node.extra or nil
      if type(extra) == "table" and extra.kind == kind then
        return node
      end

      local child = find_first_node_by_kind(node.children, kind)
      if child then
        return child
      end
    end
  end

  return nil
end

local function find_first_node_matching(nodes, predicate)
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    if type(node) == "table" then
      if predicate(node) then
        return node
      end

      local child = find_first_node_matching(node.children, predicate)
      if child then
        return child
      end
    end
  end

  return nil
end

local function review_file_badge_parts(node)
  local components = require("gh-pr.neotree.components")
  return components.file_review_badges({}, node, {})
end

local function review_file_badge_text(node)
  local rendered = review_file_badge_parts(node)
  local parts = {}
  for _, item in ipairs(type(rendered) == "table" and rendered or {}) do
    parts[#parts + 1] = type(item) == "table" and (item.text or "") or ""
  end
  return table.concat(parts, "")
end

local function pr_meta_badge_parts(node)
  local components = require("gh-pr.neotree.components")
  return components.pr_meta_badges({}, node, {})
end

local function pr_meta_badge_text(node)
  local rendered = pr_meta_badge_parts(node)
  if type(rendered) == "table" and type(rendered.text) == "string" then
    return rendered.text
  end

  local parts = {}
  for _, item in ipairs(type(rendered) == "table" and rendered or {}) do
    parts[#parts + 1] = type(item) == "table" and (item.text or "") or ""
  end
  return table.concat(parts, "")
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
      or name == "gh_my_pr"
      or name == "gh_pr_comments"
      or name == "gh_pr_diff_comments"
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
        gh_my_pr = { window = { position = "left" } },
        gh_pr_comments = { window = { position = "left" } },
        gh_pr_diff_comments = { window = { position = "bottom" } },
      },
    }

    function neo_tree.ensure_config()
      state.ensure_config_calls = (state.ensure_config_calls or 0) + 1
      for _, source_name in ipairs(neo_tree.config.sources or {}) do
        if source_name == "gh_my_pr" or (type(source_name) == "string" and source_name:match("^gh_pr")) then
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

    function manager.dispose_invalid_tabs()
      state.dispose_invalid_tabs_calls = (state.dispose_invalid_tabs_calls or 0) + 1
    end

    function manager._for_each_state(source_name, action)
      state.for_each_state_calls = (state.for_each_state_calls or 0) + 1
      manager.dispose_invalid_tabs()
      if type(action) == "function" then
        action({
          name = source_name,
          tabid = vim.api.nvim_get_current_tabpage(),
        })
      end
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

local function install_review_source_runtime_stubs(state)
  package.preload["gh-pr.cache_store"] = function()
    return {
      prune = function(...) end,
      get_repo = function(...)
        return nil
      end,
      set_repo = function(...) end,
      delete_repo = function(...) end,
    }
  end

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          cache = {
            gh_pr_review = {
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

  package.preload["gh-pr.neotree.comments_source"] = function()
    return {
      invalidate_cache = function()
        state.invalidated_comments = (state.invalidated_comments or 0) + 1
      end,
    }
  end

  package.preload["gh-pr.neotree.follow"] = function()
    local function visible_source_states(source_name)
      local states = {}
      for winid, window_state in pairs(state.window_states or {}) do
        if vim.api.nvim_win_is_valid(winid) then
          local bufnr = vim.api.nvim_win_get_buf(winid)
          if vim.bo[bufnr].filetype == "neo-tree" and vim.b[bufnr].neo_tree_source == source_name then
            states[#states + 1] = window_state
          end
        end
      end
      return states
    end

    return {
      normalize_path = function(path)
        if type(path) ~= "string" then
          return ""
        end
        return path:gsub("\\", "/")
      end,
      visible_source_states = visible_source_states,
      resolve_buffer_context = function()
        return nil
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

  package.preload["gh-pr.neotree.review_sections.overview"] = function()
    return {
      build_root_nodes = function(_, _, sections)
        local nodes = {}
        if type(sections) == "table" then
          local files = type(sections.files) == "table" and sections.files.children or {}
          local checks = type(sections.checks) == "table" and sections.checks.children or {}
          local security = type(sections.security) == "table" and sections.security.children or {}
          for _, node in ipairs(type(files) == "table" and files or {}) do
            nodes[#nodes + 1] = node
          end
          for _, node in ipairs(type(checks) == "table" and checks or {}) do
            nodes[#nodes + 1] = node
          end
          for _, node in ipairs(type(security) == "table" and security or {}) do
            nodes[#nodes + 1] = node
          end
        end
        return nodes
      end,
      files_title = function()
        return "Files"
      end,
      reviewers_title = function()
        return "Reviewers"
      end,
      commits_title = function()
        return "Commits"
      end,
      checks_title = function()
        return "Checks"
      end,
      security_title = function()
        return "Security"
      end,
      count_commit_entries = function()
        return 0
      end,
    }
  end

  package.preload["gh-pr.neotree.review_sections.reviewers"] = function()
    return {
      build_nodes = function()
        return {}
      end,
      count_states = function()
        return {}, 0
      end,
    }
  end

  package.preload["gh-pr.neotree.review_sections.checks"] = function()
    return {
      build_nodes = function(pr, details, opts)
        local nodes = {}
        local session = type(opts) == "table" and opts.session or nil
        local cache = type(session) == "table" and type(session.check_annotations_by_key) == "table" and session.check_annotations_by_key or {}

        for index, check in ipairs(type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}) do
          local key = string.format("%s:%d", check.name or "check", index)
          local entry = type(cache[key]) == "table" and cache[key] or nil
          local children = {}

          if entry and entry.loading == true then
            children[#children + 1] = {
              id = string.format("check:%d:loading", index),
              name = "Loading annotations...",
              type = "message",
              extra = { kind = "message" },
            }
          elseif entry and type(entry.error) == "string" and entry.error ~= "" then
            children[#children + 1] = {
              id = string.format("check:%d:error", index),
              name = "Unable to load annotations: " .. entry.error,
              type = "message",
              extra = { kind = "message" },
            }
          elseif entry and entry.loaded == true then
            local grouped = {}
            for annotation_index, annotation in ipairs(type(entry.annotations) == "table" and entry.annotations or {}) do
              local path = type(annotation.path) == "string" and annotation.path or "(unknown path)"
              grouped[path] = grouped[path] or {}
              grouped[path][#grouped[path] + 1] = {
                id = string.format("check:%d:file:%s:annotation:%d", index, path, annotation_index),
                name = string.format("[%s] L%d %s", (annotation.annotation_level or "notice"):upper(), annotation.start_line or 0, annotation.title or "Annotation"),
                type = "file",
                extra = {
                  kind = "check_annotation",
                  pr = pr,
                  details = details,
                  check = check,
                  check_key = key,
                  check_url = check.detailsUrl or "",
                  annotation = annotation,
                  target_path = annotation.path,
                  target_line = annotation.start_line,
                  annotation_level = annotation.annotation_level,
                  annotations = entry.annotations,
                },
              }
            end

            for path, items in pairs(grouped) do
              children[#children + 1] = {
                id = string.format("check:%d:file:%s", index, path),
                name = string.format("%s (%d)", path, #items),
                type = "directory",
                extra = {
                  kind = "check_annotation_file",
                  file_path = path,
                },
                children = items,
              }
            end
          end

          if type(check.detailsUrl) == "string" and check.detailsUrl ~= "" then
            children[#children + 1] = {
              id = string.format("check:%d:details", index),
              name = "Open check details",
              type = "file",
              extra = {
                kind = "check_details_link",
                check_url = check.detailsUrl,
                pr = pr,
                details = details,
              },
            }
          end

          nodes[#nodes + 1] = {
            id = string.format("check:%d", index),
            name = string.format("[%s] %s", check.state or "FAIL", check.name or "check"),
            type = "directory",
            extra = {
              kind = "check",
              check = check,
              check_key = key,
              check_state = check.state or "FAIL",
              check_url = check.detailsUrl or "",
              pr = pr,
              details = details,
            },
            children = children,
          }
        end

        return nodes
      end,
      count_states = function(nodes)
        return { FAIL = #(type(nodes) == "table" and nodes or {}) }, #(type(nodes) == "table" and nodes or {})
      end,
      collect_signature = function(details)
        return {
          count = #(type(details) == "table" and type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}),
          ids = {},
          set = {},
          signature = tostring(#(type(details) == "table" and type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {})),
        }
      end,
    }
  end

  package.preload["gh-pr.neotree.review_sections.comments"] = function()
    return {
      build_nodes = function()
        return {}
      end,
      build_section_title = function()
        return "Comments"
      end,
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
        return {
          owner = "owner",
          name = "repo",
          full_name = "owner/repo",
        }, nil
      end,
      fetch_details_async = function(_, callback)
        state.fetch_details_callback = callback
      end,
      fetch_review_threads_async = function(_, _, callback)
        state.fetch_threads_callback = callback
      end,
      fetch_check_annotations_async = function(_, _, _, callback)
        state.fetch_check_annotations_callback = callback
      end,
      fetch_code_scanning_alerts_async = function(_, _, callback)
        state.fetch_code_scanning_callback = callback
      end,
      fetch_dependency_review_async = function(_, _, callback)
        state.fetch_dependency_review_callback = callback
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
      get_active_review = function()
        return {
          number = 42,
        }, nil
      end,
      set_active_pr = function(...)
        state.set_active_pr_calls = (state.set_active_pr_calls or 0) + 1
      end,
      set_active_review = function(...)
        state.set_active_review_calls = (state.set_active_review_calls or 0) + 1
      end,
      is_viewed = function()
        return false
      end,
      get_pr_review_files_flat_pref = function()
        return false
      end,
    }
  end

  package.preload["gh-pr.virtual_files"] = function()
    return {
      sync_visible_pr_buffers = function(...)
        state.synced_buffers = (state.synced_buffers or 0) + 1
      end,
    }
  end

  package.preload["gh-pr.core.review_prefetch"] = function()
    return {
      prefetch_review = function(...)
        state.prefetch_calls = (state.prefetch_calls or 0) + 1
      end,
    }
  end

  package.preload["gh-pr.actions"] = function()
    return {
      sync_remote_viewed_state = function(...)
        state.sync_remote_viewed_calls = (state.sync_remote_viewed_calls or 0) + 1
      end,
    }
  end

  package.preload["neo-tree.ui.renderer"] = function()
    return {
      show_nodes = function(nodes, _)
        state.show_nodes_calls = (state.show_nodes_calls or 0) + 1
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
  require("gh_my_pr")
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
  neo_tree.config.sources = { "filesystem", "gh_pr", "gh_pr_review", "gh_my_pr", "gh_pr_comments" }
  neo_tree.ensure_config()

  assert_equals(state.ensure_config_calls, 1, "neo-tree ensure_config should be exercised once")
  assert_true(type(neo_tree.config.gh_pr.components) == "table", "gh_pr wrapper must expose components")
  assert_true(type(neo_tree.config.gh_pr.commands) == "table", "gh_pr wrapper must expose commands")
  assert_true(type(neo_tree.config.gh_pr_review.components) == "table", "gh_pr_review wrapper must expose components")
  assert_true(type(neo_tree.config.gh_pr_review.commands) == "table", "gh_pr_review wrapper must expose commands")
  assert_true(type(neo_tree.config.gh_my_pr.components) == "table", "gh_my_pr wrapper must expose components")
  assert_true(type(neo_tree.config.gh_my_pr.commands) == "table", "gh_my_pr wrapper must expose commands")
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
        my_pr = {
          auto_register = false,
          gate = "manual",
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
        my_pr = {
          auto_register = false,
          gate = "manual",
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
        my_pr = {
          auto_register = false,
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

local function case_neotree_manager_fast_events_are_scheduled()
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
        my_pr = {
          auto_register = false,
          gate = "manual",
          workspace = "cwd",
        },
      },
    },
  })

  require("neo-tree")
  require("gh-pr.integrations.neotree").handle_neotree_filetype({})

  local manager = require("neo-tree.sources.manager")
  local original_in_fast_event = vim.in_fast_event
  local fast_event = true
  local action_calls = 0

  vim.in_fast_event = function()
    return fast_event
  end

  manager._for_each_state("filesystem", function()
    action_calls = action_calls + 1
  end)

  assert_equals(state.dispose_invalid_tabs_calls or 0, 0,
    "dispose_invalid_tabs should not run inline during fast-event traversal")
  assert_equals(state.for_each_state_calls or 0, 0,
    "_for_each_state should be deferred when called from fast-event")
  assert_equals(action_calls, 0, "fast-event traversal should defer callbacks to the main loop")

  fast_event = false
  local completed = vim.wait(200, function()
    return (state.dispose_invalid_tabs_calls or 0) == 1
      and (state.for_each_state_calls or 0) == 1
      and action_calls == 1
  end, 10)

  vim.in_fast_event = original_in_fast_event

  assert_true(completed, "scheduled Neo-tree manager traversal should complete on the main loop")
  assert_equals(state.dispose_invalid_tabs_calls, 1,
    "dispose_invalid_tabs should run once after leaving fast-event")
  assert_equals(state.for_each_state_calls, 1,
    "_for_each_state should execute once after leaving fast-event")
  assert_equals(action_calls, 1, "deferred traversal should execute its callback once")
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

local function case_my_pr_auto_registers_on_branch_match()
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
        my_pr = {
          auto_register = true,
          gate = "github_repo",
          workspace = "cwd",
        },
      },
    },
  })

  local repo_mod = require("gh-pr.repo")
  local pr_service = require("gh-pr.pr_service")
  local branch_name = "feature/my-pr"
  local has_matching_pr = true

  repo_mod.current_branch = function()
    return branch_name, nil
  end
  repo_mod.current_branch_async = function(_, callback)
    callback(branch_name, nil)
  end
  repo_mod.probe_workspace_async = function(_, callback)
    callback({
      eligible = true,
      status = "eligible",
      git_root = vim.fn.getcwd(),
      repository = {
        owner = "owner",
        name = "repo",
        full_name = "owner/repo",
      },
    })
  end
  pr_service.find_pr_for_branch_async = function(resolved_branch, _, callback)
    if has_matching_pr then
      callback({
        number = 77,
        title = "My branch PR",
        state = "OPEN",
        headRefName = resolved_branch,
        headRepository = {
          nameWithOwner = "owner/repo",
        },
      }, nil)
      return
    end

    callback(nil, "No pull request matches the current branch in this repository")
  end

  require("neo-tree")
  local neotree = require("gh-pr.integrations.neotree")
  neotree.handle_neotree_filetype({})

  assert_true(contains_source(state.neo_tree.config.sources, "gh_my_pr"), "gh_my_pr should auto-register on branch match")
  assert_true(
    contains_source(state.neo_tree.config.source_selector.sources, "gh_my_pr"),
    "source selector should include gh_my_pr on branch match"
  )

  branch_name = "feature/no-pr"
  has_matching_pr = false
  neotree.handle_focus_event({})

  assert_false(contains_source(state.neo_tree.config.sources, "gh_my_pr"), "gh_my_pr should disappear when branch stops matching a PR")
  assert_false(
    contains_source(state.neo_tree.config.source_selector.sources, "gh_my_pr"),
    "source selector should hide gh_my_pr when branch stops matching a PR"
  )
end

local function case_diff_comments_tree_opens_bottom()
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

  local neotree = require("gh-pr.integrations.neotree")
  local opened = neotree.open_source("gh_pr_diff_comments", "gh-pr.neotree.diff_comments_source_entry", {
    action = "show",
    toggle = false,
    position = "bottom",
    height = 11,
    selector = false,
  })

  assert_true(opened, "diff comments source should open")
  assert_true(contains_source(state.neo_tree.config.sources, "gh_pr_diff_comments"), "diff comments source should register")
  assert_false(
    contains_source(state.neo_tree.config.source_selector.sources, "gh_pr_diff_comments"),
    "diff comments source must stay out of selector"
  )
  assert_equals(state.neo_tree.config.gh_pr_diff_comments.window.position, "bottom", "diff comments source should use bottom position")
  assert_equals(state.neo_tree.config.gh_pr_diff_comments.window.height, 11, "diff comments source should keep bottom height")
  assert_equals(#state.manager_setups, 1, "diff comments source should setup once")
  assert_equals(state.manager_setups[1].name, "gh_pr_diff_comments", "diff comments source should register the expected module")
  assert_equals(state.command_calls[1].source, "gh_pr_diff_comments", "diff comments source should execute the expected source")
  assert_equals(state.command_calls[1].position, "bottom", "diff comments source should open at bottom")
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

local function case_review_refresh_outside_focus_rerenders_badges()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
    set_active_pr_calls = 0,
    set_active_review_calls = 0,
  }
  install_review_source_runtime_stubs(state)

  local source = require("gh-pr.neotree.review_source")
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = source_buf })
  vim.b[source_buf].neo_tree_source = "gh_pr_review"

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source_buf)
  local tree_state = {
    winid = source_win,
    path = vim.fn.getcwd(),
    gh_pr_review_repo_key = "owner/repo::" .. vim.fn.getcwd(),
  }
  state.window_states[source_win] = tree_state
  vim.api.nvim_set_current_win(current_win)

  source.navigate(tree_state, vim.fn.getcwd())

  local initial_renders = state.show_nodes_calls
  assert_true(initial_renders >= 1, "initial review navigate should render at least once")
  assert_true(type(state.fetch_details_callback) == "function", "review navigate should start details fetch")

  state.fetch_details_callback({
    number = 42,
    state = "OPEN",
    isDraft = false,
    reviewDecision = "REVIEW_REQUIRED",
    mergeStateStatus = "CLEAN",
    mergeable = "MERGEABLE",
    updatedAt = "2026-03-06T15:00:00Z",
    changedFiles = 1,
    baseRepository = {
      nameWithOwner = "owner/repo",
    },
    files = {
      {
        path = "lua/gh-pr/actions.lua",
        filename = "lua/gh-pr/actions.lua",
        status = "modified",
      },
    },
    commits = {},
    labels = {},
  }, nil)

  assert_true(type(state.fetch_threads_callback) == "function", "details fetch should chain review thread fetch")

  state.fetch_threads_callback({
    {
      id = "thread-1",
      path = "lua/gh-pr/actions.lua",
      comments = {
        {
          id = "comment-1",
          path = "lua/gh-pr/actions.lua",
          line = 10,
        },
      },
    },
  }, nil)

  assert_equals(state.show_nodes_calls, initial_renders + 1, "out-of-focus review refresh should rerender visible tree")
  local file_node = find_first_file_node(state.last_nodes)
  assert_true(file_node ~= nil, "review refresh should render a file node")
  assert_equals(file_node.extra.file_comment_count, 1, "file node should include fetched comment count")
  assert_equals(state.set_active_pr_calls, 0, "passive review rerender should not sync active PR runtime")
  assert_equals(state.set_active_review_calls, 0, "passive review rerender should not sync active review runtime")
  assert_equals(state.sync_remote_viewed_calls, 1, "review refresh should request remote viewed-state sync")

  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_win_close(source_win, true)
  end
end

local function case_review_files_filters_apply()
  reset_ghpr_modules()

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          hide_viewed_files = false,
          pr_review = {
            files = {
              flat = false,
            },
          },
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

  package.preload["gh-pr.state"] = function()
    return {
      is_viewed = function(_, _, path)
        return path == "lua/gh-pr/already_viewed.lua"
      end,
      get_pr_review_files_flat_pref = function()
        return false
      end,
    }
  end

  local files_section = require("gh-pr.neotree.review_sections.files")
  local nodes, viewed_files, total_files, meta = files_section.build_nodes({
    number = 42,
  }, {
    files = {
      { path = "lua/gh-pr/already_viewed.lua", status = "modified" },
      { path = "lua/gh-pr/actions.lua", status = "modified" },
      { path = "lua/gh-pr/thread_popup.lua", status = "added" },
      { path = "doc/gh-pr.txt", status = "removed" },
    },
    review_threads = {},
  }, "owner/repo", {
    filters = {
      path_query = "gh-pr",
      status = "modified",
      hide_viewed = true,
      hide_deleted = true,
    },
  })

  assert_equals(total_files, 4, "review files filters should preserve total file count")
  assert_equals(viewed_files, 1, "review files filters should still count viewed files")
  assert_equals(meta.shown_files, 1, "review files filters should trim shown files")
  local file_node = find_first_file_node(nodes)
  assert_true(file_node ~= nil, "review files filters should leave one visible file")
  assert_equals(file_node.path, "lua/gh-pr/actions.lua", "review files filters should keep matching modified unviewed file")
end

local function case_review_file_badges_follow_canonical_paths()
  reset_ghpr_modules()
  install_neotree_stubs({
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  })

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          hide_viewed_files = false,
          pr_review = {
            files = {
              flat = false,
            },
          },
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

  package.preload["gh-pr.state"] = function()
    return {
      is_viewed = function()
        return false
      end,
      get_pr_review_files_flat_pref = function()
        return false
      end,
    }
  end

  local files_section = require("gh-pr.neotree.review_sections.files")
  local nodes = files_section.build_nodes({
    number = 42,
  }, {
    files = {
      {
        path = "lua/gh-pr/new_name.lua",
        previousFilename = "lua/gh-pr/old_name.lua",
        status = "renamed",
      },
    },
    review_threads = {
      {
        id = "thread-1",
        path = "lua/gh-pr/old_name.lua",
        comments = {
          {
            id = "comment-1",
            path = "lua/gh-pr/old_name.lua",
          },
        },
      },
    },
    pending_review_comments = {
      {
        id = "pending-1",
        path = "lua/gh-pr/old_name.lua",
      },
    },
  }, "owner/repo", {
    filters = {},
  })

  local file_node = find_first_file_node(nodes)
  assert_true(file_node ~= nil, "review file badges should render a file node for renamed files")
  assert_equals(file_node.path, "lua/gh-pr/new_name.lua", "review file badges should keep the canonical current path")
  assert_equals(file_node.extra.file_comment_count, 2, "review file badges should count comments from renamed paths")
  assert_true(review_file_badge_text(file_node):find("x2", 1, true) ~= nil, "review file badges should show comment count on canonical file row")
end

local function case_review_file_badges_use_detail_repository_for_viewed_state()
  reset_ghpr_modules()
  install_neotree_stubs({
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  })

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          hide_viewed_files = false,
          pr_review = {
            files = {
              flat = false,
            },
          },
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

  package.preload["gh-pr.state"] = function()
    return {
      is_viewed = function(repo, _, path)
        return repo == "detail-owner/detail-repo" and path == "lua/gh-pr/viewed.lua"
      end,
      get_pr_review_files_flat_pref = function()
        return false
      end,
    }
  end

  local files_section = require("gh-pr.neotree.review_sections.files")
  local nodes = files_section.build_nodes({
    number = 42,
  }, {
    baseRepository = {
      nameWithOwner = "detail-owner/detail-repo",
    },
    files = {
      {
        path = "lua/gh-pr/viewed.lua",
        status = "modified",
      },
    },
    review_threads = {},
  }, "local-owner/local-repo", {
    filters = {},
  })

  local file_node = find_first_file_node(nodes)
  assert_true(file_node ~= nil, "review file badges should render a viewed file node")
  assert_equals(file_node.extra.repo, "detail-owner/detail-repo", "review file badges should prefer repository from PR details")
  local badge_parts = review_file_badge_parts(file_node)
  assert_true(type(badge_parts[2]) == "table", "review file badges should include the viewed badge slot")
  assert_true(vim.trim(badge_parts[2].text or "") ~= "", "review file badges should show viewed icon when details repository matches state")
end

local function case_review_file_badges_normalize_paths_consistently()
  reset_ghpr_modules()
  install_neotree_stubs({
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
  })

  package.preload["gh-pr.config"] = function()
    return {
      get = function()
        return {
          hide_viewed_files = false,
          pr_review = {
            files = {
              flat = false,
            },
          },
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

  package.preload["gh-pr.state"] = function()
    return {
      is_viewed = function(repo, _, path)
        return repo == "owner/repo" and path == "lua/gh-pr/normalized.lua"
      end,
      get_pr_review_files_flat_pref = function()
        return false
      end,
    }
  end

  local files_section = require("gh-pr.neotree.review_sections.files")
  local nodes, viewed_files, total_files = files_section.build_nodes({
    number = 42,
  }, {
    baseRepository = {
      nameWithOwner = "owner/repo",
    },
    files = {
      {
        path = "//lua\\gh-pr//normalized.lua/",
        status = "modified",
      },
    },
    review_threads = {
      {
        id = "thread-1",
        path = "lua/gh-pr/normalized.lua",
        comments = {
          {
            id = "comment-1",
            path = "lua/gh-pr/normalized.lua",
          },
        },
      },
    },
    pending_review_comments = {
      {
        id = "pending-1",
        path = "\\lua\\gh-pr\\normalized.lua\\",
      },
    },
  }, "owner/repo", {
    filters = {},
  })

  local file_node = find_first_file_node(nodes)
  assert_true(file_node ~= nil, "review file badges should render normalized file nodes")
  assert_equals(total_files, 1, "review file badges should not duplicate normalized file paths")
  assert_equals(viewed_files, 1, "review file badges should resolve viewed state across normalized paths")
  assert_equals(file_node.path, "lua/gh-pr/normalized.lua", "review file badges should normalize file paths consistently")
  assert_equals(file_node.extra.file_comment_count, 2, "review file badges should merge comments across normalized path variants")
  local badge_parts = review_file_badge_parts(file_node)
  assert_true(vim.trim(badge_parts[2].text or "") ~= "", "review file badges should keep viewed icon after path normalization")
  assert_true(review_file_badge_text(file_node):find("x2", 1, true) ~= nil, "review file badges should keep comment badge after path normalization")
end

local function case_review_checks_load_annotations_lazily()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
    set_active_pr_calls = 0,
    set_active_review_calls = 0,
  }
  install_review_source_runtime_stubs(state)

  local source = require("gh-pr.neotree.review_source")
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = source_buf })
  vim.b[source_buf].neo_tree_source = "gh_pr_review"

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source_buf)
  local tree_state = {
    winid = source_win,
    path = vim.fn.getcwd(),
    gh_pr_review_repo_key = "owner/repo::" .. vim.fn.getcwd(),
  }
  state.window_states[source_win] = tree_state
  vim.api.nvim_set_current_win(current_win)

  source.navigate(tree_state, vim.fn.getcwd())
  assert_true(type(state.fetch_details_callback) == "function", "review navigate should request details before loading check annotations")

  state.fetch_details_callback({
    number = 42,
    state = "OPEN",
    isDraft = false,
    reviewDecision = "REVIEW_REQUIRED",
    mergeStateStatus = "CLEAN",
    mergeable = "MERGEABLE",
    updatedAt = "2026-03-07T15:00:00Z",
    changedFiles = 1,
    baseRepository = {
      nameWithOwner = "owner/repo",
    },
    headRepository = {
      nameWithOwner = "owner/repo",
    },
    headRefOid = "abc123",
    files = {
      {
        path = "lua/gh-pr/actions.lua",
        filename = "lua/gh-pr/actions.lua",
        status = "modified",
      },
    },
    statusCheckRollup = {
      {
        name = "unit-tests",
        state = "FAIL",
        detailsUrl = "https://example.test/checks/1",
      },
    },
    commits = {},
    labels = {},
  }, nil)

  assert_true(type(state.fetch_threads_callback) == "function", "details refresh should still request review threads")
  state.fetch_threads_callback({}, nil)

  local check_node = find_first_node_by_kind(state.last_nodes, "check")
  assert_true(check_node ~= nil, "review tree should render a check node")

  local ok, err = source.request_check_annotations(tree_state, check_node)
  assert_true(ok == true, err or "check annotation request should start")
  local loading_node = find_first_node_by_kind(state.last_nodes, "message")
  assert_true(loading_node ~= nil and loading_node.name == "Loading annotations...", "check node should render loading child while annotations are in flight")
  assert_true(type(state.fetch_check_annotations_callback) == "function", "check annotation request should use async pr_service fetch")

  state.fetch_check_annotations_callback({
    annotations = {
      {
        path = "lua/gh-pr/actions.lua",
        start_line = 14,
        end_line = 16,
        annotation_level = "failure",
        title = "Nil access",
        message = "Potential nil access",
      },
    },
    check_run_id = 1,
  }, nil)

  local annotation_file = find_first_node_by_kind(state.last_nodes, "check_annotation_file")
  assert_true(annotation_file ~= nil, "loaded check annotations should group by file")
  local annotation_leaf = find_first_node_by_kind(state.last_nodes, "check_annotation")
  assert_true(annotation_leaf ~= nil, "loaded check annotations should create navigable annotation leaves")

  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_win_close(source_win, true)
  end
end

local function case_review_commit_nodes_are_actionable()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
    set_active_pr_calls = 0,
    set_active_review_calls = 0,
  }
  install_review_source_runtime_stubs(state)
  package.preload["gh-pr.neotree.review_sections.overview"] = function()
    return {
      build_root_nodes = function(_, _, sections)
        local nodes = {}
        if type(sections) == "table" then
          local files = type(sections.files) == "table" and sections.files.children or {}
          local commits = type(sections.commits) == "table" and sections.commits.children or {}
          local checks = type(sections.checks) == "table" and sections.checks.children or {}
          local security = type(sections.security) == "table" and sections.security.children or {}
          for _, node in ipairs(type(files) == "table" and files or {}) do
            nodes[#nodes + 1] = node
          end
          for _, node in ipairs(type(commits) == "table" and commits or {}) do
            nodes[#nodes + 1] = node
          end
          for _, node in ipairs(type(checks) == "table" and checks or {}) do
            nodes[#nodes + 1] = node
          end
          for _, node in ipairs(type(security) == "table" and security or {}) do
            nodes[#nodes + 1] = node
          end
        end
        return nodes
      end,
      files_title = function()
        return "Files"
      end,
      reviewers_title = function()
        return "Reviewers"
      end,
      commits_title = function()
        return "Commits"
      end,
      checks_title = function()
        return "Checks"
      end,
      security_title = function()
        return "Security"
      end,
      count_commit_entries = function()
        return 0
      end,
    }
  end

  local source = require("gh-pr.neotree.review_source")
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = source_buf })
  vim.b[source_buf].neo_tree_source = "gh_pr_review"

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source_buf)
  local tree_state = {
    winid = source_win,
    path = vim.fn.getcwd(),
    gh_pr_review_repo_key = "owner/repo::" .. vim.fn.getcwd(),
  }
  state.window_states[source_win] = tree_state
  vim.api.nvim_set_current_win(current_win)

  source.navigate(tree_state, vim.fn.getcwd())
  assert_true(type(state.fetch_details_callback) == "function", "review navigate should request details before rendering commits")

  state.fetch_details_callback({
    number = 42,
    state = "OPEN",
    isDraft = false,
    reviewDecision = "REVIEW_REQUIRED",
    mergeStateStatus = "CLEAN",
    mergeable = "MERGEABLE",
    updatedAt = "2026-03-07T15:00:00Z",
    changedFiles = 1,
    baseRepository = {
      nameWithOwner = "owner/repo",
    },
    headRepository = {
      nameWithOwner = "owner/repo",
    },
    files = {
      {
        path = "lua/gh-pr/actions.lua",
        filename = "lua/gh-pr/actions.lua",
        status = "modified",
      },
    },
    commits = {
      {
        oid = "abc123def456",
        messageHeadline = "Refactor commit opener",
        messageBody = "Commit body",
        url = "https://example.test/commit/abc123def456",
        author = {
          login = "octocat",
        },
      },
    },
    labels = {},
  }, nil)

  assert_true(type(state.fetch_threads_callback) == "function", "details refresh should still request review threads")
  state.fetch_threads_callback({}, nil)

  local commit_node = find_first_node_by_kind(state.last_nodes, "commit")
  assert_true(commit_node ~= nil, "review tree should render a commit node")
  assert_equals(commit_node.type, "commit", "commit node should be actionable, not a directory")
  assert_true(type(commit_node.children) ~= "table" or vim.tbl_isempty(commit_node.children),
    "commit node should not expose child file nodes")

  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_win_close(source_win, true)
  end
end

local function case_review_commit_commands_open_commit_diff()
  reset_ghpr_modules()
  local state = {
    manager_setups = {},
    manager_refreshes = {},
    command_calls = {},
    redraws = 0,
    modules_by_source = {},
    window_states = {},
    open_commit_diff_calls = 0,
    ensure_commit_files_calls = 0,
    toggle_node_calls = 0,
    set_active_pr_calls = 0,
  }
  install_neotree_stubs(state)

  package.preload["gh-pr.actions"] = function()
    return {
      set_active_pr = function(...)
        state.set_active_pr_calls = state.set_active_pr_calls + 1
      end,
      open_commit_diff = function(commit)
        state.open_commit_diff_calls = state.open_commit_diff_calls + 1
        state.last_opened_commit = vim.deepcopy(commit)
      end,
    }
  end

  package.preload["gh-pr.neotree.review_source"] = function()
    return {
      ensure_commit_files = function(...)
        state.ensure_commit_files_calls = state.ensure_commit_files_calls + 1
        return true
      end,
    }
  end

  package.preload["neo-tree.sources.common.commands"] = function()
    return {
      _add_common_commands = function(_) end,
      toggle_node = function(_)
        state.toggle_node_calls = state.toggle_node_calls + 1
      end,
      expand_all_nodes = function(...) end,
      close_all_nodes = function(...) end,
    }
  end

  local commands = require("gh-pr.neotree.review_commands")
  local commit_node = {
    extra = {
      kind = "commit",
      pr = {
        number = 42,
      },
      details = {
        number = 42,
      },
      commit = {
        oid = "abc123def456",
        headline = "Refactor commit opener",
      },
    },
  }
  local tree_state = {
    tree = {
      get_node = function()
        return commit_node
      end,
    },
  }

  commands.gh_pr_review_open(tree_state)
  assert_equals(state.open_commit_diff_calls, 1, "review open should route commit nodes to open_commit_diff")
  assert_equals(state.ensure_commit_files_calls, 0, "review open should not try to load commit child nodes")
  assert_equals(state.toggle_node_calls, 0, "review open should not toggle commit nodes")
  assert_equals((state.last_opened_commit or {}).oid, "abc123def456", "review open should pass the selected commit")

  commands.open_diff(tree_state)
  assert_equals(state.open_commit_diff_calls, 2, "review open_diff should reuse open_commit_diff for commit nodes")

  package.preload["gh-pr.neotree.review_source"] = nil
  package.preload["gh-pr.actions"] = nil
  package.preload["neo-tree.sources.common.commands"] = nil
end

local function case_review_security_loads_findings_lazily()
  reset_ghpr_modules()
  local state = {
    show_nodes_calls = 0,
    synced_buffers = 0,
    window_states = {},
    set_active_pr_calls = 0,
    set_active_review_calls = 0,
  }
  install_review_source_runtime_stubs(state)

  local source = require("gh-pr.neotree.review_source")
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = source_buf })
  vim.b[source_buf].neo_tree_source = "gh_pr_review"

  local current_win = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source_buf)
  local tree_state = {
    winid = source_win,
    path = vim.fn.getcwd(),
    gh_pr_review_repo_key = "owner/repo::" .. vim.fn.getcwd(),
  }
  state.window_states[source_win] = tree_state
  vim.api.nvim_set_current_win(current_win)

  source.navigate(tree_state, vim.fn.getcwd())
  assert_true(type(state.fetch_details_callback) == "function", "review navigate should request details before loading security")

  state.fetch_details_callback({
    number = 42,
    state = "OPEN",
    isDraft = false,
    reviewDecision = "REVIEW_REQUIRED",
    mergeStateStatus = "CLEAN",
    mergeable = "MERGEABLE",
    updatedAt = "2026-03-07T15:00:00Z",
    changedFiles = 2,
    baseRepository = {
      nameWithOwner = "owner/repo",
    },
    headRepository = {
      nameWithOwner = "owner/repo",
    },
    baseRefName = "main",
    headRefName = "feature/security",
    headRefOid = "abc123",
    files = {
      {
        path = "lua/gh-pr/actions.lua",
        filename = "lua/gh-pr/actions.lua",
        status = "modified",
      },
      {
        path = "package-lock.json",
        filename = "package-lock.json",
        status = "modified",
      },
    },
    statusCheckRollup = {},
    commits = {},
    labels = {},
  }, nil)

  assert_true(type(state.fetch_threads_callback) == "function", "details refresh should still request review threads")
  state.fetch_threads_callback({}, nil)

  local code_scanning_node = find_first_node_by_kind(state.last_nodes, "security_code_scanning")
  assert_true(code_scanning_node ~= nil, "review tree should render a code scanning security node")

  local dependency_review_node = find_first_node_by_kind(state.last_nodes, "security_dependency_review")
  assert_true(dependency_review_node ~= nil, "review tree should render a dependency review security node")

  local ok, err = source.request_security_code_scanning(tree_state, code_scanning_node)
  assert_true(ok == true, err or "security code scanning request should start")
  local loading_node = find_first_node_matching(state.last_nodes, function(node)
    return type(node) == "table"
      and type(node.extra) == "table"
      and node.extra.kind == "security_loading"
      and node.name == "Loading..."
  end)
  assert_true(loading_node ~= nil and loading_node.name == "Loading...", "security code scanning should render loading child")
  assert_true(type(state.fetch_code_scanning_callback) == "function", "security code scanning should use async pr_service fetch")

  state.fetch_code_scanning_callback({
    alerts = {
      {
        id = "alert-1",
        path = "lua/gh-pr/actions.lua",
        start_line = 42,
        end_line = 44,
        severity = "high",
        rule_name = "SQL injection risk",
        html_url = "https://example.test/security/1",
      },
    },
  }, nil)

  local security_file = find_first_node_by_kind(state.last_nodes, "security_code_scanning_file")
  assert_true(security_file ~= nil, "loaded code scanning should group findings by file")
  local security_alert = find_first_node_by_kind(state.last_nodes, "security_code_scanning_alert")
  assert_true(security_alert ~= nil, "loaded code scanning should create navigable alert leaves")

  ok, err = source.request_security_dependency_review(tree_state, dependency_review_node)
  assert_true(ok == true, err or "dependency review request should start")
  assert_true(type(state.fetch_dependency_review_callback) == "function", "dependency review should use async pr_service fetch")

  state.fetch_dependency_review_callback({
    changes = {
      {
        manifest_path = "package-lock.json",
        package_name = "lodash",
        change_type = "updated",
        previous_version = "4.17.20",
        current_version = "4.17.21",
        vulnerable = true,
        vulnerabilities = {
          {
            advisory_id = "GHSA-test",
            summary = "Prototype pollution",
            severity = "high",
            advisory_url = "https://example.test/advisory/1",
          },
        },
      },
    },
    vulnerable_count = 1,
  }, nil)

  local manifest_node = find_first_node_by_kind(state.last_nodes, "security_dependency_manifest")
  assert_true(manifest_node ~= nil, "dependency review should group findings by manifest")
  local dependency_node = find_first_node_by_kind(state.last_nodes, "security_dependency_package")
  assert_true(dependency_node ~= nil, "dependency review should create dependency nodes")
  local vulnerability_node = find_first_node_by_kind(state.last_nodes, "security_dependency_vulnerability")
  assert_true(vulnerability_node ~= nil, "dependency review should create vulnerability leaves")

  if vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_win_close(source_win, true)
  end
end

local function case_pr_row_badges_compact_summary()
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

  local components = require("gh-pr.neotree.components")
  local node = {
    type = "pr",
    name = "#42 Improve badges",
    extra = {
      kind = "pr",
      pr = {
        number = 42,
        title = "Improve badges",
        author = {
          login = "octocat",
        },
        reviewDecision = "CHANGES_REQUESTED",
      },
      details = {
        number = 42,
        title = "Improve badges",
        author = {
          login = "octocat",
        },
        isDraft = true,
        mergeable = "CONFLICTING",
        mergeStateStatus = "DIRTY",
        reviewDecision = "CHANGES_REQUESTED",
        latestReviews = {
          {
            author = {
              login = "reviewer-a",
            },
            state = "APPROVED",
          },
          {
            author = {
              login = "reviewer-b",
            },
            state = "APPROVED",
          },
          {
            author = {
              login = "reviewer-c",
            },
            state = "CHANGES_REQUESTED",
          },
        },
        statusCheckRollup = {
          {
            status = "COMPLETED",
            conclusion = "SUCCESS",
          },
        },
      },
    },
  }

  assert_equals(components.pr_title({}, node, {}).text, "#42 Improve badges",
    "PR title renderer should only include number and title")
  assert_equals(pr_meta_badge_text(node), " @octocat DRAFT OK CONFLICT REQ APP2",
    "PR meta badges should summarize author, draft, checks, conflicts, review state, and approvals")
end

local function case_pr_row_badges_hide_unknowns()
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

  local node = {
    type = "pr",
    name = "#7 Pending query result",
    extra = {
      kind = "pr",
      pr = {
        number = 7,
        title = "Pending query result",
        author = {
          login = "hubot",
        },
        reviewDecision = "REVIEW_REQUIRED",
      },
      details = nil,
    },
  }

  assert_equals(pr_meta_badge_text(node), " @hubot PEND",
    "PR meta badges should keep query-level author/review decision and hide detail-only badges until details load")
end

case_eager_entry_module()
case_external_source_contract()
case_open_pending_and_idempotent()
case_github_gate_hides_source()
case_manual_gate_skips_auto_registration()
case_neotree_manager_fast_events_are_scheduled()
case_review_tree_keeps_toggle()
case_my_pr_auto_registers_on_branch_match()
case_diff_comments_tree_opens_bottom()
case_refresh_outside_focus_avoids_render()
case_initial_navigate_renders_without_live_state()
case_review_refresh_outside_focus_rerenders_badges()
case_review_files_filters_apply()
case_review_file_badges_follow_canonical_paths()
case_review_file_badges_use_detail_repository_for_viewed_state()
case_review_file_badges_normalize_paths_consistently()
case_review_checks_load_annotations_lazily()
case_review_commit_nodes_are_actionable()
case_review_commit_commands_open_commit_diff()
case_review_security_loads_findings_lazily()
case_pr_row_badges_compact_summary()
case_pr_row_badges_hide_unknowns()
