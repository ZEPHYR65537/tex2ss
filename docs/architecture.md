# Architecture

tex2ss separates a pure, complete preflight plan from effectful compilation.

```text
strict config + physical bundle discovery
                  |
                  v
          frozen global SiteIndex
                  |
                  v
scan physical index.tex plugin declarations
resolve plugin directories + select strict descendants
                  |
                  v
         complete acyclic BuildPlan
                  |
                  v
each rebuilt document: include assembly -> one Pandoc LaTeX read
                  -> one ordered-filter chain
                  -> interested ancestor analyzers share final AST
                  -> private snapshots keyed by owner/plugin/document
                  |
                  v
owner plugin generate -> named LaTeX/Pandoc fragments
                  -> owner HTML writer + template + TOC
                  -> or shared PDF source + latexmk
                  |
                  v
candidate manifest -> transactional public/ or pdfs/ snapshot
```

## Boundaries

- `meta.json` owns static discovery facts and arbitrary static `data`.
- `index.tex` and `sources/*.tex` own document semantics and content-plugin
  placement.
- SiteIndex describes all valid physical bundles, including drafts.
- View-owned Lua plugins select strict descendants, map their final ASTs, and
  fold private values into the owner's document.
- Ordered Pandoc Lua filters remain independent AST transformations.
- Pandoc owns parsing, AST semantics, TOC input, HTML writing, and portable
  block lowering to LaTeX.
- Hakyll owns HTML dependency snapshots and incremental scheduling.
- `latexmk` plus the configured engine owns the single structured PDF recipe.
- tex2ss owns validation, dependency closure, manifests, paths, caches,
  diagnostics, selective-build policy, and transactional publication.

tex2ss links Pandoc and `pandoc-lua-engine`; it does not start a Pandoc process
for pages or fragments. The default LaTeX reader extensions include macro
expansion and automatic identifiers while unsupported LaTeX is preserved for
filters or diagnostics. Body and TOC are written from one final AST.

## Plugin graph and cache correctness

Preflight expands each physical `index.tex` only far enough to find standalone
`\texssgenerated{plugin}{fragment}` declarations. It resolves each plugin,
runs `select` against the frozen SiteIndex, verifies strict-descendant edges,
and therefore knows the full acyclic graph before parsing any document body.

A rebuilt document is assembled, read, and filtered once. The resulting AST is
then passed through linked citeproc when bibliography metadata exists and
offered to every interested ancestor plugin analyzer. A snapshot identity
is `(owner slot, plugin id, analyzed slot)`, so values are never visible across
plugins or owners. HTML stores them in Hakyll snapshots; PDF walks the same
BuildPlan deepest-first. Each owner/plugin generator runs once and may satisfy
multiple fragment occurrences.

Plugin fingerprints include the complete selected plugin-directory manifest,
SiteIndex metadata snapshot, exact selected slots and values, and tool/Pandoc
versions. Metadata dependencies intentionally remain coarse at whole-site
granularity; shared bibliography inputs are also tracked, while body
dependencies cover only selected descendants. Public API
file reads and values are reproducible; arbitrary side effects of trusted Lua
are outside cache guarantees.

Selective-build slot/regex selectors form seed unions. tex2ss adds content
producers, selected descendants, affected owners, and other required edges.
The candidate begins from the last successful output, so unrelated HTML/PDF
files remain byte-for-byte intact. `--force` only recompiles the selected
closure. A complete candidate is validated and committed together, while any
failure preserves the previous published snapshot and analysis cache.

## HTML and PDF consistency

Deferred LaTeX fragments enter the owner's single LaTeX read for HTML and its
assembled TeX source for PDF. Direct `pandoc.Blocks` are inserted before the
owner filter chain and lowered through the same linked Pandoc version for PDF;
raw target nodes are rejected. This keeps content semantic and target-neutral.

PDF fingerprints contain assembled source, generated AST, selected engine and
tool versions, fixed `latexmk -norc` arguments, shared `latex/`, bundle media,
and bundle-local `extension/latex/` manifests. Builds occur in private working
directories and only a complete candidate replaces `pdfs/`.

Bundle media uses one convention: `media/img/figure.png` resolves from the
bundle directory during TeX compilation and is copied beside that bundle's
HTML route. PDF names keep the slot directory and default to the final segment.

## Deployment and trusted Lua

Filters, content plugins, and deployment scripts are trusted project code; no
malicious-code sandbox is promised. Their public inputs, outputs, order, and
tracked manifests are build contracts.

Deployment is deliberately outside the content graph. A named target first
finishes an HTML incremental build, then loads one Lua script. The script sees
the canonical successful `public/` path, its build manifest, target `data`, and
a planning API, and returns executable/argv/cwd tuples. The host never accepts
shell command strings. Dry-run validates and prints the plan without executing
it. A deploy failure does not change the local successful build. Each attempt
has one local record whose state moves from `started` to `success`, `failed`, or
`dry-run`; it keeps start/finish timestamps plus the target, script hash, and
successful build-manifest hash.
