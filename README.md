# tex2ss

tex2ss is a LaTeX-first static site generator written in Haskell. Each
physical `index.tex` + `meta.json` bundle is rendered to semantic HTML through
the linked Pandoc library and to PDF through one structured `latexmk` recipe.
Both targets share the same SiteIndex, include assembly, ordered Lua filters,
and view-owned content-plugin plan.

## Development

Pandoc and Hakyll are pinned to exact source commits in `cabal.project`.

```console
cabal build all
cabal test all
cabal run tex2ss -- --help
```

The command surface is:

```text
tex2ss new site NAME [--parent PATH]
tex2ss init [PATH]
tex2ss new view SLOT
tex2ss doctor [PATH]
tex2ss build [--format html|pdf] [--include-drafts]
              [--which all|slot:SLOT|regex:PATTERN]... [--force]
tex2ss deploy TARGET [--dry-run]
tex2ss serve [--host 127.0.0.1] [--port 8000] [--include-drafts]
```

`doctor` validates the complete project and compiles a real minimal document
with the configured `pdflatex`, `xelatex`, or `lualatex` engine. PDF outputs
retain their slot directory and use the last slot segment as the filename;
`meta.json.pdf_name` can override only that basename.

## View-owned content plugins

Dynamic semantic content is declared by a standalone line in `index.tex`:

```latex
\texssgenerated{archive}{latest}
```

The plugin is resolved from `content/<slot>/extension/archive/init.lua` first,
then `plugins/archive/init.lua`. Its optional `select` hook chooses strict
descendants from the frozen SiteIndex, `analyze` maps each selected document's
final filtered Pandoc AST, and `generate` folds the private results into named
LaTeX or Pandoc-block fragments. A document is parsed and filtered only once,
even when several ancestor plugins analyze it. Plugins do not publish global
namespaces or read one another's values, and never create virtual bundles or
write output directories.

The runnable three-level example is in
[`examples/post-analysis-tree`](examples/post-analysis-tree). Ordinary ordered
Pandoc filters remain a separate mechanism for AST transformations.

## Output and deployment

HTML templates receive `$body$`, `$toc$`, metadata, and site fields. `$toc$`
is produced from the same final AST, including plugin fragments and filter
changes. Bundle-relative `media/` paths work consistently in HTML and PDF.

Selective builds take a union of slot and regular-expression seeds and add the
dependency closure required by content plugins. Unselected successful outputs
remain intact. `--force` bypasses caches only for that closure.

Named deploy targets are configured at the project root. `tex2ss deploy`
always completes an incremental HTML build first, then lets trusted Lua return
structured executable/argv/cwd commands against the successful `public/`
snapshot. No shell command strings or implicit deployment from build/serve are
supported.

See [architecture](docs/architecture.md), [schema v1](docs/schemas.md),
[installation and production use](docs/install.md), and the
[historical M1 boundary](docs/m1-scope.md).
