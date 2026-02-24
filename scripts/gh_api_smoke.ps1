param(
  [string]$Repo,
  [switch]$IncludeNegativeChecks
)

$ErrorActionPreference = 'Stop'

function Resolve-Repo {
  param([string]$InputRepo)

  if ($InputRepo) {
    return $InputRepo
  }

  $remote = git remote get-url origin 2>$null
  if (-not $remote) {
    throw 'Unable to resolve repository. Provide -Repo owner/name.'
  }

  if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<name>[^\.]+)(\.git)?$') {
    return "$($Matches.owner)/$($Matches.name)"
  }

  throw "Unable to parse origin remote: $remote"
}

function Invoke-CommandChecked {
  param(
    [string]$Exe,
    [string[]]$CmdArgs
  )

  if ($null -eq $CmdArgs) {
    $CmdArgs = @()
  }

  $out = & $Exe @CmdArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($out | Out-String).Trim()
  }

  return ($out | Out-String).Trim()
}

$results = @()

function Add-Result {
  param(
    [string]$Name,
    [bool]$Ok,
    [string]$Detail
  )

  $script:results += [pscustomobject]@{
    Name = $Name
    Ok = $Ok
    Detail = $Detail
  }
}

function Run-Check {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  try {
    $detail = & $Action
    Add-Result -Name $Name -Ok $true -Detail ([string]$detail)
  } catch {
    Add-Result -Name $Name -Ok $false -Detail ($_.Exception.Message)
  }
}

$Repo = Resolve-Repo -InputRepo $Repo
Write-Host "Running gh API smoke checks for $Repo" -ForegroundColor Cyan

Run-Check -Name 'auth-status' -Action {
  Invoke-CommandChecked gh @('auth', 'status')
}

Run-Check -Name 'api-user' -Action {
  Invoke-CommandChecked gh @('api', 'user', '--jq', '.login')
}

Run-Check -Name 'repo-view' -Action {
  $json = Invoke-CommandChecked gh @('repo', 'view', $Repo, '--json', 'nameWithOwner,defaultBranchRef')
  $obj = $json | ConvertFrom-Json
  "$($obj.nameWithOwner)@$($obj.defaultBranchRef.name)"
}

Run-Check -Name 'pr-list' -Action {
  Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'list', '--state', 'all', '--limit', '3', '--json', 'number,title,state', '--jq', 'length')
}

$prNumber = $null
try {
  $prNumber = Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'list', '--state', 'open', '--limit', '1', '--json', 'number', '--jq', '.[0].number')
  if (-not $prNumber) {
    $prNumber = Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'list', '--state', 'all', '--limit', '1', '--json', 'number', '--jq', '.[0].number')
  }
} catch {
  $prNumber = $null
}

if (-not $prNumber) {
  Add-Result -Name 'pr-selected' -Ok $false -Detail 'No pull request found for checks'
} else {
  Add-Result -Name 'pr-selected' -Ok $true -Detail "PR #$prNumber"
  $repoParts = $Repo -split '/', 2
  $repoOwner = $repoParts[0]
  $repoName = $repoParts[1]

  if ($IncludeNegativeChecks) {
    Run-Check -Name 'pr-view-invalid-baseRepository' -Action {
      try {
        [void](Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'view', $prNumber, '--json', 'number,baseRepository', '--jq', '.number'))
      } catch {
        return 'failed-as-expected'
      }
      throw 'Unexpected success for invalid field baseRepository'
    }
  }

  Run-Check -Name 'pr-view-details' -Action {
    Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'view', $prNumber, '--json', 'number,title,baseRefName,headRefName,headRepository,headRepositoryOwner,isCrossRepository,files', '--jq', '.number')
  }

  Run-Check -Name 'graphql-review-threads' -Action {
    if (-not $repoOwner -or -not $repoName) {
      throw "Invalid repo format: $Repo"
    }
    $query = @'
query($owner:String!, $name:String!, $number:Int!, $threadsFirst:Int!, $commentsFirst:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:$threadsFirst) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          comments(first:$commentsFirst) {
            nodes {
              id
              path
              line
              originalLine
              diffHunk
            }
          }
        }
      }
    }
  }
}
'@
    $json = Invoke-CommandChecked gh @(
      'api', 'graphql',
      '-f', "query=$query",
      '-F', "owner=$repoOwner",
      '-F', "name=$repoName",
      '-F', "number=$prNumber",
      '-F', 'threadsFirst=10',
      '-F', 'commentsFirst=20'
    )
    $obj = $json | ConvertFrom-Json
    $count = @($obj.data.repository.pullRequest.reviewThreads.nodes).Count
    "threads=$count"
  }

  $filePath = $null
  $baseRef = $null

  Run-Check -Name 'pr-view-first-file' -Action {
    $script:filePath = Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'view', $prNumber, '--json', 'files', '--jq', '.files[0].path')
    if (-not $script:filePath) { throw 'PR has no files' }
    $script:filePath
  }

  Run-Check -Name 'pr-view-base-ref' -Action {
    $script:baseRef = Invoke-CommandChecked gh @('-R', $Repo, 'pr', 'view', $prNumber, '--json', 'baseRefName', '--jq', '.baseRefName')
    if (-not $script:baseRef) { throw 'Missing baseRefName' }
    $script:baseRef
  }

  if ($filePath -and $baseRef) {
    Run-Check -Name 'contents-query-ref' -Action {
      $escaped = [uri]::EscapeDataString($filePath).Replace('%2F', '/')
      $ref = [uri]::EscapeDataString($baseRef)
      $endpoint = "repos/$Repo/contents/${escaped}?ref=${ref}"
      Invoke-CommandChecked gh @('api', $endpoint, '--jq', '.encoding')
    }

    Run-Check -Name 'pull-files-first-filename' -Action {
      Invoke-CommandChecked gh @('api', "repos/$Repo/pulls/$prNumber/files", '--jq', '.[0].filename')
    }

    Run-Check -Name 'pull-files-first-patch-presence' -Action {
      $patch = Invoke-CommandChecked gh @('api', "repos/$Repo/pulls/$prNumber/files", '--jq', '.[0].patch')
      if (-not $patch) {
        '<no-textual-patch>'
      } else {
        'patch-present'
      }
    }
  }
}

Write-Host ''
$results | Format-Table -AutoSize | Out-Host

$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) {
  Write-Host "\nSmoke checks finished with $($failed.Count) failure(s)." -ForegroundColor Yellow
  exit 1
}

Write-Host "\nAll smoke checks passed." -ForegroundColor Green
exit 0
