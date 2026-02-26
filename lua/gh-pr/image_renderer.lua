local M = {}

local uv = vim.uv or vim.loop

local DEFAULT_FORMATS = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  bmp = true,
  svg = true,
}

local active = {}

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end

  local sep = package.config:sub(1, 1)
  return table.concat({ ... }, sep)
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end

  return path:match("^(.*)[/\\]") or ""
end

local function ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return false, "missing-dir"
  end

  if vim.fn.isdirectory(path) == 1 then
    return true, nil
  end

  local parent = dirname(path)
  if parent ~= "" and parent ~= path then
    local ok_parent, err_parent = ensure_dir(parent)
    if not ok_parent then
      return false, err_parent
    end
  end

  local ok, err, code = uv.fs_mkdir(path, 493) -- 0755
  if ok or code == "EEXIST" then
    return true, nil
  end

  return false, err or "mkdir-failed"
end

local function write_bytes(path, data)
  local fd, open_err = uv.fs_open(path, "w", 420) -- 0644
  if not fd then
    return false, open_err or "open-failed"
  end

  local ok, write_err = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not ok then
    return false, write_err or "write-failed"
  end

  return true, nil
end

local function sanitize_segment(value)
  value = type(value) == "string" and value or ""
  value = value:gsub("\\", "/")
  value = value:gsub("%.%.", "_")
  value = value:gsub("[^%w%._%-/]", "_")
  value = value:gsub("/+", "/")
  value = value:gsub("^/", "")
  value = value:gsub("/$", "")
  if value == "" then
    return "_"
  end
  return value
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return (path:gsub("\\", "/"))
end

local function extension(path)
  local normalized = normalize_path(path)
  local ext = normalized:match("%.([^.]+)$")
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function normalize_formats(formats)
  if type(formats) ~= "table" or vim.tbl_isempty(formats) then
    return vim.deepcopy(DEFAULT_FORMATS)
  end

  local normalized = {}
  for _, ext in ipairs(formats) do
    if type(ext) == "string" and ext ~= "" then
      normalized[ext:lower()] = true
    end
  end

  if vim.tbl_isempty(normalized) then
    return vim.deepcopy(DEFAULT_FORMATS)
  end

  return normalized
end

