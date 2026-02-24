local M = {}

local function normalize_mode(mode)
  if mode == "compact" or mode == "tree" or mode == "flat" then
    return mode
  end
  return "compact"
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return nil
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
  if normalized == "" then
    return nil
  end

  return normalized
end

local function split_path(path)
  return vim.split(path, "/", { plain = true, trimempty = true })
end

local function new_directory(name, full_path)
  return {
    name = name,
    full_path = full_path or "",
    dirs = {},
    dir_order = {},
    files = {},
  }
end

local function build_index(entries)
  local root = new_directory("", "")

  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    local normalized_path = normalize_path(entry.path)
    if normalized_path then
      local parts = split_path(normalized_path)
      if #parts > 0 then
        local current = root
        local prefix = ""

        for index = 1, (#parts - 1) do
          local segment = parts[index]
          prefix = prefix == "" and segment or (prefix .. "/" .. segment)
          if not current.dirs[segment] then
            current.dirs[segment] = new_directory(segment, prefix)
            current.dir_order[#current.dir_order + 1] = segment
          end
          current = current.dirs[segment]
        end

        current.files[#current.files + 1] = {
          name = parts[#parts],
          path = normalized_path,
          payload = entry.payload ~= nil and entry.payload or entry,
        }
      end
    end
  end

  local function sort_directory(directory)
    table.sort(directory.dir_order)
    table.sort(directory.files, function(left, right)
      if left.path == right.path then
        return left.name < right.name
      end
      return left.path < right.path
    end)

    for _, child_name in ipairs(directory.dir_order) do
      sort_directory(directory.dirs[child_name])
    end
  end

  sort_directory(root)
  return root
end

local function render_file(file_item, callbacks, context)
  if type(callbacks.create_file_node) ~= "function" then
    return {
      id = file_item.path,
      name = file_item.name,
      type = "file",
      path = file_item.path,
    }
  end

  return callbacks.create_file_node(file_item, context)
end

local function render_directory(name, full_path, callbacks, context)
  if type(callbacks.create_directory_node) ~= "function" then
    return {
      id = full_path,
      name = name,
      type = "directory",
      children = {},
    }
  end

  local node = callbacks.create_directory_node(name, full_path, context)
  node.children = type(node.children) == "table" and node.children or {}
  return node
end

local function append_files(parent_list, directory, callbacks, mode)
  for _, file_item in ipairs(directory.files) do
    parent_list[#parent_list + 1] = render_file(file_item, callbacks, {
      mode = mode,
      display_name = file_item.name,
      display_path = file_item.path,
      parent_path = directory.full_path,
    })
  end
end

local function render_tree(directory, callbacks, mode)
  local rendered = {}

  for _, child_name in ipairs(directory.dir_order) do
    local child = directory.dirs[child_name]
    local directory_node = render_directory(child.name, child.full_path, callbacks, {
      mode = mode,
      display_name = child.name,
      full_path = child.full_path,
      compressed = false,
    })
    directory_node.children = render_tree(child, callbacks, mode)
    rendered[#rendered + 1] = directory_node
  end

  append_files(rendered, directory, callbacks, mode)
  return rendered
end

local function compact_chain_start(directory)
  local display_name = directory.name
  local current = directory

  while #current.files == 0 and #current.dir_order == 1 do
    local only_child = current.dirs[current.dir_order[1]]
    display_name = display_name .. "/" .. only_child.name
    current = only_child
  end

  return current, display_name
end

local function render_compact(directory, callbacks, separator)
  local rendered = {}

  for _, child_name in ipairs(directory.dir_order) do
    local child = directory.dirs[child_name]
    local compacted, display_name = compact_chain_start(child)
    local label = (separator ~= nil and separator ~= "/") and display_name:gsub("/", separator) or display_name
    local directory_node = render_directory(label, compacted.full_path, callbacks, {
      mode = "compact",
      display_name = label,
      full_path = compacted.full_path,
      compressed = compacted ~= child,
      original_path = child.full_path,
    })
    directory_node.children = render_compact(compacted, callbacks, separator)
    rendered[#rendered + 1] = directory_node
  end

  append_files(rendered, directory, callbacks, "compact")
  return rendered
end

function M.build_nodes(entries, opts)
  opts = opts or {}
  local mode = normalize_mode(opts.mode)
  local separator = type(opts.separator) == "string" and opts.separator ~= "" and opts.separator or "/"
  local callbacks = {
    create_directory_node = opts.create_directory_node,
    create_file_node = opts.create_file_node,
  }

  if mode == "flat" then
    local root = build_index(entries)
    local files = {}

    local function collect(directory)
      for _, child_name in ipairs(directory.dir_order) do
        collect(directory.dirs[child_name])
      end
      for _, file_item in ipairs(directory.files) do
        files[#files + 1] = file_item
      end
    end

    collect(root)
    table.sort(files, function(left, right)
      return left.path < right.path
    end)

    local nodes = {}
    for _, file_item in ipairs(files) do
      nodes[#nodes + 1] = render_file(file_item, callbacks, {
        mode = "flat",
        display_name = file_item.name,
        display_path = file_item.path,
        parent_path = "",
      })
    end

    return nodes
  end

  local root = build_index(entries)
  if mode == "tree" then
    return render_tree(root, callbacks, "tree")
  end

  return render_compact(root, callbacks, separator)
end

return M
