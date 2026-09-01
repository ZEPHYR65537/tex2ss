$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$tracked = @(git ls-files)
if ($LASTEXITCODE -ne 0) {
  throw "Could not enumerate tracked files"
}
$forbidden = @($tracked | Where-Object {
  $_ -match '(^|/)(GOAL|AGENTS)\.md$' -or $_ -match '(^|/)model-context/'
})

if ($forbidden.Count -gt 0) {
  throw "Release boundary contains model-only files:`n$($forbidden -join "`n")"
}

$windowsHome = 'C:' + '\Users\'
$unixHome = '/ho' + 'me/'
$localPathPattern = [regex]::new([regex]::Escape($windowsHome) + '|' + $unixHome + '[^/]+/')
$pathHits = @(
  foreach ($path in $tracked) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $PWD $path))
    if ([Array]::IndexOf($bytes, [byte] 0) -ge 0) { continue }
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($localPathPattern.IsMatch($content)) { $path }
  }
)
if ($pathHits.Count -gt 0) {
  throw "Release boundary contains local absolute paths:`n$($pathHits -join "`n")"
}

Write-Host "release boundary is clean"