local function format_bytes(size)
  local value = tonumber(size) or 0
  if value < 1024 then
    return string.format("%d B", value)
  end

  local units = { "KB", "MB", "GB" }
  local scaled = value
  local unit = units[1]
  for _, candidate in ipairs(units) do
    scaled = scaled / 1024
    unit = candidate
    if scaled < 1024 or candidate == units[#units] then
      break
    end
  end

  return string.format("%.2f %s", scaled, unit)
end

local function get_snacks_image()
  local snacks_ok, snacks = pcall(require, "snacks")
  if not snacks_ok or type(snacks) ~= "table" then
    return nil
  end

  if type(snacks.image) ~= "table" then
    return nil
  end

  return snacks.image
end

local function clear_snacks_placement(bufnr)
  local image = get_snacks_image()
  if not image or type(image.placement) ~= "table" or type(image.placement.clean) ~= "function" then
    return
  end

  pcall(image.placement.clean, bufnr)
end

local function cache_root(images_cfg)
  if type(images_cfg) == "table" and type(images_cfg.cache_dir) == "string" and images_cfg.cache_dir ~= "" then
    return images_cfg.cache_dir
  end

  return joinpath(vim.fn.stdpath("cache"), "gh-pr", "images")
end

local function to_cache_path(opts)
  local repo = sanitize_segment(opts.repository or "repo")
  local number = tostring(tonumber(opts.pr_number) or 0)
  local side = sanitize_segment(opts.side or "head")
  local path = sanitize_segment(opts.path or "image")
  local ext = extension(path)
  local hash = sanitize_segment(opts.sha or "")
  if hash == "_" then
    hash = sanitize_segment(string.format("size-%s", tostring(opts.size or 0)))
  end

  local filename = hash
  if ext ~= "" then
    filename = filename .. "." .. ext
  end

  return joinpath(cache_root(opts.images), repo, number, side, path, filename)
end

local function ensure_cache_file(opts)
  local target = to_cache_path(opts)
  local dir = dirname(target)
  local ok_dir, dir_err = ensure_dir(dir)
  if not ok_dir then
    return nil, dir_err
  end

  if uv.fs_stat(target) then
    return target, nil
  end

  local ok_write, write_err = write_bytes(target, opts.bytes)
  if not ok_write then
    return nil, write_err
  end

  return target, nil
end

function M.extension(path)
  return extension(path)
end

function M.is_image_path(path, formats)
  local ext = extension(path)
  if ext == "" then
    return false
  end

  local allowed = normalize_formats(formats)
  return allowed[ext] == true
end

function M.clear(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 then
    return
  end

  clear_snacks_placement(bufnr)
  active[bufnr] = nil
end

function M.ensure_cache(opts)
  opts = type(opts) == "table" and opts or {}
  if type(opts.bytes) ~= "string" or opts.bytes == "" then
    return nil, "missing-bytes"
  end
  return ensure_cache_file(opts)
end

function M.get_cache_path(bufnr)
  if type(bufnr) ~= "number" then
    return nil
  end
  local item = active[bufnr]
  if type(item) == "table" and type(item.cache_path) == "string" and item.cache_path ~= "" then
    return item.cache_path
  end
  return nil
end

function M.build_placeholder_lines(opts)
  opts = type(opts) == "table" and opts or {}
  local lines = {
    "gh-pr image preview",
    "",
  }

  local path = type(opts.path) == "string" and opts.path or "unknown"
  local side = type(opts.side) == "string" and opts.side or "head"
  lines[#lines + 1] = string.format("path: %s", path)
  lines[#lines + 1] = string.format("side: %s", side)

  if type(opts.status) == "string" and opts.status ~= "" then
    lines[#lines + 1] = string.format("status: %s", opts.status)
  end

  if opts.show_metadata ~= false then
    if type(opts.size) == "number" and opts.size > 0 then
      lines[#lines + 1] = string.format("size: %s", format_bytes(opts.size))
    end

    if type(opts.sha) == "string" and opts.sha ~= "" then
      lines[#lines + 1] = string.format("sha: %s", opts.sha:sub(1, 12))
    end
  end

  if type(opts.reason) == "string" and opts.reason ~= "" then
    lines[#lines + 1] = ""
    local heading = "preview unavailable:"
    if opts.reason:lower():find("rendering", 1, true) == 1 then
      heading = "preview status:"
    end
    lines[#lines + 1] = heading
    lines[#lines + 1] = opts.reason
  end

  return lines
end

function M.render(opts)
  opts = type(opts) == "table" and opts or {}
  local bufnr = tonumber(opts.bufnr)
  local winid = tonumber(opts.winid)
  local asset = type(opts.asset) == "table" and opts.asset or nil
  local images_cfg = type(opts.images) == "table" and opts.images or {}

  if not bufnr or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid-buffer", nil
  end

  M.clear(bufnr)

  if not asset or asset.is_image ~= true then
    return false, "not-image", nil
  end
  if images_cfg.enabled == false then
    return false, "disabled", nil
  end
  if type(images_cfg.backend) == "string" and images_cfg.backend ~= "" and images_cfg.backend ~= "snacks" then
    return false, "unsupported-backend", nil
  end

  local max_bytes = tonumber(images_cfg.max_bytes)
  if max_bytes and max_bytes > 0 and tonumber(asset.size or 0) > max_bytes then
    return false, "too-large", nil
  end
  if asset.skipped == true and type(asset.skip_reason) == "string" and asset.skip_reason ~= "" then
    return false, asset.skip_reason, nil
  end
  if type(asset.bytes) ~= "string" or asset.bytes == "" then
    return false, "missing-bytes", nil
  end

  local image = get_snacks_image()
  if not image then
    return false, "backend-unavailable", nil
  end

  if type(image.supports) == "function" then
    local ok_supports, supports = pcall(image.supports, asset.path or "")
    if ok_supports and supports == false then
      return false, "terminal-or-format-unsupported", nil
    end
  end

  if type(image.placement) ~= "table" or type(image.placement.new) ~= "function" then
    return false, "placement-api-missing", nil
  end

  local cache_path, cache_err = ensure_cache_file({
    repository = opts.repository,
    pr_number = opts.pr_number,
    side = opts.side,
    path = asset.path,
    sha = asset.sha,
    size = asset.size,
    bytes = asset.bytes,
    images = images_cfg,
  })
  if not cache_path then
    return false, "cache-write-failed: " .. tostring(cache_err), nil
  end

  local current = vim.api.nvim_get_current_win()
  local target = (winid and winid > 0 and vim.api.nvim_win_is_valid(winid)) and winid or current
  local width = math.max(12, vim.api.nvim_win_get_width(target) - 2)
  local height = math.max(6, vim.api.nvim_win_get_height(target) - 2)

  local placement = nil
  local ok_render, render_err = pcall(function()
    if target ~= current and vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    placement = image.placement.new(bufnr, cache_path, {
      pos = { 1, 0 },
      inline = false,
      auto_resize = true,
      max_width = width,
      max_height = height,
    })
  end)

  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_get_current_win() ~= current then
    pcall(vim.api.nvim_set_current_win, current)
  end

  if not ok_render or not placement then
    return false, "render-failed: " .. tostring(render_err), {
      cache_path = cache_path,
    }
  end

  active[bufnr] = {
    cache_path = cache_path,
    placement = placement,
  }

  return true, nil, {
    cache_path = cache_path,
  }
end

return M
