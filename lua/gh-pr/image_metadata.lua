local M = {}

local uv = vim.uv or vim.loop
local bit_lib = bit or bit32

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

local function file_size(path)
  if type(path) ~= "string" or path == "" then
    return 0
  end
  local stat = uv.fs_stat(path)
  return type(stat) == "table" and tonumber(stat.size) or 0
end

local function read_bytes(path, max_bytes)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end

  local size = file_size(path)
  local limit = tonumber(max_bytes) or size
  if limit < 1 then
    limit = size
  end
  if size > 0 then
    limit = math.min(size, limit)
  end

  local data = uv.fs_read(fd, limit, 0)
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil
  end
  return data
end

local function be16(bytes, index)
  local b1, b2 = bytes:byte(index, index + 1)
  if not b1 or not b2 then
    return nil
  end
  return b1 * 256 + b2
end

local function be32(bytes, index)
  local b1, b2, b3, b4 = bytes:byte(index, index + 3)
  if not b1 or not b2 or not b3 or not b4 then
    return nil
  end
  return (((b1 * 256 + b2) * 256 + b3) * 256 + b4)
end

local function le16(bytes, index)
  local b1, b2 = bytes:byte(index, index + 1)
  if not b1 or not b2 then
    return nil
  end
  return b1 + b2 * 256
end

local function le24(bytes, index)
  local b1, b2, b3 = bytes:byte(index, index + 2)
  if not b1 or not b2 or not b3 then
    return nil
  end
  return b1 + b2 * 256 + b3 * 65536
end

local function le32(bytes, index)
  local b1, b2, b3, b4 = bytes:byte(index, index + 3)
  if not b1 or not b2 or not b3 or not b4 then
    return nil
  end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function parse_png(bytes)
  if type(bytes) ~= "string" or #bytes < 24 then
    return nil, nil
  end
  if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    return nil, nil
  end

  local width = be32(bytes, 17)
  local height = be32(bytes, 21)
  return width, height
end

local function parse_gif(bytes)
  if type(bytes) ~= "string" or #bytes < 10 then
    return nil, nil
  end
  local signature = bytes:sub(1, 6)
  if signature ~= "GIF87a" and signature ~= "GIF89a" then
    return nil, nil
  end

  local width = le16(bytes, 7)
  local height = le16(bytes, 9)
  return width, height
end

local function parse_bmp(bytes)
  if type(bytes) ~= "string" or #bytes < 26 then
    return nil, nil
  end
  if bytes:sub(1, 2) ~= "BM" then
    return nil, nil
  end

  local width = le32(bytes, 19)
  local height = le32(bytes, 23)
  if height and height < 0 then
    height = -height
  end
  return width, height
end

local function parse_jpeg(bytes)
  if type(bytes) ~= "string" or #bytes < 4 then
    return nil, nil
  end
  if bytes:byte(1) ~= 0xFF or bytes:byte(2) ~= 0xD8 then
    return nil, nil
  end

  local index = 3
  while index < #bytes do
    if bytes:byte(index) ~= 0xFF then
      index = index + 1
    else
      local marker = bytes:byte(index + 1)
      if not marker then
        break
      end
      if marker == 0xD9 or marker == 0xDA then
        break
      end
      local segment_len = be16(bytes, index + 2)
      if not segment_len or segment_len < 2 then
        break
      end

      local is_sof = marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
      if is_sof then
        local height = be16(bytes, index + 5)
        local width = be16(bytes, index + 7)
        return width, height
      end

      index = index + 2 + segment_len
    end
  end

  return nil, nil
end

local function parse_webp(bytes)
  if type(bytes) ~= "string" or #bytes < 30 then
    return nil, nil
  end
  if bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WEBP" then
    return nil, nil
  end

  local chunk = bytes:sub(13, 16)
  if chunk == "VP8X" then
    local width = le24(bytes, 25)
    local height = le24(bytes, 28)
    if width and height then
      return width + 1, height + 1
    end
  elseif chunk == "VP8 " then
    local start_code = bytes:sub(24, 26)
    if start_code == "\157\001\042" then
      local raw_width = le16(bytes, 27)
      local raw_height = le16(bytes, 29)
      if raw_width and raw_height then
        if bit_lib then
          return bit_lib.band(raw_width, 0x3FFF), bit_lib.band(raw_height, 0x3FFF)
        end
        return raw_width % 16384, raw_height % 16384
      end
    end
  elseif chunk == "VP8L" then
    if bytes:byte(21) == 0x2F then
      local b1, b2, b3, b4 = bytes:byte(22, 25)
      if b1 and b2 and b3 and b4 and bit_lib then
        local width = 1 + bit_lib.band(b1 + bit_lib.lshift(bit_lib.band(b2, 0x3F), 8), 0x3FFF)
        local height = 1
          + bit_lib.band(
            bit_lib.rshift(b2, 6) + bit_lib.lshift(b3, 2) + bit_lib.lshift(bit_lib.band(b4, 0x0F), 10),
            0x3FFF
          )
        return width, height
      end
    end
  end

  return nil, nil
