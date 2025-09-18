local M = {}
local pulls = require("gh-pr.pulls")

local tree_namespace = vim.api.nvim_create_namespace("gh-pr-tree")
local comment_namespace = vim.api.nvim_create_namespace("gh-pr-comments")

local state = {
        buf = nil,
        win = nil,
        nodes = {},
        namespace = tree_namespace,
        current_pr = nil,
        comments = {
                win = nil,
                buf = nil,
                nodes = {},
                namespace = comment_namespace,
                pr = nil,
                mapped = false,
                autocmd = nil,
                min_height = 4,
                max_height = 12,
                default_height = 10,
        },
}

local status_info = {
        added = { icon = "+", highlight = "GhPRFileAdded" },
        modified = { icon = "~", highlight = "GhPRFileModified" },
        changed = { icon = "~", highlight = "GhPRFileModified" },
        removed = { icon = "-", highlight = "GhPRFileRemoved" },
        deleted = { icon = "-", highlight = "GhPRFileRemoved" },
        renamed = { icon = ">", highlight = "GhPRFileRenamed" },
}

local highlights_defined = false

local function color_to_hex(value)
        if type(value) == "number" then
                return string.format("#%06x", value)
        end
        return value
end

local function copy_highlight(name)
        local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        if not ok or not hl then
                return {}
        end
        local result = {}
        for key, value in pairs(hl) do
                if key == "fg" or key == "bg" or key == "sp" then
                        result[key] = color_to_hex(value)
                else
                        result[key] = value
                end
        end
        return result
end

local function define_highlights()
        if highlights_defined then
                return
        end
        highlights_defined = true
        local function set_default(name, opts)
                local ok, err = pcall(vim.api.nvim_set_hl, 0, name, opts)
                if not ok then
                        vim.schedule(function()
                                vim.notify(string.format("gh-pr failed to set highlight %s: %s", name, err), vim.log.levels.WARN)
                        end)
                end
        end
        set_default("GhPRFileAdded", { link = "DiffAdd" })
        set_default("GhPRFileModified", { link = "DiffChange" })
        set_default("GhPRFileRenamed", { link = "DiffChange" })
        local removed = copy_highlight("DiffDelete")
        if vim.tbl_isempty(removed) then
                removed = { fg = "#ff6c6b" }
        end
        removed.strikethrough = true
        set_default("GhPRFileRemoved", removed)
        set_default("GhPRCommentUnresolved", { link = "DiagnosticWarn" })
end

local function pr_text(pr)
        local repo = pr.repository and pr.repository.full_name or ""
        local identifier = string.format("#%d", pr.number)
        if repo ~= "" then
                identifier = string.format("%s %s", repo, identifier)
        end
        local decision = pr.reviewDecision or "UNKNOWN"
        return string.format("  %s %s [%s]", identifier, pr.title, decision)
end

local function normalize_value(value)
        if value == vim.NIL then
                return nil
        end
        return value
end

local function normalize_number(value)
        value = normalize_value(value)
        if value == nil then
                return nil
        end
        return tonumber(value)
end

local function normalize_string(value)
        value = normalize_value(value)
        if type(value) == "string" then
                return value
        end
        return nil
end

local function author_name(author)
        author = normalize_value(author)
        if type(author) == "string" then
                return author
        end
        if type(author) == "table" then
                return author.login or author.name or author.userLogin or author.slug or author.username or author.displayName or "unknown"
        end
        return "unknown"
end

local function format_comment_summary(text)
        text = normalize_string(text) or ""
        text = text:gsub("\r", "")
        local first_line = text:match("^[^\n]*") or ""
        first_line = vim.trim(first_line)
        if first_line == "" then
                first_line = "[no comment text]"
        end
        local max_chars = 80
        if vim.fn.strchars(first_line) > max_chars then
                first_line = vim.fn.strcharpart(first_line, 0, max_chars - 1) .. "…"
        end
        return first_line
end

local function comment_sort(a, b)
        local la = a.line or math.huge
        local lb = b.line or math.huge
        if la ~= lb then
                return la < lb
        end
        local ta = normalize_string(a.comment and a.comment.createdAt) or ""
        local tb = normalize_string(b.comment and b.comment.createdAt) or ""
        return ta < tb
