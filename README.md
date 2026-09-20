# static-site.el

A general-purpose Emacs package for building, previewing and publishing static-file projects. It works with make4ht alone, make4ht followed by Astro, or other generators. It has no dependency on the author's blog, Node.js, Astro, or a particular layout. The two blog candidates carry identical copies of the package plus a small blog adapter.

This is version 0.1.0, tested locally with Emacs 31.1 on Windows. The declared minimum is Emacs 28.1; other Emacs/OS combinations still need testing. It is not a claim of production-proven reliability.

## Install

Put this directory on `load-path` in your own Emacs configuration:

```elisp
(add-to-list 'load-path "/absolute/path/to/emacs-static-site")
(require 'static-site)
```

On Windows use forward slashes, for example `D:/tools/emacs-static-site`. No installation changes your Emacs configuration automatically. The only required package is this single `static-site.el` file; tests and examples are optional.

For a Purcell-style configuration using local `pkg/` packages, place this
directory at `~/.emacs.d/pkg/static_site/`, copy
`integration/init-static-site.el` into `~/.emacs.d/lisp/`, and add
`(require 'init-static-site)` to your existing `lisp/init-local.el`.
This follows the local `init-*` module convention and autoloads the commands;
it does not replace `package.el`, change ELPA settings, or load EWW during
startup just for this package. Project settings remain local to each project.

Enable `M-x static-site-mode` in project buffers for these keys:

| Key | Action |
| --- | --- |
| `C-c s c` | Run generators, build, then optional validation |
| `C-c s s` / `C-c s q` | Start / stop this project's preview process |
| `C-c s b` / `C-c s e` | Open browser / EWW |
| `C-c s f` / `C-c s o` | Manage project files / inspect output in Dired |
| `C-c s d` | Build, validate, snapshot and preview deployment |
| `C-c s p` | Confirm publication of the reviewed snapshot |
| `C-c s k` | Cancel this project's active job |

All commands are also available through `M-x`. Diagnostic buffers have the project root in their names. Jobs and deployment plans are separate for each project, so independent projects can run concurrently. Load project configuration with normal Emacs directory-local variables; these command settings are intentionally not marked automatically safe.

## Direct make4ht usage

Open a `.tex` file and run `M-x static-site-make4ht-setup`. This configures that buffer for the directory containing the file, using:

```text
make4ht -x -f html5 -d public/ -B .cache/make4ht main.tex mathml
```

Then use `M-x static-site-build`. The entry file is automatically `main.html` for `main.tex`, or `index.html` for `index.tex`. The default uses MathML so ordinary formulas do not require a bitmap-conversion toolchain; customize `static-site-make4ht-tex4ht-options` to use MathJax or other TeX4ht options. Generated files are managed in `public/`; intermediate files stay under `.cache/make4ht/`. The setup command only sets buffer-local variables. To persist settings across buffers and sessions, put settings like these in a project's `.dir-locals.el`:

```elisp
((nil . ((static-site-build-command . ("make4ht" "-x" "-f" "html5"
                                     "-d" "public/" "-B" ".cache/make4ht" "index.tex" "mathml"))
         (static-site-public-directory . "public/")
         (static-site-entry-file . "index.html")
         (static-site-preview-command . ("python3" "-m" "http.server" "8000"
                                       "--bind" "127.0.0.1" "--directory" "public"))
         (static-site-preview-url . "http://127.0.0.1:8000/"))))
```

Use `python` instead of `python3` if that is your interpreter's name. In a directory without an Emacs project, also set `static-site-root` to its absolute path. Build first, then start this example server. Python's simple server does not watch files or refresh the browser; rebuild and refresh when desired. A user-supplied watching preview command can provide those features without another watcher inside Emacs. Set `static-site-preview-watches` to `t` when that command also builds files, to prevent competing builds from this package.

Make4ht remains the real build system. Its `.cfg` mappings, `.mk4` Lua build files, filters, extensions, engines, modes, and extra TeX4ht arguments are available through the ordinary command line. For example:

```elisp
(setq-local static-site-build-command
            '("make4ht" "-x" "-f" "html5+common_domfilters"
              "-c" "web.cfg" "-e" "build.mk4" "-m" "draft"
              "-d" "public/" "-B" ".cache/make4ht" "index.tex" "mathjax"))
```

