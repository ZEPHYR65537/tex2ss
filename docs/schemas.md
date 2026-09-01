# Schema v1

Both JSON documents are strict: unknown top-level or site fields fail. Custom
bundle values belong under `data` so future reserved fields can be added without
collisions.

## `config.json`

```json
{
  "schema_version": 1,
  "site": {
    "title": "Example",
    "description": "",
    "base_url": "",
    "lang": "en",
    "author": "",
    "email": "author@example.test"
  },
  "templates": {
    "default": "default.html"
  },
  "default_template": "default",
  "filters": ["filters/references.lua"],
  "pdf_engine": "pdflatex"
}
```

Template paths are relative to `site/templates/` and must end in `.html`.
Global filter paths are relative to `pandoc/` and must end in `.lua`. Every
path must exist and remain inside its owning root after canonicalization.

`pdf_engine` is optional and defaults to `pdflatex`. Its only other accepted
values are `xelatex` and `lualatex`. It selects one fixed, structured `latexmk`
recipe (`-pdf`, `-xelatex`, or `-lualatex` respectively); it does not accept a
path, argv, shell command, recipe name, or bundle override. Explicit `null` and
unknown values fail the strict schema. The recipe uses `-norc`, so system, user,
and project `.latexmkrc` files cannot silently change the fixed command model.

## `meta.json`

```json
{
  "schema_version": 1,
  "title": "A post",
  "author": "Author",
  "date": "2026-08-31",
  "template": "default",
  "visibility": "published",
  "generator": "tree.lua",
  "analysis_inputs": ["example.outline"],
  "post_analyzer": {
    "script": "outline.lua",
    "namespace": "example.outline",
    "schema_version": 1
  },
  "pdf_name": "post-handout",
  "filters": ["filters/local.lua"],
  "data": {
    "tags": ["haskell", "pandoc"],
    "kind": "post"
  }
}
```

`title` is required. `date`, when present, is `YYYY-MM-DD`; visibility is
`published` or `draft`. Local filter paths are relative to the bundle's
`extension/` directory. The optional experimental `generator` is one `.lua`
file relative to the same directory. Template fields receive custom values as
`$data_<key>$`; arrays and objects are compact JSON.

`post_analyzer` is an optional experimental contract. Its `.lua` script is
relative to the same `extension/` directory. `namespace` must contain at least
two portable dotted segments, and `schema_version` must be positive. The script
defines `post_analyzer(document, context)` and returns one JSON-serializable
open value. `document` is the current bundle's Pandoc AST after the ordered
filters; tex2ss supplies the document identity, namespace, version, and producer
identity around the returned value. One encoded export may not exceed 1 MiB.

`analysis_inputs` is a duplicate-free list of namespaces read by the current
bundle's generator. It requires `generator`. The generator receives matching
values as `context.analysis_exports`, ordered by document/namespace. Only
exports from strict descendants of the current slot are included: never the
current bundle, siblings, or ancestors. Declaring a namespace is the v1
dependency contract; Lua remains free to interpret and aggregate each open
value. HTML stores successful exports as Hakyll snapshots, and PDF schedules
bundles from deepest slot to root. Both targets use the same `html5` filter
environment for this canonical analysis AST, so `FORMAT`-sensitive filters do
not produce divergent ancestor inputs.

`pdf_name` is an optional PDF basename without `.pdf`. It must match
`[a-z0-9][a-z0-9_-]*`; paths, extensions, uppercase letters, and traversal are
rejected. Without it, a non-root bundle uses the final slot segment, while the
root bundle uses `index`. The slot directory is never changed by this field:
`content/guide/reference` produces `pdfs/guide/reference/reference.pdf`, or
`pdfs/guide/reference/post-handout.pdf` with the example override.

The experimental generator must define `pre_generator(context)` and return a
strict `fragments` table. Each named block fragment currently has one of these
explicit shapes:

```lua
return {
  fragments = {
    legacy = { type = "deferred_latex", value = "\\begin{quote}...\\end{quote}" },
    semantic = {
      type = "pandoc_blocks",
      blocks = pandoc.Blocks({ pandoc.Para({ pandoc.Str("Hello") }) })
    }
  }
}
```

Placeholders use a standalone `\\tex2ssgenerated{name}` line. Direct Pandoc
blocks may not contain raw target nodes. These Lua field names remain an
experimental protocol rather than a stable schema-v1 compatibility promise.

M2.2 deliberately adds only the root `pdf_engine` enum, not a generic recipe
schema. Multiple recipes, arbitrary tool paths, and user-provided command lines
remain outside schema v1.

## Physical bundles and routes

A directory is a bundle only when it has both `index.tex` and `meta.json`.
Having only one marker is an error. Once a bundle is found, its `sources/`,
`media/`, and `extension/` trees are not searched for nested bundles.

Slot segments match `[a-z0-9][a-z0-9_-]*`. The root bundle routes to `/`; a
bundle at `content/posts/hello/` routes to `/posts/hello/`. Bundle media is
copied to the route-relative `media/` subtree, while site assets are copied to
`/assets/`.

Literal `\input{...}` and `\include{...}` commands are expanded only when the
resolved file remains under the current bundle's `sources/` directory.
Absolute, parent-traversing, missing, dynamic, and cyclic includes fail.

The exact layout command `\maketitle` is consumed after Lua filters because the
site template owns title presentation and `meta.json.title` is authoritative.
Other contentful RawTeX must be handled by a configured filter or the page
fails explicitly.