end

local function build_comment_data(details)
        local nodes = {}
        local counts = {}
        if type(details) ~= "table" then
                return nodes, counts
        end
        local grouped = {}
        local function ensure_group(path)
                path = path or ""
                local key = path ~= "" and path or "__general__"
                local group = grouped[key]
                if not group then
                        local display = path ~= "" and path or "General Comments"
                        group = {
                                type = "comment_group",
                                key = key,
                                path = path,
                                display = display,
                                text = "",
                                children = {},
                                open = true,
                                count = 0,
                                unresolved = 0,
                        }
                        grouped[key] = group
                        table.insert(nodes, group)
                end
                return group
        end
        local function ensure_count(path)
                path = path or ""
                if path == "" then
                        return nil
                end
                local entry = counts[path]
                if not entry then
                        entry = { total = 0, unresolved = 0 }
                        counts[path] = entry
                end
                return entry
        end
        for _, thread in ipairs(details.reviewThreads or {}) do
                if type(thread) == "table" then
                        local path = normalize_string(thread.path) or ""
                        local group = ensure_group(path)
                        local unresolved = thread.isResolved == false or thread.resolved == false
                        local thread_outdated = thread.isOutdated == true
                        local per_path = ensure_count(path)
                        local comments = thread.comments or {}
                        local thread_has_comments = false
                        for _, comment in ipairs(comments) do
                                if type(comment) == "table" then
                                        local body = comment.body or comment.bodyText or ""
                                        if body == vim.NIL then
                                                body = ""
                                        end
                                        local summary = format_comment_summary(body)
                                        local author = author_name(comment.author)
                                        local start_line = normalize_number(comment.startLine) or normalize_number(comment.originalStartLine)
                                        local end_line = normalize_number(comment.line) or normalize_number(comment.originalLine)
                                        local position = normalize_number(comment.position)
                                        local line = start_line or end_line or position
                                        local range_start = start_line or end_line
                                        local range_finish = end_line or start_line
                                        if range_start and range_finish and range_start > range_finish then
                                                range_start, range_finish = range_finish, range_start
                                        end
                                        local range
                                        if range_start and range_finish then
                                                range = { start = range_start, finish = range_finish }
                                        end
                                        local side = normalize_string(comment.diffSide) or normalize_string(comment.startDiffSide)
                                        if side then
                                                side = string.upper(side)
                                        elseif path ~= "" then
                                                if normalize_number(comment.originalLine) and not normalize_number(comment.line) then
                                                        side = "LEFT"
                                                elseif line then
                                                        side = "RIGHT"
                                                end
                                        end
                                        local outdated = comment.outdated == true or comment.isOutdated == true or thread_outdated
                                        local flags = {}
                                        if unresolved and path ~= "" then
                                                table.insert(flags, "unresolved")
                                        end
                                        if outdated then
                                                table.insert(flags, "outdated")
                                        end
                                        local suffix = ""
                                        if #flags > 0 then
                                                suffix = string.format(" [%s]", table.concat(flags, ", "))
                                        end
                                        local location = line and string.format("L%s", line) or "•"
                                        local text = string.format("    %-8s %s — %s%s", location, summary, author, suffix)
                                        local comment_node = {
                                                type = "comment",
                                                text = text,
                                                comment = comment,
                                                thread = thread,
                                                path = path,
                                                line = line,
                                                side = path ~= "" and side or nil,
                                                range = range,
                                                author = author,
                                                highlight = (unresolved and path ~= "") and "GhPRCommentUnresolved" or nil,
                                        }
                                        comment_node.start_line = range_start
                                        comment_node.end_line = range_finish
                                        comment_node.flags = flags
                                        table.insert(group.children, comment_node)
                                        group.count = group.count + 1
                                        thread_has_comments = true
                                        if per_path then
                                                per_path.total = per_path.total + 1
                                        end
                                end
                        end
                        if thread_has_comments then
                                if per_path and unresolved then
                                        per_path.unresolved = per_path.unresolved + 1
                                end
                                if unresolved and path ~= "" then
                                        group.unresolved = (group.unresolved or 0) + 1
                                end
                        end
                end
        end
        for _, comment in ipairs(details.comments or {}) do
                if type(comment) == "table" then
                        local body = normalize_string(comment.body or comment.bodyText) or ""
                        local summary = format_comment_summary(body)
                        local author = author_name(comment.author)
                        local group = ensure_group("")
                        local text = string.format("    %-8s %s — %s", "•", summary, author)
                        local node = {
                                type = "comment",
                                text = text,
                                comment = comment,
                                path = "",
                                author = author,
                                line = nil,
                                side = nil,
                                range = nil,
                        }
                        node.created_at = normalize_string(comment.createdAt)
                        table.insert(group.children, node)
                        group.count = group.count + 1
                end
        end
        for i = #nodes, 1, -1 do
                if (nodes[i].count or 0) == 0 then
                        table.remove(nodes, i)
                end
        end
        for _, group in ipairs(nodes) do
                table.sort(group.children, comment_sort)
                local suffix = ""
                if (group.unresolved or 0) > 0 then
                        suffix = string.format(" !%d", group.unresolved)
                end
                group.text = string.format("  %s (%d%s)", group.display, group.count, suffix)
        end
        table.sort(nodes, function(a, b)
                if a.key == b.key then
                        return false
                end
                if a.key == "__general__" then
                        return false
                end
                if b.key == "__general__" then
                        return true
                end
                return a.key:lower() < b.key:lower()
        end)
        return nodes, counts
