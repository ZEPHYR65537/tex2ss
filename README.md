# tex2ss

tex2ss is a LaTeX-first static site generator written in Haskell. It turns each
physical `index.tex` + `meta.json` bundle into semantic HTML through its linked
Pandoc adapter and can compile the same assembled LaTeX source to PDF through a
structured `latexmk` recipe.

The current codebase implements the reliable M1 HTML core and the first M2 PDF
vertical slices. Public implementation contracts are documented under `docs/`.

## Development

The project pins exact Hakyll and Pandoc source commits in `cabal.project`.

```console
cabal build all
cabal test all
cabal run tex2ss -- --help
```

The initial command surface is:

```text
tex2ss new site NAME [--parent PATH]
tex2ss init [PATH]
tex2ss new view SLOT
tex2ss doctor [PATH]
tex2ss build [--format html|pdf] [--include-drafts]
tex2ss serve [--host 127.0.0.1] [--port 8000] [--include-drafts]
```

`doctor` validates the project, reports the resolved `latexmk` and configured
PDF engine versions and paths, and compiles a minimal probe document with that
same recipe. The optional root `pdf_engine` field selects `pdflatex` (the
default), `xelatex`, or `lualatex`; tex2ss keeps the remaining structured
`latexmk` arguments fixed. PDF builds publish
slot-shaped, recognizable files such as `pdfs/index.pdf` and
`pdfs/guide/guide.pdf` only after the complete candidate succeeds. A bundle can
override its basename with the optional `meta.json` field `pdf_name`.

HTML templates can render `$body$` and a `$toc$` produced from the same filtered
Pandoc AST. Bundle media keeps one relative convention across targets: for
example, `\includegraphics{media/img/figure.png}` is compiled from the bundle
directory for PDF and published beside that bundle's HTML route.

The experimental bundle-local pre-generator receives a read-only SiteIndex and
explicitly selected descendant `AnalysisExport` values, then returns named block
fragments. A fragment contains either deferred LaTeX or portable
`pandoc.Blocks`: HTML inserts direct blocks before filters, while PDF lowers the
same AST with the linked Pandoc LaTeX writer. A bundle `post_analyzer` can export
an open, versioned value from its filtered AST only to strict slot ancestors;
the three-level runnable fixture is under
[`examples/post-analysis-tree`](examples/post-analysis-tree). Neither path
starts a Pandoc CLI process. Virtual bundles, deployment, arbitrary or multiple
PDF recipes, and selective-build APIs remain out of scope.

See [the architecture](docs/architecture.md), [schema v1](docs/schemas.md), and
[the explicit M1 boundary](docs/m1-scope.md) for implementation contracts.
