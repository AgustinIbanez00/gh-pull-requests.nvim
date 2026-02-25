local source = require("gh-pr.neotree.review_source")

source.commands = source.commands or require("gh-pr.neotree.review_commands")
source.components = source.components or require("gh-pr.neotree.components")

return source
