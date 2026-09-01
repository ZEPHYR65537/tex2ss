# Post-analysis tree

This fixture shows the v1 upward-only analysis flow:

1. `chapter` and `chapter/topic` are ordinary physical bundles.
2. Their ordered filter appends `filtered` to the first heading.
3. Their `post_analyzer` reads that filtered Pandoc AST and exports an open
   `example.outline@1` value.
4. The root bundle explicitly reads that namespace and its generator builds a
   nested `pandoc_blocks` tree before the root document is parsed.

From this directory, run:

```console
tex2ss build --format html
tex2ss build --format pdf
```

The root output contains `Child source filtered` with the grandchild nested
under it. No virtual bundle is created, and the Lua scripts never write
`public/` or `pdfs/`.

