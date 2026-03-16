local M = {}

local diff_modes = {
  vertical = true,
  horizontal = true,
  unified = true,
}

local whitespace_modes = {
  none = true,
  trim = true,
  eol = true,
  blank_lines = true,
}

local whitespace_cycle_order = {
  "none",
  "trim",
  "eol",
  "blank_lines",
}

local function canonical_whitespace_mode(mode)
  local normalized = type(mode) == "string" and mode:lower() or ""
  if normalized == "all" then
    return "trim"
  end
  if whitespace_modes[normalized] then
    return normalized
  end
  return nil
end

function M.normalize_mode(mode, fallback)
  if type(mode) == "string" and diff_modes[mode] then
    return mode
  end
  return fallback or "vertical"
end

function M.normalize_whitespace_mode(mode, fallback)
  local normalized = canonical_whitespace_mode(mode)
  if whitespace_modes[normalized] then
    return normalized
  end
  return fallback or "none"
end

function M.resolve_whitespace_mode(mode, legacy_ignore_whitespace, fallback)
  local normalized = canonical_whitespace_mode(mode)
  if whitespace_modes[normalized] then
    return normalized
  end
  if type(legacy_ignore_whitespace) == "boolean" then
    return legacy_ignore_whitespace and "trim" or "none"
  end
  return M.normalize_whitespace_mode(fallback, "none")
end

function M.legacy_ignore_whitespace(mode)
  return M.normalize_whitespace_mode(mode, "none") ~= "none"
end

function M.vim_diff_options(mode)
  local normalized = M.normalize_whitespace_mode(mode, "none")
  if normalized == "trim" then
    return {
      ignore_whitespace_change = true,
    }
  end
  if normalized == "eol" then
    return {
      ignore_whitespace_change_at_eol = true,
    }
  end
  if normalized == "blank_lines" then
    return {
      ignore_blank_lines = true,
    }
  end
  return {}
end

function M.diffopt_candidates(mode)
  local normalized = M.normalize_whitespace_mode(mode, "none")
  if normalized == "trim" then
    return { "iwhite" }
  end
  if normalized == "eol" then
    return { "iwhiteeol" }
  end
  if normalized == "blank_lines" then
    return { "iblank" }
  end
  return {}
end

function M.supports_codediff_text_backend(diff_view)
  diff_view = type(diff_view) == "table" and diff_view or {}
  local mode = M.normalize_mode(diff_view.mode, "vertical")
  local whitespace_mode = M.resolve_whitespace_mode(diff_view.ignore_whitespace_mode, diff_view.ignore_whitespace, "none")
  return (mode == "vertical" or mode == "unified")
    and (whitespace_mode == "none" or whitespace_mode == "trim")
end

function M.cycle_whitespace_mode(mode)
  local current = M.normalize_whitespace_mode(mode, "none")
  local index = 1
  for i, candidate in ipairs(whitespace_cycle_order) do
    if candidate == current then
      index = i
      break
    end
  end
  return whitespace_cycle_order[(index % #whitespace_cycle_order) + 1]
end

function M.whitespace_mode_label(mode)
  local normalized = M.normalize_whitespace_mode(mode, "none")
  if normalized == "trim" then
    return "ignore trim whitespace"
  end
  if normalized == "eol" then
    return "ignore end-of-line whitespace"
  end
  if normalized == "blank_lines" then
    return "ignore blank lines"
  end
  return "strict"
end

return M
