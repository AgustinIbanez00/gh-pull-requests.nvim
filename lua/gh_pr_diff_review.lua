local source = require("gh-pr.neotree.diff_review_source_entry")

source.components = source.components or require("gh-pr.neotree.components")
source.commands = source.commands or require("gh-pr.neotree.diff_review_commands")

return source
