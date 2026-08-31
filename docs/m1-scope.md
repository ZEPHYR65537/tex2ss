# M1 scope

M1 is the reliable HTML core. It includes scaffold creation, strict diagnosis,
physical bundle discovery, global preflight SiteIndex construction, controlled
LaTeX includes, direct Pandoc 3.11 conversion, ordered trusted Lua filters,
Hakyll templates/routes/assets, transactional output, and local watch/serve.

M1 intentionally does not freeze or emulate unfinished contracts:

- `build --format pdf` reports that PDF belongs to the immediate M2 milestone.
- generators, post analyzers, virtual bundles, and virtual routes are not
  exposed.
- deploy providers and deploy Lua scripts are not exposed.
- selective slot/regex builds are not exposed; `--all` is the default.
- unsupported contentful RawTeX must be consumed by an ordered filter or the
  page fails instead of silently losing semantics.

M2 must reuse the same bundle identity, SiteIndex, GeneratedContent model,
dependency model, candidate directories, manifest, and failure-preserving
commit mechanism when unified PDF management is added.
