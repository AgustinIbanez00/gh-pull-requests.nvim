local create = require("gh-pr.neotree.review_source_entry")._create

return create({
  source_name = "gh_my_pr",
  display_name = "GH My PR",
  source_module_name = "gh-pr.neotree.my_pr_source",
})
