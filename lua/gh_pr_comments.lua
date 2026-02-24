local source = require("gh-pr.neotree.comments_source")

source.commands = source.commands or require("gh-pr.neotree.comments_commands")
source.components = source.components or require("gh-pr.neotree.components")

return source
