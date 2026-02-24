local M = {}

local config = require("gh-pr.config")

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end

  local separator = package.config:sub(1, 1)
  return table.concat({ ... }, separator)
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end

  return path:match("^(.*)[/\\]") or ""
end

local function queries_path()
  return joinpath(vim.fn.stdpath("state"), "gh-pr", "queries.json")
end

local function ensure_dir()
  local dir = dirname(queries_path())
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function save()
  ensure_dir()
  local payload = vim.json.encode({ queries = config.get_queries() })
  vim.fn.writefile(vim.split(payload, "\n", { plain = true }), queries_path())
end

function M.setup(skip_load)
  if skip_load then
    return
  end

  local path = queries_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  if content == "" then
    return
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or type(decoded.queries) ~= "table" then
    return
  end

  config.set_queries(decoded.queries)
end

function M.list()
  return config.get_queries()
end

function M.add(query)
  config.add_query(query)
  save()
end

function M.update(id, query)
  local changed = config.update_query(id, query)
  if changed then
    save()
  end
  return changed
end

function M.delete(id)
  local changed = config.delete_query(id)
  if changed then
    save()
  end
  return changed
end

return M