No `--shell-escape` is enabled automatically. Use a make4ht build file or your own orchestration script for a multi-document project, navigation, asset copying, or special build ordering. See the [make4ht documentation](https://github.com/michal-h21/make4ht#readme).

## Script plugins and optional frameworks

A plugin is an ordinary executable script plus its arguments. The minimal extension mechanism is an ordered list:

```elisp
(setq-local static-site-generators
            '(("figures" "python3" "scripts/figures.py")
              ("catalog" "node" "scripts/catalog.mjs")))
```

These scripts run before `static-site-build-command`; `static-site-verify-command`, if set, runs afterward. A nonzero exit stops all later steps, including deployment. Commands receive the project root as their working directory. There is no shell string interpolation. To use a shell pipeline, explicitly run your own script with its interpreter.

Scripts decide their inputs, outputs, caches, asset management and dependencies. There is no registration service, plugin discovery, dependency solver, special serialization format, or enforced template system. Do not put passwords or private key contents in command arguments: commands are shown in the diagnostics buffer.

For example, make4ht can generate content first and Astro can build the final site:

```elisp
(setq-local static-site-generators
            '(("tex-content" "node" "scripts/convert-tex.mjs"))
            static-site-build-command '("node" "node_modules/astro/bin/astro.mjs" "build")
            static-site-verify-command '("node" "scripts/verify.mjs")
            static-site-public-directory "dist/"
            static-site-preview-command
            '("node" "node_modules/astro/bin/astro.mjs" "dev" "--host" "127.0.0.1")
            static-site-preview-url "http://127.0.0.1:4321/"
            static-site-preview-watches t)
```

The named scripts in this example are yours to implement. An Astro dev server alone does not necessarily rerun a TeX generator; make that behavior part of your preview script if needed. You may instead put the complete pipeline into one script. The blog adapters demonstrate that approach.

## SSH deployment

Deployment syncs the **contents** of `static-site-public-directory` into the configured server directory. Both ends need a maintained rsync installation, and the client needs compatible OpenSSH. A native Windows Emacs needs a Windows-compatible rsync/SSH pair on PATH (or explicit executable paths); it does not automatically call WSL or translate WSL paths. The current development machine has OpenSSH but no rsync on PATH, so remote transfer has not been tested there. Running Emacs and both tools together inside WSL/Linux is another option.

Use a dedicated non-root deployment account with write access only to the site's intended directory. Create that directory through your normal server administration process. It must not contain server-side uploads or other application data if you enable deletion. This package does not configure nginx, provision SSH accounts, issue HTTPS certificates, or install rsync remotely. It uses normal rsync-over-SSH; the old blog's Python forced-command receiver is a different protocol and cannot be reused as this command's endpoint.

Configure non-secret connection metadata in your private Emacs configuration:

```elisp
(setq-default static-site-deploy-host "my-static-site"
              static-site-deploy-directory "/srv/www/my-site/"
              static-site-ssh-config (expand-file-name "~/.ssh/static-sites.conf")
              static-site-deploy-delete nil)
```

Different projects can set their own buffer/directory-local values. Use an SSH alias for IPv6. Remote directory names may contain letters, numbers, spaces, dots, underscores and hyphens; root, traversal, wildcard and shell syntax are rejected. Public output must remain inside the project, outside the snapshot cache's ancestors, and contain a nonempty configured entry file. Symlinks and special files are rejected rather than followed into unrelated files.

An example private SSH config is:

```sshconfig
Host my-static-site
    HostName YOUR_SERVER
    User YOUR_DEPLOY_USER
    Port 22
    IdentityFile ~/.ssh/static_site_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile ~/.ssh/static_site_known_hosts
    StrictHostKeyChecking yes
    ForwardAgent no
```

Create a passphrase-protected SSH key and load it into your compatible SSH agent outside Emacs (`ssh-add`). Obtain the server's host key or fingerprint through a trusted server console or administrator and verify it before placing the key in the configured known-hosts file. For nonstandard ports, the known-hosts name is `[hostname]:port`. Do not blindly trust `ssh-keyscan` output. Configure `ProxyJump` in your own SSH config when needed, and verify the jump host independently.

The package enforces strict host checking, public-key authentication, batch mode, no agent forwarding, no configured port forwarding, and fresh non-multiplexed SSH connections. Unknown/changed host keys, missing agent keys, or a bad connection fail instead of asking for passwords or silently accepting a host. Ports, identity paths and jump hosts remain OpenSSH's responsibility. These choices follow the [OpenSSH configuration manual](https://man.openbsd.org/ssh_config).

1. Save project files and stop any preview process that builds into the same output directory, including servers started outside this package.
2. Run `M-x static-site-deploy-preview`. It builds, validates, takes a snapshot, and connects to show rsync's actual dry run. It does not modify the remote site.
3. Review the diagnostics. Run `M-x static-site-deploy-publish` to confirm the displayed destination and publish that snapshot. Later source edits and Emacs deployment-variable changes do not change the prepared snapshot or captured command; run another preview when you want different content or options. SSH aliases and configuration remain external, so preview again if you change them.

Set `static-site-deploy-delete` to `t` **before the preview** if you want mirroring, including removal of stale remote files. Deletion is off by default. A declined confirmation preserves the plan; `static-site-deploy-forget` discards it. Plans are kept in memory for the Emacs session. Snapshots live under `.cache/static-site-deploy-*` and are removed on failure, completed publication, replacement or explicit discard. A crashed/killed Emacs can leave a snapshot there for manual cleanup. Do not edit snapshot files.

Rsync uses its incremental transfer algorithm, protected arguments and delayed file replacement; it does not upload a full archive for every change. The snapshot requires one local copy of the generated site. Copying and filesystem validation currently run in Emacs, so very large outputs can briefly block its UI. Build scripts should provide their own incremental caching. The package prevents overlapping jobs within one Emacs process; it does not coordinate independent editors or external build processes.

This is file synchronization, **not an atomic whole-site release or rollback system**. A failure during publication can leave some files updated. A dry run is not a lock on the remote directory: other deployers can change it before publication. Re-run preview after a failure, and use server backups or a release-directory deployment script if your project requires stronger semantics. See the [rsync manual](https://download.samba.org/pub/rsync/rsync.1).

## Checks

```text
emacs --batch -Q -L . -f batch-byte-compile static-site.el
emacs --batch -Q -L . -l static-site-tests.el
emacs --batch -Q -L . -l check-make4ht.el
emacs --batch -Q -L . -l check-extensions.el
```

The offline tests exercise actual asynchronous child processes, failure/cancellation, ordered script plugins, independent projects, command/path validation, SSH options, snapshot isolation, dry-run failure, and confirmation behavior. The optional `check-make4ht.el` requires TeX Live and compiles a temporary document with plugin-generated content and mathematics, then prepares a local snapshot. `check-extensions.el` additionally verifies that a pre-build script works together with native TeX4ht `.cfg` configuration, a make4ht `.mk4` build file, a Lua output filter, and the named `inlinecss` extension; it checks the resulting HTML for each transformation. This establishes coexistence with those native mechanisms, not a promise that every third-party extension is compatible. These checks do not contact a server or claim a tested remote deployment. The blog directories additionally contain adapter tests and a local build/EWW refresh integration check.

## Repository ownership

The installed `~/.emacs.d/pkg/static_site/` directory is an independent Git
repository. The surrounding Emacs configuration ignores this directory and
retains only its `lisp/init-static-site.el` loader and the corresponding
`init-local.el` entry. Work on the package in this checkout; workspace copies
and the two blog adapters are snapshots and are not synchronized automatically.

The local branch is `static-site`. Its `origin` is
`https://github.com/ZEPHYR65537/tex2ss.git`, reserved for later publication to a
new branch. This package has an independent initial history; it was not based
on tex2ss's existing branches. No upstream tracking branch is configured yet.

When ready, choose an unused remote branch name and push explicitly:

```sh
git push -u origin HEAD:refs/heads/YOUR_NEW_BRANCH
```

Replace `YOUR_NEW_BRANCH` with the chosen name. Keep package changes separate
from commits in the parent Emacs configuration repository.
