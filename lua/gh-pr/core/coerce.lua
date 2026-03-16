local M = {}

function M.safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

function M.positive_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 1 then
    return fallback
  end

  return number
end

function M.non_negative_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 0 then
    return fallback
  end

  return number
end

function M.normalize_line_number(value)
  return M.positive_integer(value, nil)
end

function M.normalize_line_range(start_line, line)
  local start_value = M.normalize_line_number(start_line)
  local line_value = M.normalize_line_number(line)
  if not line_value then
    return nil, nil
  end

  if start_value and start_value > line_value then
    start_value, line_value = line_value, start_value
  end

  if start_value == line_value then
    start_value = nil
  end

  return start_value, line_value
end

return M
