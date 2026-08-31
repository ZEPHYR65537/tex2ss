# tex2ss

tex2ss is a LaTeX-first static site generator written in Haskell. It reads each
physical `index.tex` + `meta.json` bundle through Pandoc, applies ordered Lua
filters in process, and lets Hakyll route and template the resulting semantic
HTML.

The repository implements the accepted M1 contract: HTML builds first, with
PDF support as the immediately following milestone. Public implementation
contracts are documented under `docs/`.

## Development

The project pins exact Hakyll and Pandoc source commits in `cabal.project`.

```console
cabal build all
cabal test all
cabal run tex2ss -- --help
```

The initial command surface is:

```text
tex2ss new site NAME [--parent PATH]
tex2ss init [PATH]
tex2ss new view SLOT
tex2ss doctor [PATH]
tex2ss build [--format html] [--include-drafts]
tex2ss serve [--host 127.0.0.1] [--port 8000] [--include-drafts]
```

M1 intentionally rejects PDF builds and does not expose generators, analyzers,
virtual bundles, deployment, or selective-build APIs before those contracts are
settled.

See [the architecture](docs/architecture.md), [schema v1](docs/schemas.md), and
[the explicit M1 boundary](docs/m1-scope.md) for implementation contracts.
