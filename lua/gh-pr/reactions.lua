local M = {}

local CATALOG = {
  { content = "THUMBS_UP", emoji = "👍", label = "Thumbs up", short_label = "Up", lane = "common" },
  { content = "HEART", emoji = "❤️", label = "Heart", short_label = "Heart", lane = "common" },
  { content = "HOORAY", emoji = "🎉", label = "Hooray", short_label = "Hooray", lane = "common" },
  { content = "ROCKET", emoji = "🚀", label = "Rocket", short_label = "Rocket", lane = "common" },
  { content = "LAUGH", emoji = "😄", label = "Laugh", short_label = "Laugh", lane = "more" },
  { content = "EYES", emoji = "👀", label = "Eyes", short_label = "Eyes", lane = "more" },
  { content = "THUMBS_DOWN", emoji = "👎", label = "Thumbs down", short_label = "Down", lane = "more" },
  { content = "CONFUSED", emoji = "😕", label = "Confused", short_label = "Confused", lane = "more" },
}

local ORDER = {}
for index, item in ipairs(CATALOG) do
  ORDER[item.content] = index
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function title_case(text)
  local words = {}
  for raw in tostring(text):gmatch("[^%s]+") do
    local lowered = raw:lower()
    words[#words + 1] = lowered:sub(1, 1):upper() .. lowered:sub(2)
  end
  return table.concat(words, " ")
end

local function fallback_entry(content)
  local normalized = safe_string(content, ""):upper()
  local humanized = title_case(normalized:gsub("_", " "))
  return {
    content = normalized,
    emoji = humanized,
    label = humanized,
    short_label = humanized,
    lane = "more",
    unknown = true,
  }
end

local function normalized_marker(opts)
  opts = type(opts) == "table" and opts or {}
  local marker = safe_string(opts.viewer_marker, "*")
  return marker ~= "" and marker or "*"
end

local function render_mode(opts)
  opts = type(opts) == "table" and opts or {}
  if safe_string(opts.render, ""):lower() == "text" then
    return "text"
  end
  return "emoji"
end

function M.catalog()
  return vim.deepcopy(CATALOG)
end

function M.definition(content)
  local normalized = safe_string(content, ""):upper()
  local index = ORDER[normalized]
  if index then
    return vim.deepcopy(CATALOG[index])
  end
  return fallback_entry(normalized)
end

function M.reaction_group_by_content(groups, content)
  local normalized = safe_string(content, ""):upper()
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    if safe_string(type(group) == "table" and group.content or "", ""):upper() == normalized then
      return group
    end
  end
  return nil
end

local function known_and_unknown_groups(groups)
  local known = {}
  local unknown = {}
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    local content = safe_string(type(group) == "table" and group.content or "", ""):upper()
    if content ~= "" then
      if ORDER[content] then
        known[#known + 1] = group
      else
        unknown[#unknown + 1] = group
      end
    end
  end

  table.sort(known, function(left, right)
    return (ORDER[safe_string(left.content, ""):upper()] or math.huge) < (ORDER[safe_string(right.content, ""):upper()] or math.huge)
  end)
  table.sort(unknown, function(left, right)
    return safe_string(left.content, "") < safe_string(right.content, "")
  end)

  return known, unknown
end

local function summary_part(group, opts)
  local content = safe_string(type(group) == "table" and group.content or "", "")
  local total_count = tonumber(type(group) == "table" and group.total_count or 0) or 0
  if content == "" or total_count < 1 then
    return nil
  end

  local entry = M.definition(content)
  local viewer_suffix = type(group) == "table" and group.viewer_has_reacted == true and normalized_marker(opts) or ""
  if render_mode(opts) == "text" then
    return string.format("%s:%d%s", entry.label, total_count, viewer_suffix)
  end

  local prefix = entry.unknown == true and entry.label or entry.emoji
  return string.format("%s %d%s", prefix, total_count, viewer_suffix)
end

function M.render_summary(groups, opts)
  local known, unknown = known_and_unknown_groups(groups)
  local parts = {}

  for _, group in ipairs(known) do
    local part = summary_part(group, opts)
    if part then
      parts[#parts + 1] = part
    end
  end

  for _, group in ipairs(unknown) do
    local part = summary_part(group, opts)
    if part then
      parts[#parts + 1] = part
    end
  end

  return table.concat(parts, "  ")
end

local function picker_entry(definition, group, opts)
  local total_count = tonumber(type(group) == "table" and group.total_count or 0) or 0
  local viewer_has_reacted = type(group) == "table" and group.viewer_has_reacted == true
  local count_text = tostring(total_count)
  if viewer_has_reacted then
    count_text = count_text .. normalized_marker(opts)
  end

  return {
    content = definition.content,
    emoji = definition.emoji,
    label = definition.label,
    short_label = definition.short_label or definition.label,
    lane = definition.lane or "more",
    total_count = total_count,
    viewer_has_reacted = viewer_has_reacted,
    count_text = count_text,
    display = string.format("%s %s %s", definition.emoji, definition.short_label or definition.label, count_text),
  }
end

function M.build_picker_sections(groups, opts)
  opts = type(opts) == "table" and opts or {}
  local only_viewer = opts.only_viewer == true
  local sections = {
    common = {
      title = "Quick reactions",
      items = {},
    },
    more = {
      title = "More reactions",
      items = {},
    },
  }

  for _, definition in ipairs(CATALOG) do
    local group = M.reaction_group_by_content(groups, definition.content)
    local entry = picker_entry(definition, group, opts)
    if not only_viewer or entry.viewer_has_reacted == true then
      sections[entry.lane].items[#sections[entry.lane].items + 1] = entry
    end
  end

  local ordered = {}
  if not vim.tbl_isempty(sections.common.items) then
    ordered[#ordered + 1] = sections.common
  end
  if not vim.tbl_isempty(sections.more.items) then
    ordered[#ordered + 1] = sections.more
  end
  return ordered
end

return M
