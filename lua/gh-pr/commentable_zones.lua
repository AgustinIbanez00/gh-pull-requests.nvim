local M = {}

local config = require("gh-pr.config")
local highlights = require("gh-pr.highlights")
local inline_targets = require("gh-pr.core.inline_comment_targets")
local pr_service = require("gh-pr.pr_service")
local review_context = require("gh-pr.core.review_context")
local state = require("gh-pr.state")

local namespace = vim.api.nvim_create_namespace("gh-pr-commentable-zones")
local sign_group = "gh_pr_commentable_zones"
local sign_name = "GhPrCommentableZoneSign"
local patch_cache = {}
local patch_fetch_inflight = {}

local function normalize_path(path)
  return review_context.normalize_path(path)
end

local function safe_string(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

local function zone_config()
  local diff_view = ((config.get() or {}).diff_view or {})
  local zones = type(diff_view.commentable_zones) == "table" and diff_view.commentable_zones or {}
  return {
    enabled = zones.enabled ~= false,
    sign = type(zones.sign) == "string" and zones.sign ~= "" and zones.sign or "+",
    keymap = type(zones.keymap) == "string" and zones.keymap or "+",
  }
end

local function cache_key(pr_number, path)
  local number = tonumber(pr_number)
  local normalized = normalize_path(path)
  if not number or normalized == "" then
    return nil
  end
  return tostring(number) .. "\0" .. normalized
end

local function file_patch(file)
  local patch = type(file) == "table" and file.patch or nil
  if type(patch) == "string" and patch ~= "" then
    return patch
  end
  return nil
end

local function add_path(paths, seen, path)
  local normalized = normalize_path(path)
  if normalized == "" or seen[normalized] then
    return
  end
  seen[normalized] = true
  paths[#paths + 1] = normalized
end

local function file_path_candidates(file)
  local paths = {}
  local seen = {}
  if type(file) ~= "table" then
    return paths
  end
  add_path(paths, seen, file.path)
  add_path(paths, seen, file.filename)
  add_path(paths, seen, file.previous_filename)
  add_path(paths, seen, file.previousFilename)
  return paths
end

local function file_matches_path(file, path)
  local target = normalize_path(path)
  if target == "" then
    return false
  end
  for _, candidate in ipairs(file_path_candidates(file)) do
    if candidate == target then
      return true
    end
  end
  return false
end

local function find_file_for_path(files, path)
  if type(files) ~= "table" then
    return nil
  end
  for _, file in ipairs(files) do
    if file_matches_path(file, path) then
      return file
    end
  end
  return nil
end

local function cache_patch_in_active_state(pr_number, path, patch, rest_file, ctx_file)
  if type(patch) ~= "string" or patch == "" then
    return
  end

  if type(ctx_file) == "table" and file_matches_path(ctx_file, path) then
    ctx_file.patch = patch
  end

  local active_file = state.get_active_file()
  if type(active_file) == "table" and file_matches_path(active_file, path) then
    active_file.patch = patch
  end

  local active_pr, details = state.get_active_pr()
  if tonumber(type(active_pr) == "table" and active_pr.number or nil) ~= tonumber(pr_number) then
    return
  end

  local details_file = find_file_for_path(type(details) == "table" and details.files or nil, path)
  if type(details_file) == "table" then
    details_file.patch = patch
    if type(rest_file) == "table" then
      details_file.filename = details_file.filename or rest_file.filename
      details_file.path = details_file.path or rest_file.filename or rest_file.path
      details_file.previous_filename = details_file.previous_filename or rest_file.previous_filename
      details_file.previousFilename = details_file.previousFilename or rest_file.previous_filename
      details_file.status = details_file.status or rest_file.status
    end
  end
end

local function ensure_sign(sign_text)
  highlights.ensure_baseline_links()
  local text = type(sign_text) == "string" and sign_text ~= "" and sign_text or "+"
  if #text > 2 then
    text = text:sub(1, 2)
  end
  vim.fn.sign_define(sign_name, {
    text = text,
    texthl = "GhPrCommentableZone",
  })
end

function M.clear_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, sign_group, { buffer = bufnr })
  vim.b[bufnr].gh_pr_commentable_zones = {}
  vim.b[bufnr].gh_pr_commentable_zone_patch_pending = false
end

local function is_commentable_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.b[bufnr].gh_pr_diff_backend ~= "codediff" then
    return false
  end
  if vim.b[bufnr].gh_pr_is_non_text == true or vim.b[bufnr].gh_pr_is_image == true then
    return false
  end

  local kind = vim.b[bufnr].gh_pr_file_kind
  return kind == "base" or kind == "head" or kind == "unified"
end

local function same_diff_buffer(bufnr, ctx)
  if not is_commentable_buffer(bufnr) then
    return false
  end

  local number = tonumber(ctx.pr_number)
  if number and tonumber(vim.b[bufnr].gh_pr_number) ~= number then
    return false
  end

  local current_path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
  local expected_path = normalize_path(ctx.path)
  return expected_path ~= "" and current_path == expected_path
end

local function resolve_patch(ctx)
  local patch = type(ctx.patch) == "string" and ctx.patch ~= "" and ctx.patch or file_patch(ctx.file)
  if patch then
    return patch
  end

  local key = cache_key(ctx.pr_number, ctx.path)
  if key and type(patch_cache[key]) == "string" and patch_cache[key] ~= "" then
    return patch_cache[key]
  end

  return nil
end

local function request_patch_async(bufnr, ctx)
  if type(pr_service.fetch_pr_files_api_async) ~= "function" then
    return
  end

  local number = tonumber(ctx.pr_number)
  local path = normalize_path(ctx.path)
  local key = cache_key(number, path)
  if not key then
    return
  end

  vim.b[bufnr].gh_pr_commentable_zone_patch_pending = true
  if type(patch_fetch_inflight[key]) == "table" then
    patch_fetch_inflight[key][#patch_fetch_inflight[key] + 1] = {
      bufnr = bufnr,
      ctx = ctx,
    }
    return
  end

  patch_fetch_inflight[key] = {
    {
      bufnr = bufnr,
      ctx = ctx,
    },
  }

  pr_service.fetch_pr_files_api_async(number, function(files)
    local function finish()
      local waiters = patch_fetch_inflight[key]
      patch_fetch_inflight[key] = nil
      waiters = type(waiters) == "table" and waiters or {}
      local rest_file = find_file_for_path(files, path)
      local patch = file_patch(rest_file)
      if type(patch) ~= "string" or patch == "" then
        for _, waiter in ipairs(waiters) do
          local waiter_bufnr = tonumber(waiter.bufnr)
          if waiter_bufnr and vim.api.nvim_buf_is_valid(waiter_bufnr) then
            vim.b[waiter_bufnr].gh_pr_commentable_zone_patch_pending = false
          end
        end
        return
      end

      patch_cache[key] = patch

      for _, waiter in ipairs(waiters) do
        local waiter_bufnr = tonumber(waiter.bufnr)
        local waiter_ctx = type(waiter.ctx) == "table" and waiter.ctx or {}
        cache_patch_in_active_state(number, path, patch, rest_file, waiter_ctx.file)
        if waiter_bufnr and vim.api.nvim_buf_is_valid(waiter_bufnr) and same_diff_buffer(waiter_bufnr, waiter_ctx) then
          local next_ctx = vim.tbl_extend("force", {}, waiter_ctx, {
            patch = patch,
            fetch_missing_patch = false,
          })
          M.attach_to_buffer(waiter_bufnr, next_ctx)
        end
      end
    end

    if vim.in_fast_event and vim.in_fast_event() then
      vim.schedule(finish)
    else
      vim.schedule(finish)
    end
  end)
end

function M.attach_to_buffer(bufnr, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  bufnr = tonumber(bufnr) or vim.api.nvim_get_current_buf()

  M.clear_buffer(bufnr)
  if not is_commentable_buffer(bufnr) then
    return
  end

  local cfg = zone_config()
  if not cfg.enabled then
    return
  end

  local path = normalize_path(ctx.path or vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
  if path == "" then
    return
  end

  local patch = resolve_patch(vim.tbl_extend("force", {}, ctx, { path = path }))
  if not patch then
    if ctx.fetch_missing_patch ~= false then
      request_patch_async(bufnr, vim.tbl_extend("force", {}, ctx, {
        path = path,
        pr_number = tonumber(ctx.pr_number) or tonumber(vim.b[bufnr].gh_pr_number),
      }))
    end
    return
  end

  local zones = inline_targets.commentable_lines({
    bufnr = bufnr,
    path = path,
    patch = patch,
    kind = safe_string(ctx.kind) ~= "" and ctx.kind or vim.b[bufnr].gh_pr_file_kind,
    file_mode = safe_string(ctx.file_mode) ~= "" and ctx.file_mode or vim.b[bufnr].gh_pr_file_mode,
    backend = "codediff",
    layout = safe_string(ctx.layout) ~= "" and ctx.layout or vim.b[bufnr].gh_pr_codediff_layout,
  })

  vim.b[bufnr].gh_pr_commentable_zones = zones
  if vim.tbl_isempty(zones) then
    return
  end

  ensure_sign(cfg.sign)
  for line in pairs(zones) do
    pcall(vim.fn.sign_place, 0, sign_group, sign_name, bufnr, {
      lnum = line,
      priority = 20,
    })
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
      priority = 20,
    })
  end
end

function M.apply_keymap(bufnr, handler)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local old_key = vim.b[bufnr].gh_pr_commentable_zone_keymap
  if type(old_key) == "string" and old_key ~= "" then
    pcall(vim.keymap.del, "n", old_key, { buffer = bufnr })
  end
  vim.b[bufnr].gh_pr_commentable_zone_keymap = nil

  local cfg = zone_config()
  if not cfg.enabled or type(cfg.keymap) ~= "string" or cfg.keymap == "" or type(handler) ~= "function" then
    return
  end

  vim.keymap.set("n", cfg.keymap, handler, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "GH PR: add inline comment at commentable line",
  })
  vim.b[bufnr].gh_pr_commentable_zone_keymap = cfg.keymap
end

function M._reset_for_tests()
  patch_cache = {}
  patch_fetch_inflight = {}
end

return M
