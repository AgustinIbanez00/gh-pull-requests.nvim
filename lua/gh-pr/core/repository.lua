local M = {}

local coerce = require("gh-pr.core.coerce")

local safe_string = coerce.safe_string

function M.parse_full_name(full_name)
  local value = safe_string(full_name)
  if value == "" then
    return nil
  end

  local owner, name = value:match("^([^/]+)/(.+)$")
  if safe_string(owner) == "" or safe_string(name) == "" then
    return nil
  end

  return {
    owner = owner,
    name = name,
    full_name = owner .. "/" .. name,
  }
end

function M.parse(input)
  if type(input) == "string" then
    return M.parse_full_name(input)
  end

  if type(input) ~= "table" then
    return nil
  end

  local parsed = M.parse_full_name(input.full_name or input.nameWithOwner)
  if parsed then
    return parsed
  end

  local owner = type(input.owner) == "table"
      and safe_string(input.owner.login, safe_string(input.owner.name))
    or safe_string(input.owner)
  local name = safe_string(input.name)
  if owner == "" or name == "" then
    return nil
  end

  return {
    owner = owner,
    name = name,
    full_name = owner .. "/" .. name,
  }
end

function M.name_with_owner(input, fallback)
  local parsed = M.parse(input)
  if parsed then
    return parsed.full_name
  end
  return safe_string(fallback)
end

function M.to_api_object(input, name)
  local parsed = nil
  if name ~= nil then
    parsed = M.parse({
      owner = input,
      name = name,
    })
  else
    parsed = M.parse(input)
  end

  if not parsed then
    return nil
  end

  return {
    owner = {
      login = parsed.owner,
    },
    name = parsed.name,
    nameWithOwner = parsed.full_name,
  }
end

return M
