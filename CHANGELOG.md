# Changelog

## Unreleased

- Establish the M1 HTML architecture, strict project schemas, and CLI surface.
- Pin Hakyll 4.17.1.0 without its Pandoc integration and link Pandoc 3.11 directly.
- Add the first M2 PDF slice: structured `latexmk` builds, incremental input
  fingerprints, transactional `pdfs/` manifests, and a real LaTeX doctor probe.
- Add the SiteIndex/deferred-LaTeX pre-generator experiment shared by HTML and
  PDF source assembly.
- Add portable `pandoc_blocks` generator fragments: direct AST splice before
  HTML filters, in-process LaTeX lowering for PDF, raw-node rejection, and AST
  cache fingerprints.
- Name non-root PDFs after the final slot segment by default and support a
  strict bundle-level `pdf_name` basename override.
- Add the concise root `pdf_engine` enum for pdfLaTeX, XeLaTeX, or LuaLaTeX;
  use the selected engine in the structured recipe, doctor probe, diagnostics,
  and cache fingerprint.
- Add the experimental upward-only `post_analyzer` protocol: open namespaced
  exports from filtered Pandoc AST, explicit ancestor namespace inputs, Hakyll
  analysis snapshots, deepest-first PDF scheduling, strict direction/size
  validation, and a shared HTML/PDF tree fixture.
- Restore Pandoc's default LaTeX reader profile while preserving unsupported
  raw LaTeX for filters, including macro expansion and automatic identifiers.
- Expose `$toc$` to Hakyll templates from the final filtered AST without a
  second parse, and keep HTML fragments deterministically unwrapped.
- Harden portable slot names and recursive discovery against Windows device
  names and directory-link cycles; remove the previously ignored `--all` flag.
- Cover one bundle-relative media convention for route-shaped HTML output and
  PDF compilation.
