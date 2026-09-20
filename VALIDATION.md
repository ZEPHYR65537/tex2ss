# Local validation — 2026-09-20

Tested with Emacs 31.1, Windows, TeX Live 2025/make4ht 0.4d, and the existing Node-based comparison projects. These are observed local results, not a cross-platform or production guarantee.

| Check | Result |
| --- | --- |
| Byte compilation with warnings treated as errors | Passed for the standalone package and both blog adapters |
| Standalone ERT regression suite | 20/20 passed; final run at 20:33 Asia/Shanghai |
| Blog adapter tests | 3/3 passed in each comparison branch |
| Direct make4ht, no framework | Script plugin generated TeX, make4ht produced MathML/HTML, and a publish snapshot retained the content; 5.48 seconds |
| Native extension compatibility | Outer script + `.cfg` + explicit `.mk4` + Lua filter + named `inlinecss` extension passed together; 2.56 seconds; HTML assertions checked the actual transformations |
| make4ht branch integration | Build + validation, real EWW rendering, source save -> rebuild -> EWW refresh, restoration of source bytes, and preview shutdown passed |
| Astro branch integration | Same checks passed with the Astro build pipeline |
| Package copies | Standalone and both branch copies of `static-site.el` are byte-identical |

The regression suite includes real asynchronous processes, nonzero exits, cancellation, argument safety, output/destination path guards, script ordering, separate project state, SSH security flags, snapshot isolation, dry-run failure and publishing confirmation. Windows process-tree cancellation tests run outside the restricted execution sandbox; they terminate only test-owned processes.

Full first builds took about 122 seconds (make4ht) and 128 seconds (Astro) in this environment. Observed warm build + validation times were 3.09–6.96 seconds for make4ht and 8.14 seconds for Astro, each for the existing 53-page collection. These timings depend on the generator's cache, hardware and concurrent work. The package runs external jobs asynchronously and avoids duplicate jobs per project; it does not provide its own TeX cache. Snapshot validation and copying remain synchronous filesystem operations.

Remote rsync transfer was **not** exercised: no destination was supplied and rsync is absent from the current Windows PATH. SSH/rsync arguments and the transfer state machine were tested offline, with transfer execution substituted in those tests. Server authentication, permissions, Windows rsync compatibility, network interruption recovery and real remote mirroring still need an integration check against the intended server.

Native compatibility means the outer script mechanism coexists with make4ht's own build and extension machinery. It is not itself the make4ht extension API, and untested third-party extensions may have their own requirements.

No site was deployed. The original `jddblog/` checkout was not edited. Temporary source edits in both comparison projects were restored. Existing preview servers were left alone; integration checks used their own loopback ports 45173 and 45174.
