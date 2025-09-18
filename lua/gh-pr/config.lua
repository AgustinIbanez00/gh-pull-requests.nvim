local M = {}

local defaults = {
        queries = {
                {
                        label = "Waiting For My Review",
                        query = "repo:${owner}/${repository} is:open review-requested:${user}",
                },
                {
                        label = "Created By Me",
                        query = "repo:${owner}/${repository} is:open author:${user}",
                },
                {
                        label = "All Open",
                        query = "repo:${owner}/${repository} is:open",
                },
        },
}

local options = vim.deepcopy(defaults)

function M.setup(opts)
        options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
        return options
end

function M.get()
        return options
end

return M
