local M = {}

local config = require("gh-pr.config")

local last_lua_queries = nil

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

-- Canonical signature: sorted by folder+label, only folder/label/query fields
local function signature(queries)
  if type(queries) ~= "table" or #queries == 0 then
    return "[]"
  end

  local items = {}
  for _, q in ipairs(queries) do
    if type(q) == "table" then
      table.insert(items, {
        folder = type(q.folder) == "string" and q.folder or "",
        label = type(q.label) == "string" and q.label or "",
        query = type(q.query) == "string" and q.query or "",
      })
    end
  end

  table.sort(items, function(a, b)
    local ka = a.folder .. "\0" .. a.label
    local kb = b.folder .. "\0" .. b.label
    return ka < kb
  end)

  local ok, encoded = pcall(vim.json.encode, items)
  return ok and encoded or "[]"
end

-- Read + decode file; migrate v1 → v2 in-memory; returns { queries, meta } or nil
local function load_file()
  local path = queries_path()
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  if content == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or type(decoded.queries) ~= "table" then
    return nil
  end

  local meta
  if decoded.version == nil then
    -- v1 migration: construct default meta without writing yet
    meta = { lua_signature = nil, conflict_choice = "ask", saved_at = nil }
  else
    local raw = type(decoded.meta) == "table" and decoded.meta or {}
    meta = {
      lua_signature = type(raw.lua_signature) == "string" and raw.lua_signature or nil,
      conflict_choice = type(raw.conflict_choice) == "string" and raw.conflict_choice or "ask",
      saved_at = type(raw.saved_at) == "number" and raw.saved_at or nil,
    }
  end

  return { queries = decoded.queries, meta = meta }
end

local function save(queries, meta)
  ensure_dir()
  meta = meta or {}
  local lua_sig = meta.lua_signature

  local payload = {
    version = 2,
    queries = queries,
    meta = {
      saved_at = os.time(),
      lua_signature = (lua_sig ~= nil) and lua_sig or vim.NIL,
      conflict_choice = meta.conflict_choice or "ask",
    },
  }

  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return
  end

  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), queries_path())
end

local function format_relative(saved_at)
  if type(saved_at) ~= "number" then
    return "hace un tiempo"
  end

  local diff = math.max(0, os.time() - saved_at)
  local days = math.floor(diff / 86400)
  local hours = math.floor(diff / 3600)
  local minutes = math.floor(diff / 60)

  if days >= 1 then
    return days == 1 and "hace 1 día" or ("hace " .. days .. " días")
  elseif hours >= 1 then
    return hours == 1 and "hace 1 hora" or ("hace " .. hours .. " horas")
  elseif minutes >= 1 then
    return minutes == 1 and "hace 1 minuto" or ("hace " .. minutes .. " minutos")
  else
    return "hace un momento"
  end
end

local function apply_to_config(queries)
  config.set_queries(queries)
end

local function trigger_refresh()
  local ok, registry = pcall(require, "gh-pr.neotree.registry")
  if not ok then
    return
  end

  for _, source_name in ipairs({ "gh_pr", "gh_pr_review", "gh_my_pr" }) do
    local source = registry.get(source_name)
    if type(source) == "table" then
      if type(source.invalidate_cache) == "function" then
        pcall(source.invalidate_cache)
      end
      if type(source.request_refresh) == "function" then
        pcall(source.request_refresh, nil, {
          force = false,
          notify_error = false,
          refresh_context = { mode = "ui-refresh", reason = "queries-update", notify = false },
        })
      end
    end
  end
end

