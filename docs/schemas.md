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
  "filters": ["filters/references.lua"]
}
```

Template paths are relative to `site/templates/` and must end in `.html`.
Global filter paths are relative to `pandoc/` and must end in `.lua`. Every
path must exist and remain inside its owning root after canonicalization.

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

M2 intentionally adds no PDF recipe field to schema v1. The first slice has one
fixed, structured `latexmk -pdf` recipe; configurable recipe schemas will be
introduced only after this execution and transaction model is stable.

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