end

local function combine_count(path, file, counts)
        path = normalize_string(path) or ""
        if path == "" then
                return nil
        end
        counts = counts or {}
        local total = 0
        local unresolved = 0
        local entry = counts[path]
        if entry then
                total = total + (entry.total or 0)
                unresolved = unresolved + (entry.unresolved or 0)
        end
        local previous = file and normalize_string(file.previousFilename)
        if previous and previous ~= "" and previous ~= path then
                local prev_entry = counts[previous]
                if prev_entry then
                        total = total + (prev_entry.total or 0)
                        unresolved = unresolved + (prev_entry.unresolved or 0)
                end
        end
        if total == 0 and unresolved == 0 then
                return nil
        end
        return { total = total, unresolved = unresolved }
end

local function format_file_text(file, path, previous, count_info)
        local status = normalize_string(file.status) or "modified"
        status = status:lower()
        if status_info[status] == nil then
                status = "modified"
        end
        if status == "deleted" then
                status = "removed"
        end
        local info = status_info[status] or status_info.modified
        local display_path = path
        if status == "renamed" and previous and previous ~= "" and previous ~= path then
                display_path = string.format("%s → %s", previous, path)
        end
        local suffix = ""
        if count_info then
                suffix = string.format(" [%d", count_info.total or 0)
                if (count_info.unresolved or 0) > 0 then
                        suffix = string.format("%s !%d", suffix, count_info.unresolved)
                end
                suffix = suffix .. "]"
        end
        local text = string.format("    %s %s%s", info.icon or "~", display_path, suffix)
        return text, info.highlight
end

local function build_file_nodes(pr_node, details, comment_counts)
        pr_node.files_by_path = {}
        local nodes = {}
        for _, f in ipairs(details.files or {}) do
                if type(f) == "table" then
                        local path = normalize_string(f.path) or normalize_string(f.filename) or ""
                        local previous = normalize_string(f.previousFilename)
                        local count_info = combine_count(path, f, comment_counts)
                        local text, highlight = format_file_text(f, path, previous, count_info)
                        local node = {
                                type = "file",
                                text = text,
                                file = f,
                                path = path,
                                highlight = highlight,
                                highlight_range = { col_start = 0, col_end = -1 },
                                comment_count = count_info,
                        }
                        table.insert(nodes, node)
                        if path ~= "" then
                                pr_node.files_by_path[path] = f
                        end
                        if previous and previous ~= "" then
                                pr_node.files_by_path[previous] = f
                        end
                end
        end
        table.sort(nodes, function(a, b)
                return (a.path or "") < (b.path or "")
        end)
        return nodes
end

