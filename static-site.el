;;; static-site.el --- Build, preview and publish static sites -*- lexical-binding: t; -*-

;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, web

;;; Commentary:
;; Configure these variables in your init file or trusted directory locals.
;; Commands are argument lists, never shell expressions.  The preview command
;; supplies the HTTP server and any file watching.  Publishing uses rsync/SSH.
;; See README.md in this directory for setup and platform requirements.

;;; Code:
(require 'cl-lib)
(require 'compile)
(require 'project)
(require 'subr-x)
(require 'eww)
(require 'browse-url)
(require 'ansi-color)

(declare-function projectile-project-root "projectile")
(defvar projectile-require-project-root)
(defvar static-site-mode-map)
(declare-function static-site-preview-start "static-site-preview")
(declare-function static-site-preview-stop "static-site-preview")
(declare-function static-site-preview-browser "static-site-preview")
(declare-function static-site-preview-eww "static-site-preview")
(declare-function static-site-author-mode "static-site-author")
(declare-function static-site-insert-template "static-site-author")
(declare-function static-site-new-article "static-site-author")

(defgroup static-site nil "Build and publish static websites." :group 'tools)
(defcustom static-site-root nil
  "Project directory, or nil to use the current Emacs project."
  :type '(choice (const nil) directory))
(defcustom static-site-build-command nil
  "Build program and arguments.  For example: (\"node\" \"build.mjs\")."
  :type '(repeat string))
(defcustom static-site-backend "static"
  "Project-defined build target identifier, also checked by preview adapters."
  :type 'string)
(defcustom static-site-error-regexp-alist nil
  "Optional project-specific `compilation-error-regexp-alist'.
Nil uses standard compiler diagnostics plus make4ht's native error table.
A staging adapter that emits mapped GNU diagnostics can use (gnu)."
  :type '(choice (const nil) (repeat sexp)))
(defcustom static-site-build-directory "."
  "Working directory for build scripts, relative to the project root."
  :type 'directory)
(defcustom static-site-environment nil
  "Project environment overrides as (NAME . VALUE) pairs.
Nil VALUE unsets a variable.  Values are not printed in diagnostics.
The environment and executable search path are captured for the whole job."
  :type '(alist :key-type string :value-type (choice string (const nil))))
(defcustom static-site-exec-path nil
  "Extra executable directories, relative to the root, prepended to PATH."
  :type '(repeat directory))
(defcustom static-site-post-build-generators nil
  "Ordered (NAME PROGRAM ARGUMENT...) scripts after the build, before validation."
  :type '(repeat (cons string (repeat string))))
(defcustom static-site-generators nil
  "Ordered script plugins, each (NAME PROGRAM ARGUMENT...).
They run in the project root before the build.  A nonzero exit stops
the pipeline.  Scripts own their input/output conventions and caching;
the package does not impose a template engine, registry or plugin protocol."
  :type '(repeat (cons (string :tag "Name") (repeat string))))
(defcustom static-site-verify-command nil
  "Optional validation program and arguments, run after the build."
  :type '(repeat string))
(defcustom static-site-public-directory "public/"
  "Generated site directory, relative to the project root."
  :type 'string)
(defcustom static-site-entry-file "index.html"
  "Nonempty entry file required in generated output before publishing.
For a make4ht document this can be main.html instead of index.html."
  :type 'string)
(defcustom static-site-make4ht-program "make4ht"
  "Make4ht executable used by `static-site-make4ht-setup'."
  :type 'string)
(defcustom static-site-make4ht-options '("-x" "-f" "html5")
  "Options used by `static-site-make4ht-setup'.
Use make4ht's own -c configuration, -e build file, -m mode and extensions.
No shell escape is enabled automatically.  You can replace the entire
build command for multiple documents or a framework pipeline."
  :type '(repeat string))
(defcustom static-site-make4ht-tex4ht-options "mathml"
  "Optional TeX4ht options passed after the input filename.
The default uses MathML instead of requiring bitmap conversion for formulas.
Set to mathjax, another TeX4ht option string, or nil for TeX4ht's default."
  :type '(choice (const nil) string))
(defcustom static-site-preview-command nil
  "Local preview server program and arguments; it may also build and watch."
  :type '(repeat string))
(defcustom static-site-preview-url "http://127.0.0.1:8000/"
  "URL opened by the generic preview commands."
  :type 'string)
(defcustom static-site-preview-watches nil
  "Whether the preview server writes build output.
Stop a watching server before a separate build or deployment."
  :type 'boolean)
(defcustom static-site-deploy-host nil
  "SSH host alias or user@host.  Use an SSH alias for IPv6 hosts."
  :type '(choice (const nil) string))
(defcustom static-site-deploy-directory nil
  "Absolute POSIX directory dedicated to this site on the server."
  :type '(choice (const nil) string))
(defcustom static-site-deploy-delete nil
  "Also remove remote files absent from the reviewed snapshot.
Disabled by default.  Set before running the deployment preview."
  :type 'boolean)
(defcustom static-site-rsync-program "rsync"
  "Rsync executable, without arguments."
  :type 'string)
(defcustom static-site-ssh-program "ssh"
  "OpenSSH executable compatible with the chosen rsync."
  :type 'string)
(defcustom static-site-ssh-config nil
  "Optional private SSH configuration file, outside the repository.
Nil uses OpenSSH's normal configuration.  Set ports, identity files,
known hosts and jump hosts there, never passwords or private key contents."
  :type '(choice (const nil) file))

(dolist (variable '(static-site-root static-site-build-command static-site-generators
                    static-site-backend static-site-build-directory
                    static-site-error-regexp-alist
                    static-site-environment static-site-exec-path static-site-post-build-generators
                    static-site-verify-command static-site-public-directory
                    static-site-entry-file static-site-make4ht-program static-site-make4ht-options
                    static-site-make4ht-tex4ht-options
                    static-site-preview-command static-site-preview-url
                    static-site-preview-watches static-site-deploy-host
                    static-site-deploy-directory static-site-deploy-delete
                    static-site-rsync-program static-site-ssh-program
                    static-site-ssh-config))
  (make-variable-buffer-local variable))

(cl-defstruct (static-site--state (:constructor static-site--make-state))
  root process server watches plan preview)
(defvar static-site--states (make-hash-table :test #'equal))
(defvar static-site--projects (make-hash-table :test #'equal)
  "Explicit adapter settings indexed by canonical project root.")
(defvar-local static-site--applied-settings nil)

(defun static-site-register-project (root settings)
  "Register trusted adapter SETTINGS for ROOT without changing global defaults.
SETTINGS is an alist of static-site variables.  Directory/buffer locals take
precedence.  Loading another adapter never changes an existing project's jobs."
  (dolist (setting settings)
    (unless (and (consp setting) (symbolp (car setting))
                 (string-prefix-p "static-site-" (symbol-name (car setting))))
      (error "Invalid static-site setting: %S" setting)))
  (puthash (file-name-as-directory (file-truename root)) (copy-tree settings)
           static-site--projects))

(defun static-site--detected-root ()
  "Ask the user's project manager, then fall back to directory locals."
  (or (when (fboundp 'projectile-project-root)
        (let ((projectile-require-project-root nil))
          (projectile-project-root)))
      (when-let* ((project (project-current nil))) (project-root project))
      (locate-dominating-file default-directory ".dir-locals.el")))

(defun static-site--registered-root ()
  "Find the most specific registered project containing the current file."
  (let ((directory (file-name-as-directory
                    (file-truename (if buffer-file-name
                                       (file-name-directory buffer-file-name)
                                     default-directory))))
        found)
    (maphash (lambda (root _settings)
               (when (and (string-prefix-p root directory
                                           (eq system-type 'windows-nt))
                          (or (null found) (> (length root) (length found))))
                 (setq found root)))
             static-site--projects)
    found))

(defun static-site--configure ()
  "Apply this project's adapter defaults, respecting explicit local settings."
  (let ((settings (gethash (static-site--root) static-site--projects)))
    (dolist (setting static-site--applied-settings)
      (when (and (not (assq (car setting) settings))
                 (equal (symbol-value (car setting)) (cdr setting)))
        (kill-local-variable (car setting))))
    (setq static-site--applied-settings
          (delq nil
                (mapcar
                 (lambda (setting)
                   (let* ((variable (car setting))
                          (previous (assq variable static-site--applied-settings)))
                     (when (or (not (local-variable-p variable))
                               (and previous (equal (symbol-value variable) (cdr previous))))
                       (set (make-local-variable variable) (copy-tree (cdr setting)))
                       (cons variable (copy-tree (cdr setting)))))) settings)))))

(defun static-site--root ()
  "Return the canonical local project root."
  (let ((root (or static-site-root
                  (static-site--registered-root)
                  (static-site--detected-root)
                  default-directory)))
    (when (file-remote-p root) (user-error "Use a local checkout to build and publish"))
    (unless (file-directory-p root) (user-error "Project root does not exist: %s" root))
    (file-name-as-directory (file-truename root))))

(defun static-site--state ()
  "Return this project's independent job state."
  (static-site--configure)
  (let ((root (static-site--root)))
    (or (gethash root static-site--states)
        (puthash root (static-site--make-state :root root) static-site--states))))

(defun static-site--idle (state &optional building)
  "Reject overlapping jobs for STATE, including watchers when BUILDING."
  (when (process-live-p (static-site--state-process state))
    (user-error "A site job is already running; use M-x static-site-cancel"))
  (when (and building (static-site--state-watches state)
             (or (process-live-p (static-site--state-server state))
                 (memq (plist-get (static-site--state-preview state) :phase)
                       '(checking starting ready building error))))
    (user-error "Stop the watching preview first; it already rebuilds on save")))

(defun static-site--command (command)
  "Validate COMMAND and resolve its program without invoking a shell."
  (unless (and (consp command) (cl-every #'stringp command)
               (not (string-empty-p (car command))))
    (user-error "Configure a program and argument list for this command"))
  (let ((program (executable-find (car command))))
    (unless program (user-error "Executable not found: %s" (car command)))
    (cons program (cdr command))))

(defun static-site--build-steps (root)
  "Capture build and validation commands rooted at ROOT."
  (let* ((directory (file-name-as-directory (expand-file-name static-site-build-directory root)))
         (default-directory directory))
    (unless (and (not (file-remote-p directory)) (file-directory-p directory))
      (user-error "Build directory must exist locally: %s" directory))
    (cl-labels ((scripts (plugins)
                (mapcar (lambda (plugin)
             (unless (and (consp plugin) (stringp (car plugin)))
               (user-error "A generator plugin must be (NAME PROGRAM ARGUMENT...)"))
             (cons directory (static-site--command (cdr plugin)))) plugins)))
      (append (scripts static-site-generators)
              (when static-site-build-command
                (list (cons directory (static-site--command static-site-build-command))))
              (scripts static-site-post-build-generators)
              (when static-site-verify-command
                (list (cons directory (static-site--command static-site-verify-command))))))))

(defun static-site--environment (root)
  "Capture the effective process environment and search path for ROOT."
  (let* ((process-environment (copy-sequence process-environment))
         (extra (mapcar (lambda (path) (expand-file-name path root)) static-site-exec-path))
         (path (append extra (copy-sequence exec-path))))
    (dolist (pair static-site-environment)
      (unless (and (stringp (car pair)) (not (string-match-p "[=\0]" (car pair)))
                   (or (null (cdr pair)) (stringp (cdr pair))))
        (user-error "Invalid site environment entry"))
      (setenv (car pair) (cdr pair)))
    (when (assoc-string "PATH" static-site-environment (eq system-type 'windows-nt))
      (setq path (append extra (parse-colon-path (or (getenv "PATH") "")))))
    (when extra
      (setenv "PATH" (mapconcat #'identity (append extra (list (or (getenv "PATH") "")))
                               path-separator)))
    (cons process-environment path)))

;;;###autoload
(defun static-site-project-dispatch ()
  "Show site commands for the project selected by Projectile or project.el."
  (interactive)
  (static-site--configure)
  (set-transient-map (lookup-key static-site-mode-map (kbd "C-c s")) t)
  (message "Site %s: c build, s preview, q stop, b browser, e EWW, n article, i template, f files"
           (abbreviate-file-name (static-site--root))))

;;;###autoload
(defun static-site-make4ht-setup (file)
  "Configure this buffer for a standalone make4ht project using FILE.
The project root becomes FILE's directory.  Edit the resulting buffer-local
settings or persist them in trusted directory locals.  No files are changed."
  (interactive "fMain TeX file: ")
  (when (or (file-remote-p file) (not (file-regular-p file))
            (not (equal (file-name-extension file) "tex")))
    (user-error "Select a local .tex file"))
  (setq-local static-site-root (file-name-directory (expand-file-name file))
              static-site-entry-file (concat (file-name-base file) ".html")
              static-site-build-command
              (append (list static-site-make4ht-program) static-site-make4ht-options
                      (list "-d" static-site-public-directory
                            "-B" ".cache/make4ht" (file-name-nondirectory file))
                      (when static-site-make4ht-tex4ht-options
                        (list static-site-make4ht-tex4ht-options))))
  (message "Make4ht configured; M-x static-site-build to compile"))

;;;###autoload
(defun static-site-open-project ()
  "Manage project sources and static assets in Dired."
  (interactive)
  (dired (static-site--root)))

;;;###autoload
(defun static-site-open-public ()
  "Inspect this project's generated static files in Dired."
  (interactive)
  (static-site--configure)
  (dired (static-site--public (static-site--root))))

(defun static-site--buffer (state kind)
  "Create a project-specific diagnostics buffer for STATE and KIND."
  (let ((settings (cl-remove-if-not
                   (lambda (pair) (and (consp pair)
                                       (string-prefix-p "static-site-" (symbol-name (car pair)))
                                       (not (string-prefix-p "static-site--" (symbol-name (car pair))))))
                   (buffer-local-variables)))
        (rules static-site-error-regexp-alist)
        (command static-site-build-command)
        (directory (expand-file-name static-site-build-directory (static-site--state-root state)))
        (buffer (get-buffer-create
                 (format "*static-site %s: %s*" kind (static-site--state-root state)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer))
      (compilation-mode)
      (dolist (setting settings)
        (set (make-local-variable (car setting)) (copy-tree (cdr setting))))
      (setq-local default-directory directory
                  static-site-root (static-site--state-root state)
                  static-site-build-command command
                  compilation-error-regexp-alist
                  (or rules
                      (cons '("^\\(?:.*htlatex:[ \t]+\\)\\(.+?\\)[ \t]+\\([0-9]+\\)[ \t]+" 1 2)
                            compilation-error-regexp-alist)))
      (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t))
    (display-buffer buffer)
    buffer))

(defun static-site--log (buffer text)
  "Append TEXT when diagnostics BUFFER is still alive."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max)) (insert text)))))

(defun static-site--run (state steps buffer done)
  "Run directory/argv STEPS serially for STATE, logging to BUFFER.
Call DONE once with non-nil on success, nil on failure or cancellation."
  (static-site--idle state)
  (let ((environment (copy-sequence process-environment))
        (search-path (copy-sequence exec-path))
        (steps (copy-tree steps)))
    (cl-labels
      ((finish (ok)
         (setf (static-site--state-process state) nil)
         (static-site--log buffer (if ok "\nFinished successfully.\n" "\nFailed or cancelled.\n"))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq header-line-format (propertize (if ok "Site job succeeded" "Site job FAILED — see diagnostics")
                                                  'face (if ok 'success 'error))))
           (unless ok (display-buffer buffer)))
         (condition-case err
             (let ((process-environment (copy-sequence environment))
                   (exec-path (copy-sequence search-path))
                   (default-directory (static-site--state-root state)))
               (funcall done ok))
           (error (static-site--log buffer (format "\n%s\n" (error-message-string err)))
                  (message "Site job failed: %s" (error-message-string err)))))
       (next (remaining)
         (if (null remaining) (finish t)
           (let* ((step (car remaining))
                  (default-directory (car step))
                  (process-environment (copy-sequence environment))
                  (exec-path (copy-sequence search-path))
                  (argv (cdr step)))
             (static-site--log buffer (format "\nRunning %S\n" argv))
             (condition-case err
                 (setf (static-site--state-process state)
                       (make-process
                        :name "static-site-job" :buffer buffer :command argv
                        :filter #'compilation-filter
                        :connection-type 'pipe :coding 'utf-8-unix :noquery nil
                        :sentinel
                        (lambda (process _event)
                          (when (and (memq (process-status process) '(exit signal))
                                     (not (process-get process 'static-site-finished)))
                            (process-put process 'static-site-finished t)
                            (if (and (eq (process-status process) 'exit)
                                     (not (process-get process 'static-site-cancelled))
                                     (= (process-exit-status process) 0))
                                (next (cdr remaining))
                              (static-site--log buffer
                                                (format "Exit status: %s\n" (process-exit-status process)))
                              (finish nil))))))
               (error (static-site--log buffer (concat (error-message-string err) "\n"))
                      (finish nil)))))))
      (next steps))))

;;;###autoload
(defun static-site-build ()
  "Build and validate this project asynchronously."
  (interactive)
  (let ((state (static-site--state)))
    (static-site--idle state t)
    (let* ((context (static-site--environment (static-site--state-root state)))
           (process-environment (car context)) (exec-path (cdr context)))
      (static-site--run state (static-site--build-steps (static-site--state-root state))
                      (static-site--buffer state "build")
                      (lambda (ok) (message "Site build %s" (if ok "succeeded" "failed; see diagnostics")))))))

;;;###autoload
(defun static-site-cancel ()
  "Cancel this project's active build or transfer."
  (interactive)
  (when-let* ((process (static-site--state-process (static-site--state))))
    (process-put process 'static-site-cancelled t)
    (static-site--terminate process)))

(defun static-site--terminate (process)
  "Terminate owned PROCESS and its subprocesses where supported."
  (when (process-live-p process)
    (if (eq system-type 'windows-nt)
        (let ((taskkill (executable-find "taskkill")))
          (unless taskkill (user-error "taskkill is required to stop a Windows process tree"))
          (with-temp-buffer
            (let ((status (call-process taskkill nil t nil
                                        "/PID" (number-to-string (process-id process)) "/T" "/F")))
              ;; taskkill can report an already-exited descendant; collect the
              ;; parent's exit event before deciding whether it is still alive.
              (accept-process-output process 0.1)
              (when (and (not (eq status 0)) (process-live-p process))
                (user-error "Could not stop the site process tree: %s" (string-trim (buffer-string)))))))
      ;; Unlike deleting just the process object, this signals its process group.
      (kill-process process))))

(dolist (command '(static-site-preview-start static-site-preview-stop static-site-preview-follow static-site-preview-browser static-site-preview-eww static-site-preview-status)) (autoload command "static-site-preview" nil t))
(dolist (command '(static-site-author-mode static-site-insert-template static-site-new-article))
  (autoload command "static-site-author" nil t))

(defun static-site--destination ()
  "Validate and return the SSH destination, never a daemon URL."
  (unless (and (stringp static-site-deploy-host)
               (string-match-p
                "\\`\\(?:[[:alnum:]_][[:alnum:]_.-]*@\\)?[[:alnum:]][[:alnum:]._-]*\\'"
                static-site-deploy-host))
    (user-error "Set static-site-deploy-host to an SSH alias or user@host"))
  (let* ((path static-site-deploy-directory)
         (parts (and (stringp path) (split-string path "/" t))))
    (unless (and (stringp path) (string-prefix-p "/" path)
                 (not (string-prefix-p "//" path)) (>= (length parts) 2)
                 (cl-every (lambda (part)
                             (and (string-match-p "\\`[[:alnum:]_. -]+\\'" part)
                                  (not (member part '("." ".."))))) parts)
                 (not (member (string-remove-suffix "/" path)
                              '("/var/www" "/usr/local" "/home/root"))))
      (user-error "Set a dedicated absolute server directory, e.g. /srv/www/blog"))
    (concat static-site-deploy-host ":/" (string-join parts "/") "/")))

(defun static-site--rsh-quote (argument)
  "Quote ARGUMENT for rsync's own -e parser, not for a shell."
  (when (string-match-p "[\0\r\n]" argument) (user-error "Invalid SSH argument"))
  (concat "'" (replace-regexp-in-string "'" "''" argument t t) "'"))

(defun static-site--rsync-command (destination)
  "Capture a safe transfer command for DESTINATION."
  (let* ((ssh (car (static-site--command (list static-site-ssh-program))))
         (config (when static-site-ssh-config
                   (when (or (file-remote-p static-site-ssh-config)
                             (not (file-readable-p static-site-ssh-config)))
                     (user-error "SSH configuration must be a readable local file"))
                   (expand-file-name static-site-ssh-config)))
         (options '("BatchMode=yes" "StrictHostKeyChecking=yes" "UpdateHostKeys=no"
                    "PreferredAuthentications=publickey" "PasswordAuthentication=no"
                    "KbdInteractiveAuthentication=no" "ForwardAgent=no"
                    "ClearAllForwardings=yes" "RequestTTY=no" "ControlMaster=no"
                    "ControlPath=none" "ConnectTimeout=10" "ServerAliveInterval=15"
                    "ServerAliveCountMax=3"))
         (rsh (mapconcat #'static-site--rsh-quote
                         (append (list ssh)
                                 (cl-mapcan (lambda (option) (list "-o" option)) options)
                                 (when config (list "-F" config))) " ")))
    (append (static-site--command (list static-site-rsync-program))
            '("--recursive" "--times" "--perms" "--chmod=D755,F644"
              "--omit-dir-times" "--delay-updates" "--itemize-changes"
              "--human-readable" "--timeout=60" "-s")
            (when static-site-deploy-delete '("--delete-delay"))
            (list "-e" rsh "--" "./" destination))))

(defun static-site--public (root)
  "Resolve the configured public folder strictly inside ROOT."
  (let ((source (expand-file-name static-site-public-directory root)))
    (when (or (file-remote-p source)
              (equal (file-name-as-directory (file-truename source)) root)
              (file-in-directory-p (expand-file-name ".cache/" root) source)
              (not (file-in-directory-p (file-truename source) root)))
      (user-error "Public output must be a subdirectory of the project"))
    (file-name-as-directory source)))

(defun static-site--check-tree (directory)
  "Reject symlinks and special files anywhere under DIRECTORY."
  (when (file-symlink-p (directory-file-name directory))
    (user-error "Publish output must not contain symlinks: %s" directory))
  (dolist (entry (directory-files directory t directory-files-no-dot-files-regexp))
    (cond ((file-symlink-p entry) (user-error "Publish output contains a symlink: %s" entry))
          ((file-directory-p entry) (static-site--check-tree entry))
          ((not (file-regular-p entry)) (user-error "Not a regular publish file: %s" entry)))))

(defun static-site--snapshot (root source &optional entry-file)
  "Copy built SOURCE into a fresh private snapshot under ROOT."
  (let ((entry (expand-file-name (or entry-file static-site-entry-file) source)))
    (unless (and (file-directory-p source) (file-in-directory-p entry source)
                 (file-regular-p entry) (> (file-attribute-size (file-attributes entry)) 0))
      (user-error "Publish output needs a nonempty entry file inside it: %s" entry)))
  (static-site--check-tree source)
  (let ((cache (expand-file-name ".cache/" root)))
    (when (or (file-symlink-p (directory-file-name cache))
              (not (file-in-directory-p (file-truename cache) root)))
      (user-error "Deployment cache must stay inside this project"))
    (make-directory cache t)
    (let ((snapshot (make-temp-file (expand-file-name "static-site-deploy-" cache) t)))
      (condition-case err
          (progn (copy-directory source snapshot t t t)
                 (set-file-modes snapshot #o700)
                 snapshot)
        (error (static-site--remove-snapshot root snapshot) (signal (car err) (cdr err)))))))

(defun static-site--remove-snapshot (root directory)
  "Delete only an owned deployment snapshot DIRECTORY within ROOT."
  (when (and directory (file-exists-p directory))
    (unless (and (not (file-symlink-p directory))
                 (string-prefix-p "static-site-deploy-" (file-name-nondirectory directory))
                 (equal (file-name-directory (directory-file-name (expand-file-name directory)))
                        (expand-file-name ".cache/" root))
                 (file-in-directory-p (file-truename directory) (file-truename root)))
      (error "Refusing to remove a directory outside the deployment cache"))
    (delete-directory directory t)))

;;;###autoload
(defun static-site-deploy-forget ()
  "Discard this project's prepared deployment snapshot."
  (interactive)
  (let ((state (static-site--state)))
    (static-site--idle state)
    (static-site--remove-snapshot (static-site--state-root state)
                                 (plist-get (static-site--state-plan state) :snapshot))
    (setf (static-site--state-plan state) nil)))

;;;###autoload
(defun static-site-deploy-preview ()
  "Build, validate, snapshot, and show the remote rsync dry run.
Never change the remote site.  Only a successful dry run enables publishing."
  (interactive)
  (let* ((state (static-site--state))
         (root (static-site--state-root state)))
    (static-site--idle state t)
    (let* ((context (static-site--environment root))
           (process-environment (car context)) (exec-path (cdr context))
           (destination (static-site--destination))
           (command (static-site--rsync-command destination))
           (source (static-site--public root))
           (entry static-site-entry-file)
           (steps (static-site--build-steps root))
           (delete static-site-deploy-delete)
           (buffer (static-site--buffer state "deploy")))
      (static-site-deploy-forget)
      (static-site--log buffer (format "Destination: %s\nRemove stale files: %s\n" destination delete))
      (static-site--run
       state steps buffer
       (lambda (ok)
         (if (not ok) (message "Deployment stopped: build/validation failed")
           (let ((snapshot (static-site--snapshot root source entry)))
             (static-site--run
              state (list (cons (file-name-as-directory snapshot)
                                (append (list (car command) "--dry-run") (cdr command)))) buffer
              (lambda (success)
                (if success
                    (progn
                      (setf (static-site--state-plan state)
                            (list :snapshot snapshot :command command
                                  :environment (copy-sequence process-environment)
                                  :exec-path (copy-sequence exec-path)
                                  :destination destination :delete delete))
                      (message "Review the dry run, then M-x static-site-deploy-publish"))
                  (static-site--remove-snapshot root snapshot)
                  (message "Deployment preview failed; publishing is disabled")))))))))))

;;;###autoload
(defun static-site-deploy-publish ()
  "Confirm and publish the exact snapshot from the last successful dry run.
Later Emacs settings and builds do not change the captured command or snapshot.
SSH configuration remains external; preview again after changing it."
  (interactive)
  (let* ((state (static-site--state))
         (root (static-site--state-root state))
         (plan (static-site--state-plan state))
         (snapshot (plist-get plan :snapshot)))
    (static-site--idle state)
    (unless (and plan (file-directory-p snapshot))
      (user-error "Run M-x static-site-deploy-preview successfully first"))
    (when (yes-or-no-p
           (format "Publish reviewed snapshot to %s%s? " (plist-get plan :destination)
                   (if (plist-get plan :delete) " (including remote deletions)" "")))
      (static-site--check-tree snapshot)
      (setf (static-site--state-plan state) nil)
      (let ((process-environment (copy-sequence (plist-get plan :environment)))
            (exec-path (copy-sequence (plist-get plan :exec-path))))
        (static-site--run
       state (list (cons (file-name-as-directory snapshot) (plist-get plan :command)))
       (static-site--buffer state "publish")
       (lambda (ok)
         (static-site--remove-snapshot root snapshot)
         (message (if ok "Site published successfully"
                    "Publish failed or cancelled; remote files may be partially updated. Run a new preview."))))))))

(defvar static-site-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c s c") #'static-site-build)
    (define-key map (kbd "C-c s s") #'static-site-preview-start)
    (define-key map (kbd "C-c s q") #'static-site-preview-stop)
    (define-key map (kbd "C-c s b") #'static-site-preview-browser)
    (define-key map (kbd "C-c s e") #'static-site-preview-eww)
    (define-key map (kbd "C-c s d") #'static-site-deploy-preview)
    (define-key map (kbd "C-c s p") #'static-site-deploy-publish)
    (define-key map (kbd "C-c s f") #'static-site-open-project)
    (define-key map (kbd "C-c s o") #'static-site-open-public)
    (define-key map (kbd "C-c s k") #'static-site-cancel)
    (define-key map (kbd "C-c s n") #'static-site-new-article)
    (define-key map (kbd "C-c s i") #'static-site-insert-template)
    map))

;;;###autoload
(define-minor-mode static-site-mode
  "Opt-in commands for the current static-site project.
The configured preview command owns file watching and browser live reload."
  :lighter " Site" :keymap static-site-mode-map
  (static-site-author-mode (if static-site-mode 1 -1)))

(provide 'static-site)
;;; static-site.el ends here
