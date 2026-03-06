local M = {}

local loaded_sources = {}

function M.register(source_name, source_module)
  if type(source_name) ~= "string" or source_name == "" then
    return false
  end

  if type(source_module) ~= "table" then
    return false
  end

  loaded_sources[source_name] = source_module
  return true
end

function M.get(source_name)
  if type(source_name) ~= "string" or source_name == "" then
    return nil
  end

  return loaded_sources[source_name]
end

function M.is_loaded(source_name)
  return M.get(source_name) ~= nil
end

function M.call(source_name, method, ...)
  local source = M.get(source_name)
  if type(source) ~= "table" then
    return false, nil
  end

  local handler = source[method]
  if type(handler) ~= "function" then
    return false, nil
  end

  return true, handler(...)
end

return M
