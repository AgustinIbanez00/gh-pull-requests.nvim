local M = {}
local pulls = require("gh-pr.pulls")

local state = { buf = nil, win = nil, nodes = {} }

local function render()
        if not state.buf then
                return
        end
        local lines = {}
        for _, group in ipairs(state.nodes) do
                table.insert(lines, group.text)
                if group.open then
                        for _, pr in ipairs(group.children) do
                                table.insert(lines, pr.text)
                                if pr.open then
                                        for _, file in ipairs(pr.children or {}) do
                                                table.insert(lines, file.text)
                                        end
                                end
                        end
                end
        end
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
end

local function node_at(line)
        local idx = 1
        for _, group in ipairs(state.nodes) do
                if idx == line then
                        return group, nil
                end
                idx = idx + 1
                if group.open then
                        for _, pr in ipairs(group.children) do
                                if idx == line then
                                        return pr, group
                                end
                                idx = idx + 1
                                if pr.open then
                                        for _, file in ipairs(pr.children or {}) do
                                                if idx == line then
                                                        return file, pr
                                                end
                                                idx = idx + 1
                                        end
                                end
                        end
                end
        end
        return nil
end

local function toggle()
        local line = vim.api.nvim_win_get_cursor(state.win)[1]
        local node, parent = node_at(line)
        if not node then
                return
        end
        if node.type == "group" then
                node.open = not node.open
                render()
        elseif node.type == "pr" then
                if node.open then
                        node.open = false
                        node.children = nil
                        render()
                else
                        local details = pulls.fetch_details(node.number)
                        node.details = details
                        node.children = {}
                        for _, f in ipairs(details.files or {}) do
                                table.insert(node.children, { type = "file", text = "    " .. (f.path or f.filename or ""), file = f })
                        end
                        node.open = true
                        render()
                end
        elseif node.type == "file" and parent and parent.details then
                pulls.open_file_diff(parent.details, node.file)
        end
end

local function close()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                vim.api.nvim_win_close(state.win, true)
        end
        state.win = nil
        state.buf = nil
        state.nodes = {}
end

function M.open()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                vim.api.nvim_set_current_win(state.win)
                return
        end
        vim.cmd("topleft vsplit")
        state.win = vim.api.nvim_get_current_win()
        state.buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(state.win, state.buf)
        vim.api.nvim_win_set_width(state.win, 40)
        vim.bo[state.buf].buftype = "nofile"
        vim.bo[state.buf].bufhidden = "wipe"
        vim.bo[state.buf].swapfile = false
        vim.bo[state.buf].filetype = "ghprtree"
        state.nodes = {
                { type = "group", text = "Assigned", open = false, children = {} },
                { type = "group", text = "All", open = false, children = {} },
        }
        for _, pr in ipairs(pulls.fetch_assigned()) do
                table.insert(state.nodes[1].children, { type = "pr", number = pr.number, pr = pr, text = string.format("  #%d %s", pr.number, pr.title) })
        end
        for _, pr in ipairs(pulls.fetch_all()) do
                table.insert(state.nodes[2].children, { type = "pr", number = pr.number, pr = pr, text = string.format("  #%d %s", pr.number, pr.title) })
        end
        render()
        vim.keymap.set("n", "<CR>", toggle, { buffer = state.buf })
        vim.keymap.set("n", "q", close, { buffer = state.buf })
end

return M
