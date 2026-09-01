# M1 scope

M1 is the reliable HTML core. It includes scaffold creation, strict diagnosis,
physical bundle discovery, global preflight SiteIndex construction, controlled
LaTeX includes, direct Pandoc 3.11 conversion, ordered trusted Lua filters,
Hakyll templates/routes/assets, transactional output, and local watch/serve.

The M1 baseline intentionally did not freeze or emulate unfinished contracts:

- generators, post analyzers, virtual bundles, and virtual routes were not
  part of the M1 contract.
- deploy providers and deploy Lua scripts are not exposed.
- selective slot/regex and force-rebuild flags are not exposed. A normal build
  considers every bundle selected by visibility while retaining incremental
  caches; there is no misleading no-op `--all` flag.
- unsupported contentful RawTeX must be consumed by an ordered filter or the
  page fails instead of silently losing semantics.

The current experimental branch has started M2 with `build --format pdf`, one
structured `latexmk` recipe with a root-selected PDF engine, slot-shaped `pdfs/` outputs, incremental
fingerprints, a candidate manifest, atomic publication, failure preservation,
and a real `doctor` compile probe. Arbitrary and multiple recipes remain later
M2 work. Later experimental M2 slices add block generators and upward-only
`post_analyzer` exports without changing the M1 baseline or adding virtual
bundles.
