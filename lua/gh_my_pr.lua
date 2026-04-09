local source = require("gh-pr.neotree.my_pr_source_entry")

source.components = source.components or require("gh-pr.neotree.components")
source.commands = source.commands or require("gh-pr.neotree.review_commands")

return source
