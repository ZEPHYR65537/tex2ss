# M1 scope

M1 is the reliable HTML core. It includes scaffold creation, strict diagnosis,
physical bundle discovery, global preflight SiteIndex construction, controlled
LaTeX includes, direct Pandoc 3.11 conversion, ordered trusted Lua filters,
Hakyll templates/routes/assets, transactional output, and local watch/serve.

The M1 baseline intentionally did not freeze or emulate unfinished contracts:

- generators, post analyzers, virtual bundles, and virtual routes are not
  exposed.
- deploy providers and deploy Lua scripts are not exposed.
- selective slot/regex builds are not exposed; `--all` is the default.
- unsupported contentful RawTeX must be consumed by an ordered filter or the
  page fails instead of silently losing semantics.

The current experimental branch has started M2 with `build --format pdf`, one
structured `latexmk` recipe with a root-selected PDF engine, slot-shaped `pdfs/` outputs, incremental
fingerprints, a candidate manifest, atomic publication, failure preservation,
and a real `doctor` compile probe. Arbitrary and multiple recipes remain later
M2 work.
