$ErrorActionPreference = "Stop"

$tracked = @(git ls-files)
$forbidden = @($tracked | Where-Object {
  $_ -match '(^|/)(GOAL|AGENTS)\.md$' -or $_ -match '(^|/)model-context/'
})

if ($forbidden.Count -gt 0) {
  throw "Release boundary contains model-only files:`n$($forbidden -join "`n")"
}

$windowsHome = 'C:' + '\Users\'
$unixHome = '/ho' + 'me/'
$localPathPattern = [regex]::Escape($windowsHome) + '|' + $unixHome + '[^/]+/'
$pathHits = @(git grep -n -I -E $localPathPattern -- . 2>$null)
if ($LASTEXITCODE -notin @(0, 1)) {
  throw "Could not scan tracked files for local absolute paths"
}
if ($pathHits.Count -gt 0) {
  throw "Release boundary contains local absolute paths:`n$($pathHits -join "`n")"
}

Write-Host "release boundary is clean"
