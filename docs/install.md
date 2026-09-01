# Installation and production use

Release archives contain the `tex2ss` executable, README, GPL-2.0-or-later
license, and a matching SHA-256 checksum file. Verify the checksum, unpack the
archive, and add its directory to `PATH`.

PowerShell, current terminal only:

```powershell
$env:Path = "C:\path\to\tex2ss;$env:Path"
```

For a permanent Windows installation, place the executable in a stable user
directory and add that directory through the user Environment Variables UI.
On Linux, copy it to a directory already on `PATH`, such as `~/.local/bin`.

`tex2ss new site NAME` embeds and copies all required scaffold assets: the
LaTeX package, semantic Pandoc filter, a content-plugin example, templates,
deployment targets, CSS, and JS. An installed executable does not read the
tex2ss source checkout.

Install `latexmk` plus the selected `pdflatex`, `xelatex`, or `lualatex` engine
and run `tex2ss doctor` inside the site. Doctor resolves both executables and
performs a real compile probe; merely finding their names on `PATH` is not
considered sufficient.

Content plugins are trusted project Lua under `plugins/<id>/` or a bundle's
`extension/<id>/`. They use standard `require` for local modules. Review shared
plugins as code: tex2ss validates their public values and dependency direction,
but does not provide a malicious-code sandbox, marketplace, installer, or
lockfile.

Use `build --which slot:...` or `--which regex:...` for selective work; run a
full build first so unrelated successful outputs can be retained. `--force`
bypasses compilation caches only in the selected dependency closure.

Deployment credentials belong in environment variables or provider CLIs, not
`config.json`. `tex2ss deploy TARGET --dry-run` still builds and loads the Lua
target but only prints its structured executable/argument plan. Ordinary build,
serve, and watch operations never deploy.
