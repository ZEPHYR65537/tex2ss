# Schema v1 and public extension contracts

Both JSON files are strict: unknown fields fail. Bundle-specific static values
belong under `data`, leaving room for future reserved fields without rescanning
the document body.

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
  "templates": { "default": "default.html" },
  "default_template": "default",
  "filters": ["filters/tex2ss-semantic.lua"],
  "pdf_engine": "pdflatex",
  "deploy": {
    "production": {
      "script": "deploy/production.lua",
      "data": { "project": "example" }
    }
  }
}
```

Template paths are relative to `site/templates/`. Global filter paths are
relative to `pandoc/`; all filters are `.lua` files and run in declared order.
Every path must exist and remain inside its owning root after canonicalization.

`pdf_engine` defaults to `pdflatex`; `xelatex` and `lualatex` are also accepted.
It selects a fixed `latexmk -norc` recipe, not a path or command line.

Deploy target names use portable identifiers. `script` is relative to the
project root and must remain under `deploy/`; `data` is an open JSON object.
Deploy Lua is trusted project code, but it returns structured commands rather
than shell text. Build and serve never trigger a target.

```lua
return function(ctx)
  local project = assert(ctx.target.data.project)
  return {
    commands = {
      {
        executable = "wrangler",
        arguments = {"pages", "deploy", ".", "--project-name", project},
        cwd = "public"
      }
    }
  }
end
```

The context contains the canonical `public` path, decoded successful build
`manifest`, and `{name, data}` target. Each command must use exactly
`executable`, `arguments`, and `cwd = "public"`; no shell string is accepted.
Dry-run loads this function and prints the plan without executing it.

## `meta.json`

```json
{
  "schema_version": 1,
  "title": "A post",
  "author": "Author",
  "date": "2026-08-31",
  "template": "default",
  "visibility": "published",
  "pdf_name": "post-handout",
  "filters": ["filters/local.lua"],
  "data": {
    "tags": ["haskell", "pandoc"],
    "kind": "post"
  }
}
```

`title` is required. Dates use `YYYY-MM-DD`; visibility is `published` or
`draft`. Local filters are relative to the bundle's `extension/` directory.
The superseded `generator`, `analysis_inputs`, and `post_analyzer` fields are
rejected rather than silently accepted.

`pdf_name` must match `[a-z0-9][a-z0-9_-]*` and does not contain `.pdf`. With no
override the root produces `pdfs/index.pdf`; `content/guide/reference` produces
`pdfs/guide/reference/reference.pdf`.

HTML templates receive `$body$`, `$toc$`, `$title$`, `$author$`, `$date$`,
`$visibility$`, `$slot$`, `$route$`, `$site_title$`, `$site_description$`,
`$base_url$`, `$lang$`, plus `$data_<key>$`. Arrays and objects are compact
JSON. `$toc$` is derived from the final filtered AST without a second parse.

## Content plugins

`index.tex` declares a block-level fragment on a standalone line:

```latex
\texssgenerated{archive}{latest} % an optional trailing comment is valid
```

Plugin and fragment IDs match `[a-z0-9][a-z0-9_-]*`. The first occurrence fixes
plugin execution order. Each plugin runs once per owner view, may return several
named fragments, and the same fragment may be inserted repeatedly. Referencing
a missing fragment fails the build.

The public name is `\texssgenerated`, not `\tex2ssgenerated`: digits terminate
a normal TeX control word. `latex/tex2ss.sty` provides
`\providecommand{\texssgenerated}[2]{}` so raw LaTeX remains compilable and
simply omits dynamic content outside tex2ss.

Resolution order is:

```text
content/<slot>/extension/<plugin-id>/init.lua
plugins/<plugin-id>/init.lua
```

The selected plugin directory is tracked as a manifest. Standard Lua `require`
loads sibling modules; there is no package manager, plugin manifest, dependency
download, or version resolver.

An entry returns a hook table:

```lua
local tex2ss = require "tex2ss"

return {
  select = function(ctx)
    return { "posts/one", "posts/two" }
  end,

  analyze = function(document, ctx)
    return { title = pandoc.utils.stringify(document.meta.title) }
  end,

  generate = function(ctx)
    return {
      latest = tex2ss.latex("\\begin{itemize}...\\end{itemize}"),
      tree = tex2ss.blocks(pandoc.Blocks({ pandoc.Para("Tree") }))
    }
  end
}
```

`generate` is required. `analyze` is optional; without it the plugin uses only
the owner and complete frozen SiteIndex. `select` is meaningful only with
`analyze`; its default is every visible strict descendant. Selecting the owner,
a sibling, an ancestor, a missing/draft-hidden slot, or a duplicate fails.

`analyze` receives one descendant's AST after the complete ordered-filter chain
and returns `nil` or a JSON-serializable open value of at most 1 MiB. `generate`
receives the owner, complete SiteIndex, and only this plugin's results in stable
slot order. Results are private to the owning view; there is no namespace bus or
plugin dependency graph.

`tex2ss.latex` is the ordinary form and rejoins the owner's unified reader/PDF
source pipeline. `tex2ss.blocks` directly inserts portable Pandoc blocks; raw
target nodes are rejected and PDF lowers the blocks using the linked Pandoc
version. Plugins cannot return target-specific HTML/PDF values or create routes.

## First-party semantic LaTeX

The scaffold includes these legal control words:

```latex
\texssaudio{media/audio/example.mp3}{Audio recording}
\texssvideo{media/video/example.mp4}{Video recording}
\texsslink{/posts/one/}{Read the post}
```

The package produces readable links in PDF. The ordinary first-party Pandoc
filter turns audio/video into semantic containers with `tex2ss-media` and
`tex2ss-audio`/`tex2ss-video` classes and preserves a fallback link. Default JS
enhances them into players; templates, CSS, and user JS own presentation.
Math does not use a template predicate such as `$has_math$`. The first-party
filter supplies the small HTML bridge Pandoc's LaTeX reader needs for
`\label`/`\ref`/`\eqref`, labeled display-equation numbers, figure references,
and citation fallback content. The AST remains native Pandoc Math/Figure/Cite.
When LaTeX declares `\bibliography{bibliography/references.bib}`, tex2ss runs
Pandoc's linked citeproc after ordered filters; bibliography paths resolve from
the bundle or project `latex/` directory. Real TeX continues to process the
same native LaTeX commands for PDF.

## Physical bundles and includes

A directory is a bundle only when it has both `index.tex` and `meta.json`.
Having one marker is an error. Its `sources/`, `media/`, and `extension/` trees
are not searched for nested bundles. Slot segments use the same portable ID
rule; `.` is the root selector, not a directory name.

Literal `\input{...}` and `\include{...}` commands may resolve only inside the
current bundle's `sources/`. Absolute, parent-traversing, missing, dynamic, and
cyclic includes fail. Contentful RawTeX left after filters also fails explicitly.
