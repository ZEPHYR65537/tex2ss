# M1/M2 architecture

The build is deliberately split into a pure preflight model and an effectful
compiler model.

```text
strict config + physical bundle discovery
                  |
                  v
       immutable global SiteIndex
                  |
                  v
controlled include expansion + deferred LaTeX generator fragments
                  -> Pandoc readLaTeX (once per rebuilt bundle)
                  -> direct Pandoc block splice
                  -> ordered in-process Lua filters
                  -> residual RawTeX validation
                  -> Pandoc HTML5 writer
                  -> Hakyll template and route
                  |
                  v
       .tex2ss/work/public candidate
                  |
                  v
   SHA-256 manifest + snapshot commit -> public/

assembled LaTeX + in-process lowering of direct Pandoc blocks
                  + declared resource manifests
                  |
                  v
       input fingerprint + PDF cache
                  |
                  v
structured latexmk -pdf invocation per changed bundle
                  |
                  v
        .tex2ss/work/pdfs candidate
                  |
                  v
   SHA-256 manifest + snapshot commit -> pdfs/
```

## Ownership boundaries

- `meta.json` owns static page facts used by discovery and SiteIndex.
- `index.tex` and `sources/*.tex` own document content and LaTeX semantics.
- Pandoc owns the document AST, Lua filter model, and HTML conversion.
- Generator output is explicit block-level `deferred_latex` or
  `pandoc_blocks`; ordinary strings have no implicit reader or target format.
- Hakyll owns tracked inputs, incremental compilation, templates, and routes.
- `latexmk`/`pdflatex` own TeX execution for the single M2 PDF recipe.
- tex2ss owns validation, paths, build planning, media routing, structured
  process arguments, PDF fingerprints, and both final snapshot transactions.

The Hakyll dependency is compiled with `-usePandoc`. tex2ss links Pandoc 3.11
and `pandoc-lua-engine` directly, so there is one documented Pandoc adapter and
no Pandoc CLI process per fragment or page.

## SiteIndex and incremental correctness

SiteIndex contains every valid physical bundle, including drafts, before any
LaTeX document is parsed. Each page currently takes a coarse dependency on the
complete set of `meta.json` files. This makes additions, removals, moves, and
metadata changes correct for future whole-site generators. Finer query
projection is an optimization after the generator API is accepted.

Includes and filters are explicit Hakyll content dependencies. Hakyll builds
into a persistent candidate directory; tex2ss prunes stale routes, hashes the
candidate, and only then swaps the canonical `public/` snapshot. Compiler
failure therefore leaves the previous successful site intact.

PDF outputs mirror slot shape (`index.pdf`, `guide/index.pdf`). Direct generated
blocks are lowered by the linked Pandoc LaTeX writer, and required Pandoc snippet
helper macros are inserted before `\\begin{document}`. Each fingerprint contains
the lowered assembled source, canonical generated AST, TeX recipe/tool versions,
shared `latex/`, bundle `media/`, and bundle-local `extension/latex/` manifests.
An unchanged and unmodified published PDF is copied into a fresh candidate
without invoking TeX.
Every changed bundle compiles in `.tex2ss/tmp/pdf/`; only a complete candidate
can atomically replace `pdfs/`.

`doctor` resolves `latexmk` and `pdflatex`, reports their paths and versions,
and runs the same recipe on a minimal document. Finding commands on `PATH` alone
is therefore not considered a healthy LaTeX environment.

## Trusted Lua

Configured filters are trusted project code and run through Pandoc's standard
in-process Lua engine. M1 does not add a malicious-code sandbox. The lifecycle,
ordered filter list, declared file dependencies, and typed outputs remain build
contracts; undeclared filesystem, network, or process side effects are outside
the reproducibility and cache guarantees.

Generated `pandoc_blocks` are decoded through Pandoc's Lua marshal instances,
not JSON or generated markup. Raw blocks and raw inlines are rejected at this
boundary so the same semantic AST remains portable to HTML and PDF. Internal
source markers only bridge the single document reader call; they are removed
before filters and never reach either writer.
