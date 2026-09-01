$ErrorActionPreference = "Stop"

$tracked = @(git ls-files)
$forbidden = @($tracked | Where-Object {
  $_ -match '(^|/)(GOAL|AGENTS)\.md$' -or $_ -match '(^|/)model-context/'
})

if ($forbidden.Count -gt 0) {
  throw "Release boundary contains model-only files:`n$($forbidden -join "`n")"
}

$matches = @(git grep -n -I -E 'C:\\Users\\|/home/[^/]+/' -- . 2>$null)
if ($LASTEXITCODE -notin @(0, 1)) {
  throw "Could not scan tracked files for local absolute paths"
}
if ($matches.Count -gt 0) {
  throw "Release boundary contains local absolute paths:`n$($matches -join "`n")"
}

Write-Host "release boundary is clean"
