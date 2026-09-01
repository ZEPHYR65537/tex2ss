# M1 scope

M1 is the reliable HTML core. It includes scaffold creation, strict diagnosis,
physical bundle discovery, global preflight SiteIndex construction, controlled
LaTeX includes, direct Pandoc 3.11 conversion, ordered trusted Lua filters,
Hakyll templates/routes/assets, transactional output, and local watch/serve.

The M1 baseline intentionally did not freeze or emulate then-unfinished contracts:

- generators, post analyzers, virtual bundles, and virtual routes were not
  part of the M1 contract.
- deployment and selective-build APIs were not part of M1.
- unsupported contentful RawTeX must be consumed by an ordered filter or the
  page fails instead of silently losing semantics.

Subsequent milestones added the structured PDF target, view-owned content
plugins, selective builds, and explicit deployment. The old generator and
upward namespace experiment was superseded rather than made compatible. This
document remains a historical boundary, not the current feature list.