end

local function parse_dimension_token(value)
  if type(value) ~= "string" then
    return nil
  end
  local number = value:match("^%s*([%d%.]+)")
  if not number then
    return nil
  end
  local parsed = tonumber(number)
  if not parsed then
    return nil
  end
  return math.floor(parsed + 0.5)
end

local function parse_svg(bytes)
  if type(bytes) ~= "string" or bytes == "" then
    return nil, nil
  end
  local open_tag = bytes:match("<svg%s+.-%>")
  if not open_tag then
    return nil, nil
  end

  local width_attr = open_tag:match('width%s*=%s*"([^"]+)"') or open_tag:match("width%s*=%s*'([^']+)'")
  local height_attr = open_tag:match('height%s*=%s*"([^"]+)"') or open_tag:match("height%s*=%s*'([^']+)'")
  local width = parse_dimension_token(width_attr)
  local height = parse_dimension_token(height_attr)
  if width and height then
    return width, height
  end

  local view_box = open_tag:match('viewBox%s*=%s*"([^"]+)"') or open_tag:match("viewBox%s*=%s*'([^']+)'")
  if type(view_box) == "string" then
    local min_x, min_y, vb_width, vb_height = view_box:match("([%-%d%.]+)[, ]+([%-%d%.]+)[, ]+([%-%d%.]+)[, ]+([%-%d%.]+)")
    local parsed_width = tonumber(vb_width)
    local parsed_height = tonumber(vb_height)
    if parsed_width and parsed_height then
      return math.floor(parsed_width + 0.5), math.floor(parsed_height + 0.5)
    end
  end

  return nil, nil
end

local function parse_resolution_internal(ext, bytes)
  if ext == "png" then
    return parse_png(bytes)
  end
  if ext == "jpg" or ext == "jpeg" then
    return parse_jpeg(bytes)
  end
  if ext == "gif" then
    return parse_gif(bytes)
  end
  if ext == "webp" then
    return parse_webp(bytes)
  end
  if ext == "bmp" then
    return parse_bmp(bytes)
  end
  if ext == "svg" then
    return parse_svg(bytes)
  end
  return nil, nil
end

local function resolve_external_command(template, path)
  if type(template) ~= "table" or vim.tbl_isempty(template) then
    return nil
  end

  local command = {}
  for _, token in ipairs(template) do
    if type(token) == "string" and token ~= "" then
      if token == "{file}" then
        command[#command + 1] = path
      else
        command[#command + 1] = token:gsub("{file}", path)
      end
    end
  end

  if vim.tbl_isempty(command) then
    return nil
  end
  return command
end

local function parse_resolution_external(path, command_template)
  local command = resolve_external_command(command_template, path)
  if not command then
    return nil, nil
  end

  if not vim.system then
    return nil, nil
  end

  local ok_run, result = pcall(function()
    return vim.system(command, { text = true }):wait(10000)
  end)
  if not ok_run or type(result) ~= "table" or tonumber(result.code) ~= 0 then
    return nil, nil
  end

  local output = type(result.stdout) == "string" and vim.trim(result.stdout) or ""
  if output == "" then
    return nil, nil
  end

  local width, height = output:match("(%d+)%s+(%d+)")
  if not width or not height then
    width, height = output:match("(%d+)%s*x%s*(%d+)")
  end
  if not width or not height then
    return nil, nil
  end

  return tonumber(width), tonumber(height)
end

local function resolution_label(width, height)
  if tonumber(width) and tonumber(height) and width > 0 and height > 0 then
    return string.format("%dx%d", width, height)
  end
  return "unknown"
end

function M.collect(opts)
  opts = type(opts) == "table" and opts or {}

  local path = type(opts.path) == "string" and opts.path or ""
  local ext = type(opts.ext) == "string" and opts.ext:lower() or extension(path)
  local strategy = type(opts.strategy) == "string" and opts.strategy:lower() or "hybrid"
  local size_bytes = tonumber(opts.size_bytes) or file_size(path)
  local sha = type(opts.sha) == "string" and opts.sha or ""
  local bytes = nil
  local width, height

  if strategy ~= "external" then
    bytes = read_bytes(path, ext == "svg" and 262144 or 65536)
    width, height = parse_resolution_internal(ext, bytes)
  end

  if (not width or not height) and (strategy == "external" or strategy == "hybrid") then
    width, height = parse_resolution_external(path, opts.external_command)
  end

  return {
    path = path,
    ext = ext,
    sha = sha,
    size_bytes = size_bytes,
    size_human = format_bytes(size_bytes),
    width = width,
    height = height,
    resolution = resolution_label(width, height),
  }
end

function M.format_bytes(size)
  return format_bytes(size)
end

return M
