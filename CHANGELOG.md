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
