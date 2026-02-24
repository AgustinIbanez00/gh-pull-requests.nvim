local utils = require("gh-pr.overview_utils")

local M = {}

local warned = {}

local function warn_once(key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  vim.notify(message, vim.log.levels.WARN)
end

local function add_line(payload, text, hl_group)
  payload.lines[#payload.lines + 1] = text
  local line_number = #payload.lines
  if type(hl_group) == "string" and hl_group ~= "" then
    payload.highlights[#payload.highlights + 1] = {
      line = line_number,
      start_col = 0,
      end_col = -1,
      group = hl_group,
    }
  end
  return line_number
end

local function add_span(payload, line_number, start_col, end_col, hl_group)
  if type(hl_group) ~= "string" or hl_group == "" then
    return
  end
  if type(line_number) ~= "number" or line_number < 1 then
    return
  end

  payload.highlights[#payload.highlights + 1] = {
    line = line_number,
    start_col = math.max(0, tonumber(start_col) or 0),
    end_col = tonumber(end_col) or -1,
    group = hl_group,
  }
end

local function apply_inline_highlights(payload, line_number, text)
  local index = 1
  while true do
    local start_pos, end_pos = text:find("`[^`]+`", index)
    if not start_pos then
      break
    end
    add_span(payload, line_number, start_pos - 1, end_pos, "GhPrOverviewMarkdownInlineCode")
    index = end_pos + 1
  end

  index = 1
  while true do
    local start_pos, end_pos = text:find("%[([^%]]+)%]%(([^%)]+)%)", index)
    if not start_pos then
      break
    end
    add_span(payload, line_number, start_pos - 1, end_pos, "GhPrOverviewMarkdownLink")
    index = end_pos + 1
  end
end

local function trim_to_max_lines(payload, max_lines)
  local total = #payload.lines
  if total <= max_lines then
    return payload
  end

  local truncated = {
    lines = {},
    highlights = {},
    truncated = true,
  }

  for index = 1, max_lines do
    truncated.lines[index] = payload.lines[index]
  end

  local hidden_count = total - max_lines + 1
  truncated.lines[max_lines] = string.format("… description truncated (%d more lines)", hidden_count)
  truncated.highlights[#truncated.highlights + 1] = {
    line = max_lines,
    start_col = 0,
    end_col = -1,
    group = "GhPrOverviewMuted",
  }

  for _, highlight in ipairs(payload.highlights) do
    if highlight.line < max_lines then
      truncated.highlights[#truncated.highlights + 1] = highlight
    end
  end

  return truncated
end

local function render_plain(text, opts)
  local payload = {
    lines = utils.split_lines(text),
    highlights = {},
  }

  if vim.tbl_isempty(payload.lines) then
    payload.lines = { "(no pull request description)" }
  end

  return trim_to_max_lines(payload, opts.max_lines)
end

local function render_builtin(text, opts)
  local payload = {
    lines = {},
    highlights = {},
  }

  local input_lines = utils.split_lines(text)
  if vim.tbl_isempty(input_lines) then
    input_lines = { "" }
  end

  local in_code_block = false

  for _, raw_line in ipairs(input_lines) do
    if in_code_block then
      if raw_line:match("^%s*```%s*$") then
        in_code_block = false
        local closing = opts.code_block_border and "└" or "```"
        add_line(payload, closing, "GhPrOverviewMarkdownCodeFence")
      else
        local code_text = opts.code_block_border and ("│ " .. raw_line) or ("    " .. raw_line)
        add_line(payload, code_text, "GhPrOverviewMarkdownCode")
      end
      goto continue
    end

    local fence_language = raw_line:match("^%s*```%s*([^`]*)%s*$")
    if fence_language then
      local language = utils.safe_string(vim.trim(fence_language), "")
      local opening
      if opts.code_block_border then
        opening = language ~= "" and ("┌ code: " .. language) or "┌ code"
      else
        opening = language ~= "" and ("```" .. language) or "```"
      end
      add_line(payload, opening, "GhPrOverviewMarkdownCodeFence")
      in_code_block = true
      goto continue
    end

    if raw_line:match("^%s*[-*_][-%*_][-%*_]+%s*$") then
      add_line(payload, string.rep("─", 48), "GhPrOverviewMarkdownRule")
      goto continue
    end

    local heading_marks, heading_text = raw_line:match("^(#+)%s*(.-)%s*$")
    if heading_marks and #heading_marks <= 6 then
      local heading_line = heading_text ~= "" and heading_text or raw_line
      local heading_no = add_line(payload, heading_line, "GhPrOverviewMarkdownHeading")
      apply_inline_highlights(payload, heading_no, heading_line)
      goto continue
    end

    local quote_text = raw_line:match("^>%s?(.*)$")
    if quote_text then
      local quote_line = "│ " .. quote_text
      local quote_no = add_line(payload, quote_line, "GhPrOverviewMarkdownQuote")
      add_span(payload, quote_no, 0, 1, "GhPrOverviewMarkdownQuoteMarker")
      apply_inline_highlights(payload, quote_no, quote_line)
      goto continue
    end

    local bullet_indent, bullet_text = raw_line:match("^(%s*)[-*+]%s+(.*)$")
    if bullet_text then
      local line_text = bullet_indent .. "• " .. bullet_text
      local line_no = add_line(payload, line_text)
      local marker_col = #bullet_indent
      add_span(payload, line_no, marker_col, marker_col + 1, "GhPrOverviewMarkdownListMarker")
      apply_inline_highlights(payload, line_no, line_text)
      goto continue
    end

    local ordered_indent, ordered_num, ordered_text = raw_line:match("^(%s*)(%d+)%.%s+(.*)$")
    if ordered_text then
      local marker = ordered_num .. "."
      local line_text = ordered_indent .. marker .. " " .. ordered_text
      local line_no = add_line(payload, line_text)
      add_span(payload, line_no, #ordered_indent, #ordered_indent + #marker, "GhPrOverviewMarkdownListMarker")
      apply_inline_highlights(payload, line_no, line_text)
      goto continue
    end

    local line_no = add_line(payload, raw_line)
    apply_inline_highlights(payload, line_no, raw_line)

    ::continue::
  end

  if in_code_block and opts.code_block_border then
    add_line(payload, "└", "GhPrOverviewMarkdownCodeFence")
  end

  return trim_to_max_lines(payload, opts.max_lines)
end

local function module_available(module_name)
  local ok = pcall(require, module_name)
  return ok
end

local function resolve_provider(opts)
  local requested = utils.safe_string(opts.provider, "auto"):lower()

  if requested == "builtin" then
    return "builtin"
  end

  if requested == "render-markdown" then
    if module_available("render-markdown") then
      warn_once(
        "overview-md-render-markdown-adapter",
        "gh-pr: render-markdown.nvim detected, using builtin inline renderer (adapter pending)."
      )
      return "builtin"
    end
    warn_once(
      "overview-md-render-markdown-missing",
      "gh-pr: overview.markdown.provider=render-markdown but plugin is not installed; falling back to builtin."
    )
    return "builtin"
  end

  if requested == "markview" then
    if module_available("markview") then
      warn_once(
        "overview-md-markview-adapter",
        "gh-pr: markview.nvim detected, using builtin inline renderer (adapter pending)."
      )
      return "builtin"
    end
    warn_once(
      "overview-md-markview-missing",
      "gh-pr: overview.markdown.provider=markview but plugin is not installed; falling back to builtin."
    )
    return "builtin"
  end

  if module_available("render-markdown") then
    warn_once(
      "overview-md-auto-render-markdown-adapter",
      "gh-pr: render-markdown.nvim detected, using builtin inline renderer (adapter pending)."
    )
    return "builtin"
  end

  if module_available("markview") then
    warn_once(
      "overview-md-auto-markview-adapter",
      "gh-pr: markview.nvim detected, using builtin inline renderer (adapter pending)."
    )
    return "builtin"
  end

  return "builtin"
end

function M.render(text, options)
  local opts = utils.sanitize_markdown_opts(options)
  local markdown = type(text) == "string" and text or ""

  if markdown == "" then
    return {
      lines = { "(no pull request description)" },
      highlights = {
        {
          line = 1,
          start_col = 0,
          end_col = -1,
          group = "GhPrOverviewMuted",
        },
      },
      provider = "builtin",
    }
  end

  if not opts.enabled then
    local plain = render_plain(markdown, opts)
    plain.provider = "plain"
    return plain
  end

  local provider = resolve_provider(opts)
  local payload = render_builtin(markdown, opts)
  payload.provider = provider
  return payload
end

return M