local function refresh_file_comment_annotations(pr_node)
        if not (pr_node and pr_node.children) then
                return
        end
        local counts = pr_node.comment_counts or {}
        for _, file_node in ipairs(pr_node.children) do
                        local path = file_node.path or ""
                        local previous = file_node.file and normalize_string(file_node.file.previousFilename)
                        local count_info = combine_count(path, file_node.file, counts)
                        local text, highlight = format_file_text(file_node.file, path, previous, count_info)
                        file_node.text = text
                        file_node.highlight = highlight
                        file_node.comment_count = count_info
        end
end

local function render()
        if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
                return
        end
        local lines = {}
        local highlights = {}
        local line_nr = 0
        local function add_line(text, highlight, range)
                line_nr = line_nr + 1
                lines[line_nr] = text
                if highlight then
                        table.insert(highlights, {
                                line = line_nr - 1,
                                group = highlight,
                                col_start = range and range.col_start or 0,
                                col_end = range and range.col_end or -1,
                        })
                end
        end
        if vim.tbl_isempty(state.nodes) then
                add_line("No pull requests found")
        else
                for _, group in ipairs(state.nodes) do
                        add_line(group.text, group.highlight, group.highlight_range)
                        if group.open then
                                for _, pr in ipairs(group.children or {}) do
                                        add_line(pr.text, pr.highlight, pr.highlight_range)
                                        if pr.open and pr.children then
                                                for _, file in ipairs(pr.children) do
                                                        add_line(file.text, file.highlight, file.highlight_range)
                                                end
                                        end
                                end
                        end
                end
        end
        vim.api.nvim_buf_set_option(state.buf, "modifiable", true)
        vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(state.buf, state.namespace, 0, -1)
        for _, hl in ipairs(highlights) do
                local col_end = hl.col_end
                if col_end ~= -1 then
                        local text = lines[hl.line + 1] or ""
                        col_end = math.min(col_end, #text)
                end
                vim.api.nvim_buf_add_highlight(state.buf, state.namespace, hl.group, hl.line, hl.col_start or 0, col_end or -1)
        end
end

local function node_at(line)
        local idx = 1
        for _, group in ipairs(state.nodes) do
                if idx == line then
                        return group, nil
                end
                idx = idx + 1
                if group.open then
                        for _, pr in ipairs(group.children or {}) do
                                if idx == line then
                                        return pr, group
                                end
                                idx = idx + 1
                                if pr.open and pr.children then
                                        for _, file in ipairs(pr.children) do
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

local function comment_node_at(line)
        local idx = 1
        for _, group in ipairs(state.comments.nodes or {}) do
                if idx == line then
                        return group, nil
                end
                idx = idx + 1
                if group.open ~= false then
                        for _, comment in ipairs(group.children or {}) do
                                if idx == line then
                                        return comment, group
                                end
                                idx = idx + 1
                        end
                end
        end
        return nil
end

local function render_comments()
        local buf = state.comments.buf
        if not (buf and vim.api.nvim_buf_is_valid(buf)) then
                return
        end
        local lines = {}
        local highlights = {}
        local line_nr = 0
        local function add_line(text, highlight)
                line_nr = line_nr + 1
                lines[line_nr] = text
                if highlight then
                        table.insert(highlights, { line = line_nr - 1, group = highlight })
                end
        end
        local pr_node = state.comments.pr
        if not pr_node then
                add_line("Select a pull request to view review comments")
        elseif vim.tbl_isempty(state.comments.nodes) then
                add_line("No review comments")
        else
                for _, group in ipairs(state.comments.nodes) do
                        add_line(group.text)
                        if group.open ~= false then
                                for _, comment in ipairs(group.children or {}) do
                                        add_line(comment.text, comment.highlight)
                                end
                        end
                end
        end
        vim.api.nvim_buf_set_option(buf, "modifiable", true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(buf, state.comments.namespace, 0, -1)
        for _, hl in ipairs(highlights) do
                vim.api.nvim_buf_add_highlight(buf, state.comments.namespace, hl.group, hl.line, 0, -1)
        end
        if state.comments.win and vim.api.nvim_win_is_valid(state.comments.win) then
                local height = line_nr
                if height < state.comments.min_height then
                        height = state.comments.min_height
                end
                if height > state.comments.max_height then
                        height = state.comments.max_height
                end
                vim.api.nvim_win_set_height(state.comments.win, height)
        end
end

local function open_comment(node, parent)
        if not node then
                return
        end
        local pr_node = state.comments.pr
        if not pr_node or not pr_node.details then
                return
        end
        if not parent or parent.path == nil or parent.path == "" then
                vim.notify("Comment is not associated with a file", vim.log.levels.INFO)
                return
        end
        local file
        if pr_node.files_by_path then
                file = pr_node.files_by_path[parent.path]
        end
        if not file then
                vim.notify("File not available for this comment", vim.log.levels.WARN)
                return
        end
        local opts = {
                line = node.line,
                side = node.side,
                range = node.range,
        }
        pulls.open_file_diff(pr_node.pr, pr_node.details, file, opts)
end

local function toggle_comment()
        if not (state.comments.win and vim.api.nvim_win_is_valid(state.comments.win)) then
                return
        end
        local line = vim.api.nvim_win_get_cursor(state.comments.win)[1]
        local node, parent = comment_node_at(line)
        if not node then
                return
        end
        if node.type == "comment_group" then
                node.open = not node.open
                render_comments()
        elseif node.type == "comment" then
                open_comment(node, parent)
        end
end

local function close_comments()
        if state.comments.win and vim.api.nvim_win_is_valid(state.comments.win) then
                vim.api.nvim_win_close(state.comments.win, true)
        end
        if state.comments.buf and vim.api.nvim_buf_is_valid(state.comments.buf) then
                vim.api.nvim_buf_delete(state.comments.buf, { force = true })
        end
        state.comments.win = nil
        state.comments.buf = nil
        state.comments.nodes = {}
        state.comments.pr = nil
        state.comments.mapped = false
        state.comments.autocmd = nil
end

local function ensure_comment_window()
        if state.comments.win and vim.api.nvim_win_is_valid(state.comments.win) and state.comments.buf and vim.api.nvim_buf_is_valid(state.comments.buf) then
                return true
        end
        if state.comments.win and not vim.api.nvim_win_is_valid(state.comments.win) then
                state.comments.win = nil
        end
        if state.comments.buf and not vim.api.nvim_buf_is_valid(state.comments.buf) then
                state.comments.buf = nil
                state.comments.mapped = false
                state.comments.autocmd = nil
        end
        local buf = state.comments.buf
        if not buf then
                buf = vim.api.nvim_create_buf(false, true)
                state.comments.buf = buf
        end
        vim.cmd("botright split")
        local win = vim.api.nvim_get_current_win()
        state.comments.win = win
        vim.api.nvim_win_set_buf(win, buf)
        vim.api.nvim_win_set_height(win, state.comments.default_height)
        vim.api.nvim_win_set_option(win, "number", false)
        vim.api.nvim_win_set_option(win, "relativenumber", false)
        vim.api.nvim_win_set_option(win, "foldenable", false)
        vim.api.nvim_win_set_option(win, "signcolumn", "no")
        vim.api.nvim_win_set_option(win, "wrap", false)
        vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(buf, "swapfile", false)
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.api.nvim_buf_set_option(buf, "filetype", "ghprcomments")
        if not state.comments.mapped then
                vim.keymap.set("n", "<CR>", toggle_comment, { buffer = buf, nowait = true })
                vim.keymap.set("n", "q", close_comments, { buffer = buf, nowait = true })
                state.comments.mapped = true
        end
        if not state.comments.autocmd then
                state.comments.autocmd = vim.api.nvim_create_autocmd("BufWipeout", {
                        buffer = buf,
                        callback = function()
                                state.comments.win = nil
                                state.comments.buf = nil
                                state.comments.nodes = {}
                                state.comments.pr = nil
                                state.comments.mapped = false
                                state.comments.autocmd = nil
                        end,
                })
        end
        return true
end

local function preserve_comment_group_state(previous, nodes)
        if not previous or not nodes then
                return
        end
        local open_by_key = {}
        for _, group in ipairs(previous) do
                if group.key then
                        open_by_key[group.key] = group.open ~= false
                end
        end
        for _, group in ipairs(nodes) do
                if group.key and open_by_key[group.key] ~= nil then
                        group.open = open_by_key[group.key]
                end
        end
end

local function first_open_pr(exclude)
        for _, group in ipairs(state.nodes) do
                if group.open then
                        for _, pr in ipairs(group.children or {}) do
                                if pr ~= exclude and pr.open and pr.details then
                                        return pr
                                end
                        end
                end
        end
        return nil
end

local function update_comment_panel(pr_node)
        if not pr_node or not pr_node.details then
                close_comments()
                return
        end
        if not pr_node.comment_nodes or not pr_node.comment_counts then
                local comment_nodes, comment_counts = build_comment_data(pr_node.details)
                pr_node.comment_nodes = comment_nodes
                pr_node.comment_counts = comment_counts
                refresh_file_comment_annotations(pr_node)
                render()
        end
        preserve_comment_group_state(state.comments.nodes, pr_node.comment_nodes)
        state.comments.nodes = pr_node.comment_nodes or {}
        state.comments.pr = pr_node
        state.current_pr = pr_node
        if ensure_comment_window() then
                render_comments()
                if state.win and vim.api.nvim_win_is_valid(state.win) then
                        vim.api.nvim_set_current_win(state.win)
                end
        end
end

local function toggle()
        if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
                return
        end
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
                        node.details = nil
                        node.comment_nodes = nil
                        node.comment_counts = nil
                        node.files_by_path = nil
                        if state.current_pr == node then
                                state.current_pr = nil
                        end
                        render()
                        if state.comments.pr == node then
                                local replacement = first_open_pr(node)
                                if replacement then
                                        update_comment_panel(replacement)
                                else
                                        state.comments.pr = nil
                                        state.comments.nodes = {}
                                        if state.comments.buf and vim.api.nvim_buf_is_valid(state.comments.buf) then
                                                render_comments()
                                        else
                                                close_comments()
                                        end
                                end
                        end
                else
                        local details = pulls.fetch_details(node.pr)
                        node.details = details
                        local comment_nodes, comment_counts = build_comment_data(details)
                        node.comment_nodes = comment_nodes
                        node.comment_counts = comment_counts
                        node.children = build_file_nodes(node, details, comment_counts)
                        node.open = true
                        state.current_pr = node
                        render()
                        update_comment_panel(node)
                end
        elseif node.type == "file" and parent and parent.details then
                pulls.open_file_diff(parent.pr, parent.details, node.file)
        end
end

local function close()
        close_comments()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                vim.api.nvim_win_close(state.win, true)
        end
        if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
                vim.api.nvim_buf_delete(state.buf, { force = true })
        end
        state.win = nil
        state.buf = nil
        state.nodes = {}
        state.current_pr = nil
end

function M.open()
        if state.win and vim.api.nvim_win_is_valid(state.win) then
                vim.api.nvim_set_current_win(state.win)
                return
        end
        define_highlights()
        vim.cmd("topleft vsplit")
        state.win = vim.api.nvim_get_current_win()
        state.buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(state.win, state.buf)
        vim.api.nvim_win_set_width(state.win, 40)
        vim.api.nvim_win_set_option(state.win, "wrap", false)
        vim.api.nvim_win_set_option(state.win, "number", false)
        vim.api.nvim_win_set_option(state.win, "relativenumber", false)
        vim.api.nvim_win_set_option(state.win, "signcolumn", "no")
        vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
        vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(state.buf, "swapfile", false)
        vim.api.nvim_buf_set_option(state.buf, "modifiable", false)
        vim.api.nvim_buf_set_option(state.buf, "filetype", "ghprtree")
        state.nodes = {}
        state.current_pr = nil
        state.comments.nodes = {}
        state.comments.pr = nil
        if state.comments.buf and vim.api.nvim_buf_is_valid(state.comments.buf) then
                render_comments()
        end
        for _, group in ipairs(pulls.fetch_by_query()) do
                local group_node = { type = "group", text = group.label, open = false, children = {} }
                for _, pr in ipairs(group.pull_requests or {}) do
                        table.insert(group_node.children, { type = "pr", pr = pr, text = pr_text(pr), open = false })
                end
                table.insert(state.nodes, group_node)
        end
        render()
        vim.keymap.set("n", "<CR>", toggle, { buffer = state.buf })
        vim.keymap.set("n", "q", close, { buffer = state.buf })
end

return M
