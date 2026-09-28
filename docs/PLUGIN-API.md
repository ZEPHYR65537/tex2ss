# Site plugins: API version 1

Available in static-site 0.3.0. A plugin is a trusted, explicitly loaded Lisp file. It is not a sandbox and is not discovered automatically. Simple projects can still use directory-local command variables without a plugin.

## A second generator, without blog code

Save this as `site-plugin.el` at your own site's root (enable lexical binding). Supply your own `build.py`, which writes `public/index.html`:

```elisp
;;; site-plugin.el --- My static site -*- lexical-binding: t; -*-
(require 'static-site)
(let ((root (file-name-directory (or load-file-name buffer-file-name)))
      (python (or (executable-find "python3") (executable-find "python"))))
  (unless python (error "Python is required for this site's generator"))
  (static-site-register-plugin
   root 'plain-html
   (list :api-version 1
         :settings `((static-site-backend . "plain-html")
                     (static-site-public-directory . "public/")
                     (static-site-entry-file . "index.html")
                     (static-site-preview-command .
                       (,python "-m" "http.server" "8000" "--bind" "127.0.0.1"
                                "--directory" "public"))
                     (static-site-preview-url . "http://127.0.0.1:8000/"))
         :actions (list
                   (cons 'build
                     (lambda (context done)
                       (static-site-run-job context
                         (list :argv (list python "build.py")) done))))
         :templates '(("section" . "<section>\n{{point}}\n</section>")))))
```

Load that trusted file, visit a source file, enable `static-site-mode`, then run `static-site-build`. Build before starting this ordinary Python server. It has no build watcher or revision protocol; refresh after rebuilding. No TeX, Node, rsync or deployment provider is required by the framework.

## Registration and ownership

`static-site-register-plugin ROOT ID SPEC` accepts `:api-version 1`, `:settings`, `:actions`, `:preview`, `:templates`, `:keymap`, `:setup`, `:teardown` and `:replace`. Settings are an alist of public `static-site-*` variables. Explicit buffer/directory locals override plugin defaults. Registration replaces the same root/ID; conflicting action or template names from different plugins require those names in `:replace`.

`static-site-context` returns a captured plist with `:root`, `:backend`, `:buffer`, `:file`, `:directory`, `:environment`, `:exec-path`, `:settings` and `:plugins`. Treat it as read-only. Function objects and lexical closures are captured so later plugin loads cannot replace running providers. A helper called by symbol inside such a closure is still ordinary Lisp: avoid global mutable site configuration and version-dependent shared helper names.

`static-site-projects` lists registered roots. `static-site-action-available-p` checks registered providers; built-in build/verify defaults remain available through `static-site-invoke-action` even without a provider. `static-site-log CONTEXT TEXT` appends project diagnostics. Do not log secrets.

## Actions and asynchronous jobs

An `:actions` entry is `(ACTION . PROVIDER)`. A provider is either a job spec or a function `(lambda (context done) ...)`. `static-site-invoke-action ACTION &optional CONTEXT` acquires the root's lock **before** invoking the provider, including asynchronous preflight. It returns an opaque action token; use `static-site-cancel` for cancellation. Run jobs only from an active action's context.

`static-site-run-job CONTEXT SPEC DONE` accepts:

- `:argv`: a list of executable and literal arguments; no implicit shell.
- `:directory`: working directory relative to the root, default `.`.
- `:steps`: alternatively, a list of `(ABSOLUTE-DIRECTORY . ARGV)` pairs, run serially.
- `:environment`: alist of environment overrides (nil unsets a variable).

`DONE` receives a plist containing `:status success`, `error` or `cancelled`, optionally a message. Call the provider's completion exactly once. The framework ignores late completion after cancellation and rejects jobs started from expired contexts. Do not perform slow synchronous subprocess or network work in a provider. Windows cancellation is asynchronous: a stopping process retains ownership until its tree exits. Different roots have independent locks; a watching preview blocks independent builds of the same output.

For a staged provider, call `static-site-preview-probe CONTEXT CALLBACK` first. Its callback receives `:status absent`, `occupied`, `matching`, `timeout` or `error`; inspect it before starting a job. Probe coalesces with an existing session request. `static-site-preview-state` returns a snapshot. Neither exposes mutable internal state.

Deployment is optional. Register actions such as `deploy-preview` and `deploy-publish` to use another deployment client. The provider owns target selection, review/confirmation and plan validation. The blog uses its existing restricted receiver and plan ID. Legacy rsync commands lazily load `static-site-deploy-rsync.el`; its snapshot worker also requires `static-site-snapshot.el`. No deployment is implied by registration or build.

## Local editing contributions

`:setup` receives a context in the enabled buffer and returns an opaque value. `:teardown` receives `(context value)`. For additive local list settings use `static-site-buffer-contribute VARIABLE VALUES` and pass its token to `static-site-buffer-withdraw`; cleanup removes only the contributed entries and preserves later user additions. Failed setup is rolled back. Do not mutate shared lists or use `setq-default`.

`:keymap` composes a buffer-local minor-mode override, with explicit user overrides taking precedence. Teardown runs on disable, major-mode change, buffer death and plugin reload. A changed root is reconciled at the next `static-site-context`/action or mode re-enable; there is no per-keystroke project scan.

Templates accept literal `{{point}}` text or insertion functions. `static-site-expand-snippet TEXT FALLBACK` uses `yas-expand-snippet` only when YAS is already active, otherwise inserts the literal fallback. It never installs global snippet tables. AUCTeX contributions are optional, buffer-local and owned by the site adapter; ordinary LaTeX buffers receive no changes.

## Preview performance

The optional decoder may add `:page-revisions`, an alist mapping routes to final HTML hashes, to the existing identity/readiness/revision response. Unchanged current pages then skip EWW reloads. Without it, the framework uses the global revision. Hidden EWW buffers become dirty and reload on display. The server owns watching and building; Emacs's local save hook only requests earlier status checking.

Requests coalesce per session. Idle intervals back off to 30 seconds; save bursts poll at 0.4 seconds for eight seconds, startup/building at 0.3 seconds. Metadata completion scans at most 20,000 characters once, respecting nesting, escapes and comments. Rsync snapshot validation/copy runs in a batch Emacs worker; its publication precheck still scans synchronously.

## Validation

Use `emacs --batch -Q -L . -l check-api.el` and `check-workflow.el`. The API tests include a real nonblog generator, captured environments, preflight cancellation, late callbacks, conflicts, reload/root isolation, local cleanup, bounded completion, request coalescing and hidden EWW. Validated on Emacs 31.1/Windows; Emacs 28.1 and other operating systems remain compatibility targets, not newly verified platforms.