local function schedule_prompt(stored, lua_queries, lua_sig)
  vim.schedule(function()
    local relative = format_relative(stored.meta.saved_at)
    local opt_local = "Configuración local (guardada " .. relative .. ")"
    local opt_lua = "Configuración de nvim/lua"

    vim.ui.select({ opt_local, opt_lua }, {
      prompt = "Queries modificadas en Lua. ¿Qué consultas debemos conservar?",
    }, function(choice)
      if not choice then
        return
      end

      local use_lua = choice == opt_lua

      vim.ui.select(
        { "Sí, preguntar siempre", "No, recordar mi elección" },
        { prompt = "¿Volver a preguntarte la próxima vez que cambien?" },
        function(remember_choice)
          if not remember_choice then
            return
          end

          local conflict_choice
          if remember_choice == "No, recordar mi elección" then
            conflict_choice = use_lua and "always_lua" or "always_local"
          else
            conflict_choice = "ask"
          end

          local final_queries = use_lua and lua_queries or stored.queries
          save(final_queries, { lua_signature = lua_sig, conflict_choice = conflict_choice })
          apply_to_config(final_queries)

          local msg = use_lua and "gh-pr: queries actualizadas desde configuración Lua"
            or "gh-pr: queries locales conservadas"
          vim.notify(msg, vim.log.levels.INFO)
          trigger_refresh()
        end
      )
    end)
  end)
end

function M.setup(opts)
  opts = opts or {}
  local lua_queries = opts.lua_queries
  last_lua_queries = lua_queries

  local stored = load_file()

  if not stored then
    if lua_queries and #lua_queries > 0 then
      local sig = signature(lua_queries)
      save(lua_queries, { lua_signature = sig, conflict_choice = "ask" })
      apply_to_config(lua_queries)
    else
      local defaults = config.get_default_queries()
      save(defaults, { lua_signature = nil, conflict_choice = "ask" })
      apply_to_config(defaults)
    end
    return
  end

  -- File exists: no Lua queries → local always wins
  if not lua_queries or #lua_queries == 0 then
    apply_to_config(stored.queries)
    return
  end

  local current_sig = signature(lua_queries)
  -- Signatures match → local edits preserved
  if stored.meta.lua_signature == current_sig then
    apply_to_config(stored.queries)
    return
  end

  -- Conflict: Lua changed since last reconciliation
  local choice = stored.meta.conflict_choice
  if choice == "always_lua" then
    save(lua_queries, { lua_signature = current_sig, conflict_choice = "always_lua" })
    apply_to_config(lua_queries)
  elseif choice == "always_local" then
    -- Update signature so next Lua change re-triggers the check
    save(stored.queries, { lua_signature = current_sig, conflict_choice = "always_local" })
    apply_to_config(stored.queries)
  else
    -- "ask": apply local while async prompt resolves
    apply_to_config(stored.queries)
    schedule_prompt(stored, lua_queries, current_sig)
  end
end

function M.list()
  return config.get_queries()
end

function M.add(query)
  config.add_query(query)
  local stored = load_file()
  local meta = stored and stored.meta or { conflict_choice = "ask" }
  save(config.get_queries(), meta)
end

function M.update(id, query)
  local changed = config.update_query(id, query)
  if changed then
    local stored = load_file()
    local meta = stored and stored.meta or { conflict_choice = "ask" }
    save(config.get_queries(), meta)
  end
  return changed
end

function M.delete(id)
  local changed = config.delete_query(id)
  if changed then
    local stored = load_file()
    local meta = stored and stored.meta or { conflict_choice = "ask" }
    save(config.get_queries(), meta)
  end
  return changed
end

function M.reset_prompt_choice()
  local stored = load_file()
  if not stored then
    vim.notify("gh-pr: no hay archivo de queries persistido", vim.log.levels.WARN)
    return
  end
  save(stored.queries, { lua_signature = stored.meta.lua_signature, conflict_choice = "ask" })
  vim.notify("gh-pr: se volverá a preguntar en el próximo conflicto de queries", vim.log.levels.INFO)
end

function M.reload_from_lua()
  if not last_lua_queries or #last_lua_queries == 0 then
    vim.notify("gh-pr: no hay queries de Lua configuradas", vim.log.levels.WARN)
    return
  end
  local sig = signature(last_lua_queries)
  local stored = load_file()
  local conflict_choice = stored and stored.meta.conflict_choice or "ask"
  save(last_lua_queries, { lua_signature = sig, conflict_choice = conflict_choice })
  apply_to_config(last_lua_queries)
  vim.notify("gh-pr: queries recargadas desde configuración Lua", vim.log.levels.INFO)
end

return M
