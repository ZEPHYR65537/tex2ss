# View-plugin tree

This fixture shows the LaTeX-declared, view-owned plugin flow:

1. `chapter` and `chapter/topic` are ordinary physical bundles.
2. Their ordered filter appends `filtered` to the first heading.
3. The root's `\\texssgenerated{outline}{tree}` declaration owns one plugin.
4. That plugin selects the root's strict descendants, analyzes each final
   filtered Pandoc AST, and folds those private values into a LaTeX fragment.
5. The fragment returns to the root's normal HTML/PDF rendering pipeline.
6. The child also uses the first-party audio, video, and link macros so the
   fixture exercises semantic HTML and readable TeX PDF fallbacks together.
   Native math, an equation label/reference, and a shared bibliography exercise
   the first-party reference bridge and linked citeproc as well.

From this directory, run:

```console
tex2ss build --format html
tex2ss build --format pdf
```

The root output contains both `Child source filtered` and `Grandchild source
filtered`. Each descendant is parsed and filtered once even though the root
plugin consumes its AST. No namespace bus or virtual bundle is created, and
the Lua plugin never writes `public/` or `pdfs/`.
