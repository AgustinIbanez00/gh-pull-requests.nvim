local M = {}

local function on_main_loop(callback, value)
  if vim.in_fast_event() then
    vim.schedule(function()
      callback(value)
    end)
    return
  end
  callback(value)
end

local function prompt(text, default, callback)
  callback = type(callback) == "function" and callback or function() end

  if vim.ui and type(vim.ui.input) == "function" then
    vim.ui.input({
      prompt = text,
      default = default or "",
    }, function(value)
      local normalized = type(value) == "string" and value or ""
      on_main_loop(callback, normalized)
    end)
    return
  end

  local value = vim.fn.input(text, default or "")
  callback(value)
end

local function select_query(ctx, callback)
  local current = ctx.get_queries().list()
  if vim.tbl_isempty(current) then
    ctx.notify_error("No queries configured")
    return
  end

  vim.ui.select(current, {
    prompt = "Select query",
    format_item = function(item)
      return string.format("%s / %s", item.folder, item.label)
    end,
  }, function(selected)
    if not selected then
      return
    end

    callback(selected)
  end)
end

function M.add_query(ctx)
  prompt("Folder: ", "General", function(folder)
    if folder == "" then
      return
    end

    prompt("Label: ", "New Query", function(label)
      if label == "" then
        return
      end

      prompt("Query: ", "is:open", function(query)
        if query == "" then
          return
        end

        ctx.get_queries().add({ folder = folder, label = label, query = query })
        ctx.notify_info("Query added")
        ctx.refresh_views()
      end)
    end)
  end)
end

function M.edit_query(ctx)
  select_query(ctx, function(selected)
    prompt("Folder: ", selected.folder, function(folder)
      if folder == "" then
        return
      end

      prompt("Label: ", selected.label, function(label)
        if label == "" then
          return
        end

        prompt("Query: ", selected.query, function(query)
          if query == "" then
            return
          end

          ctx.get_queries().update(selected.id, {
            folder = folder,
            label = label,
            query = query,
          })

          ctx.notify_info("Query updated")
          ctx.refresh_views()
        end)
      end)
    end)
  end)
end

function M.delete_query(ctx)
  select_query(ctx, function(selected)
    local ok = ctx.get_queries().delete(selected.id)
    if ok then
      ctx.notify_info("Query deleted")
      ctx.refresh_views()
    end
  end)
end

return M
