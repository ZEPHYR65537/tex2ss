# M1 architecture

The build is deliberately split into a pure preflight model and an effectful
compiler model.

```text
strict config + physical bundle discovery
                  |
                  v
       immutable global SiteIndex
                  |
                  v
controlled include expansion -> Pandoc readLaTeX (once per rebuilt bundle)
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
```

## Ownership boundaries

- `meta.json` owns static page facts used by discovery and SiteIndex.
- `index.tex` and `sources/*.tex` own document content and LaTeX semantics.
- Pandoc owns the document AST, Lua filter model, and HTML conversion.
- Hakyll owns tracked inputs, incremental compilation, templates, and routes.
- tex2ss owns validation, paths, build planning, media routing, and the final
  snapshot transaction.

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

## Trusted Lua

Configured filters are trusted project code and run through Pandoc's standard
in-process Lua engine. M1 does not add a malicious-code sandbox. The lifecycle,
ordered filter list, declared file dependencies, and typed outputs remain build
contracts; undeclared filesystem, network, or process side effects are outside
the reproducibility and cache guarantees.
