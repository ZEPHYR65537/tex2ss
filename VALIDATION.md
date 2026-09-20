# Local validation — static-site 0.2.0

Observed on 2026-09-20 with Emacs 31.1, Windows, TeX Live 2025/make4ht 0.4d and Node 24.19.0. The declared Emacs minimum remains 28.1; other versions and operating systems were not exercised.

| Check | Observed result |
| --- | --- |
| Three runtime modules and adapters | Byte compilation passed |
| Package workflow regression suite | 37/37 passed, including real child processes and loopback servers; about 18 seconds |
| Two adapters in the same session | Correct root/backend/output in both load orders; directory-local overrides preserved |
| Temporary environments | Both asynchronous steps and completion callback saw the captured environment and executable path |
| Generic framework/static-file projects | Ordered pre-build, build, post-build and verify steps; custom working directory; nil build supported |
| Preview | Delayed readiness, instance/root/backend identity, port conflict, bounded request timeout, error/recovery, cancellation and externally owned server preservation passed |
| Source diagnostics | Native make4ht and mapped GNU diagnostics navigated to the original file/line, including spaces in filenames |
| Metadata/templates | Context-sensitive keys/enums, nested braced metadata, comments, literal templates and cursor placement passed |
| Native make4ht alone | Generated content, mathematics, HTML and snapshot smoke passed in 3.32 seconds |
| Native make4ht extension mechanisms | `.cfg`, `.mk4`, Lua filter, `inlinecss` and outer generation script passed together in 2.62 seconds |
| Two live blog previews | Both ran in one Emacs session; saving one fixture refreshed only its EWW buffer; a real undefined TeX command reported original source line 8; recovery and independent stopping passed |

The two-project integration against the installed shared package took 30.17 seconds with warm caches; the earlier run including initial builds took 116.39 seconds. Temporary articles were removed and both projects rebuilt successfully. Original authored files and the original `jddblog/` checkout were not edited. Local preview tests choose their own ephemeral ports.

After the cache-key correction, warm 53-page builds converted zero TeX documents: 1.03 seconds for the standalone renderer and 2.62 seconds for Astro. Both output verifiers passed (1,759 and 1,812 links respectively). These are local observations, not performance guarantees.

The installed package is now the shared dependency. Blog repositories retain project adapters and their own build/native make4ht files; duplicate package modules and tests have been removed. Tests do not require a running user's Emacs session. Windows process-tree cleanup tests require permission to stop their own child processes.

Build processes and HTTP checks are asynchronous. There is one request at a time per preview and no package-owned recursive source watcher. Source caching remains the generator's responsibility; the blog pipelines use relative cache keys so Windows drive-letter capitalization does not invalidate every document. Snapshot validation/copying still runs synchronously and can pause Emacs for large output trees.

Native compatibility demonstrates coexistence with the tested make4ht mechanisms, not universal compatibility with every third-party extension. Plain HTTP servers have availability checks; project/backend verification and EWW revision refresh require the optional status decoder. The blog server supplies that decoder contract.

No live deployment occurred. Rsync is absent from this Windows PATH and no destination was supplied. SSH argument enforcement, snapshot ownership and transfer state transitions are tested offline; actual authentication, remote permissions and synchronization still require a test against the intended server. This package does not provide atomic deployment or rollback.
