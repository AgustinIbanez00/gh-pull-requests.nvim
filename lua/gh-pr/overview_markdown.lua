local utils = require("gh-pr.overview_utils")

local M = {}

local warned = {}
local module_cache = {}

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

local function render_inline_markup(text)
  local source = type(text) == "string" and text or ""
  local rendered = {}
  local spans = {}
  local links = {}
  local cursor = 1

  while cursor <= #source do
    local code_start, code_end = source:find("`[^`]+`", cursor)
    local link_start, link_end, link_label, link_url = source:find("%[([^%]]+)%]%(([^%)]+)%)", cursor)

    local kind = nil
    local token_start = nil
    local token_end = nil
    if code_start and (not link_start or code_start <= link_start) then
      kind = "code"
      token_start = code_start
      token_end = code_end
    elseif link_start then
      kind = "link"
      token_start = link_start
      token_end = link_end
    end

    if not kind then
      rendered[#rendered + 1] = source:sub(cursor)
      break
    end

    if token_start > cursor then
      rendered[#rendered + 1] = source:sub(cursor, token_start - 1)
    end

    local rendered_text = table.concat(rendered)
    if kind == "code" then
      local chunk = source:sub(token_start, token_end)
      local start_col = #rendered_text
      rendered[#rendered + 1] = chunk
      spans[#spans + 1] = {
        start_col = start_col,
        end_col = start_col + #chunk,
        group = "GhPrOverviewMarkdownInlineCode",
      }
    else
      local label = type(link_label) == "string" and link_label or ""
      local url = type(link_url) == "string" and vim.trim(link_url) or ""
      if label == "" then
        label = url
      end
      if label == "" then
        label = source:sub(token_start, token_end)
      end

      local start_col = #rendered_text
      rendered[#rendered + 1] = label
      spans[#spans + 1] = {
        start_col = start_col,
        end_col = start_col + #label,
        group = "GhPrOverviewMarkdownLink",
      }
      if url ~= "" then
        links[#links + 1] = {
          start_col = start_col,
          end_col = start_col + #label,
          label = label,
          url = url,
        }
      end
    end

    cursor = token_end + 1
  end

  return table.concat(rendered), spans, links
end

local function apply_inline_markup(payload, line_number, spans, links)
  for _, span in ipairs(type(spans) == "table" and spans or {}) do
    add_span(payload, line_number, span.start_col, span.end_col, span.group)
  end
  for _, link in ipairs(type(links) == "table" and links or {}) do
    payload.links[#payload.links + 1] = {
      line = line_number,
      start_col = tonumber(link.start_col) or 0,
      end_col = tonumber(link.end_col) or 0,
      label = type(link.label) == "string" and link.label or "",
      url = type(link.url) == "string" and link.url or "",
    }
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
    links = {},
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

  for _, link in ipairs(payload.links or {}) do
    if link.line < max_lines then
      truncated.links[#truncated.links + 1] = link
    end
  end

  return truncated
end

local function render_plain(text, opts)
  local payload = {
    lines = utils.split_lines(text),
    highlights = {},
    links = {},
  }

  if vim.tbl_isempty(payload.lines) then
    payload.lines = { "(no pull request description)" }
  end

  return trim_to_max_lines(payload, opts.max_lines)
end

local function collect_raw_links(payload)
  for line_number, text in ipairs(payload.lines or {}) do
    local source = type(text) == "string" and text or ""
    local cursor = 1
    while cursor <= #source do
      local start_idx, end_idx, label, url = source:find("%[([^%]]+)%]%(([^%)]+)%)", cursor)
      if not start_idx then
        break
      end

      local cleaned_url = type(url) == "string" and vim.trim(url) or ""
      if cleaned_url ~= "" then
        payload.links[#payload.links + 1] = {
          line = line_number,
          start_col = start_idx - 1,
          end_col = end_idx,
          label = type(label) == "string" and label or cleaned_url,
          url = cleaned_url,
        }
      end

      cursor = end_idx + 1
    end
  end
end

local function render_full_markdown(text, opts)
  local payload = {
    lines = utils.split_lines(text),
    highlights = {},
    links = {},
  }

  if vim.tbl_isempty(payload.lines) then
    payload.lines = { "(no pull request description)" }
  end

  payload = trim_to_max_lines(payload, opts.max_lines)
  collect_raw_links(payload)
  return payload
end

local function render_builtin(text, opts)
  local payload = {
    lines = {},
    highlights = {},
    links = {},
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
      local rendered_heading, heading_spans, heading_links = render_inline_markup(heading_line)
      local heading_no = add_line(payload, rendered_heading, "GhPrOverviewMarkdownHeading")
      apply_inline_markup(payload, heading_no, heading_spans, heading_links)
      goto continue
    end

    local quote_text = raw_line:match("^>%s?(.*)$")
    if quote_text then
      local quote_line = "│ " .. quote_text
      local rendered_quote, quote_spans, quote_links = render_inline_markup(quote_line)
      local quote_no = add_line(payload, rendered_quote, "GhPrOverviewMarkdownQuote")
      add_span(payload, quote_no, 0, 1, "GhPrOverviewMarkdownQuoteMarker")
      apply_inline_markup(payload, quote_no, quote_spans, quote_links)
      goto continue
    end

    local bullet_indent, bullet_text = raw_line:match("^(%s*)[-*+]%s+(.*)$")
    if bullet_text then
      local line_text = bullet_indent .. "• " .. bullet_text
      local rendered_line, line_spans, line_links = render_inline_markup(line_text)
      local line_no = add_line(payload, rendered_line)
      local marker_col = #bullet_indent
      add_span(payload, line_no, marker_col, marker_col + 1, "GhPrOverviewMarkdownListMarker")
      apply_inline_markup(payload, line_no, line_spans, line_links)
      goto continue
    end

    local ordered_indent, ordered_num, ordered_text = raw_line:match("^(%s*)(%d+)%.%s+(.*)$")
    if ordered_text then
      local marker = ordered_num .. "."
      local line_text = ordered_indent .. marker .. " " .. ordered_text
      local rendered_line, line_spans, line_links = render_inline_markup(line_text)
      local line_no = add_line(payload, rendered_line)
      add_span(payload, line_no, #ordered_indent, #ordered_indent + #marker, "GhPrOverviewMarkdownListMarker")
      apply_inline_markup(payload, line_no, line_spans, line_links)
      goto continue
    end

    local rendered_line, line_spans, line_links = render_inline_markup(raw_line)
    local line_no = add_line(payload, rendered_line)
    apply_inline_markup(payload, line_no, line_spans, line_links)

    ::continue::
  end

  if in_code_block and opts.code_block_border then
    add_line(payload, "└", "GhPrOverviewMarkdownCodeFence")
  end

  return trim_to_max_lines(payload, opts.max_lines)
end

local function module_available(module_name)
  if module_cache[module_name] ~= nil then
    return module_cache[module_name] == true
  end

  local ok = pcall(require, module_name)
  module_cache[module_name] = ok == true
  return ok == true
end

local function resolve_provider(opts)
  local requested = utils.safe_string(opts.provider, "render-markdown"):lower()

  if requested == "builtin" then
    return "builtin"
  end

  if module_available("render-markdown") then
    return "render-markdown"
  end

  warn_once(
    "overview-md-render-markdown-missing",
    "gh-pr: missing required dependency render-markdown.nvim; falling back to builtin markdown renderer."
  )

  return "builtin"
end

function M.resolve_provider(options)
  local opts = utils.sanitize_markdown_opts(options)
  return resolve_provider(opts)
end

local function render_external_provider(text, opts, provider)
  local ok, payload = pcall(render_full_markdown, text, opts)
  if not ok or type(payload) ~= "table" then
    warn_once(
      "overview-md-external-provider-fallback",
      string.format("gh-pr: %s renderer failed; falling back to builtin.", provider)
    )
    local fallback = render_builtin(text, opts)
    fallback.provider = "builtin"
    return fallback
  end

  payload.provider = provider
  payload.markdown_block = true
  return payload
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
      links = {},
      provider = opts.mode == "full" and "full" or "builtin",
    }
  end

  if not opts.enabled then
    local plain = render_plain(markdown, opts)
    plain.provider = "plain"
    plain.links = {}
    return plain
  end

  if opts.mode == "full" then
    local payload = render_full_markdown(markdown, opts)
    payload.provider = "full"
    return payload
  end

  local provider = resolve_provider(opts)
  if provider == "render-markdown" then
    return render_external_provider(markdown, opts, provider)
  end

  local builtin_payload = render_builtin(markdown, opts)
  builtin_payload.provider = "builtin"
  return builtin_payload
end

return M
