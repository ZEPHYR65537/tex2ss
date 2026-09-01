# Changelog

## Unreleased

- Establish the reliable HTML and PDF architecture: strict schemas, frozen
  SiteIndex, one in-process Pandoc adapter, ordered Lua filters, filtered-AST
  TOC, structured `latexmk`, real doctor probe, fingerprints, and transactional
  `public/`/`pdfs/` snapshots.
- Name non-root PDFs after the final slot segment and support a strict
  bundle-level `pdf_name` basename override.
- Replace the experimental generator/namespace/post-analyzer protocol with
  LaTeX-declared, view-owned content plugins. Plugins select strict descendants,
  analyze shared final ASTs once, and generate private named LaTeX or portable
  Pandoc-block fragments through a stable `require "tex2ss"` host module.
- Add the scaffolded semantic `\texssaudio`, `\texssvideo`, and `\texsslink`
  macros with matching PDF fallbacks, Pandoc filter, and progressive HTML JS;
  bridge native LaTeX labels/references/equation numbers and run linked
  citeproc for declared shared bibliographies.
- Add selective slot/regex build unions, automatic plugin dependency closure,
  closure-scoped `--force`, and preservation of unrelated successful outputs.
- Add named Lua deploy targets with build-before-deploy, dry-run, structured
  executable/argv/cwd commands, deployment records, and no shell-string API.
- Preserve bundle-relative media semantics across HTML and PDF and harden
  portable paths against Windows device names and directory-link cycles.
