;;; static-site-api.el --- Root-scoped plugin and job API -*- lexical-binding: t; -*-
;;; Code:
(require 'static-site)
(declare-function static-site-preview--active "static-site-preview")
(declare-function static-site-preview--session "static-site-preview")
(declare-function static-site-preview--request "static-site-preview")
(declare-function static-site-preview--identity "static-site-preview")
(declare-function static-site-preview--close-request "static-site-preview")
(defvar static-site--plugins (make-hash-table :test #'equal))
(defvar static-site--owner nil)
(defvar-local static-site--contributions nil)
(defvar-local static-site--contribution-tokens nil)
(defvar-local static-site--installed-map nil)
(defvar-local static-site--saved-map nil)

(defun static-site--copy (value)
  "Copy data while preserving captured function objects on older Emacs too."
  (cond ((functionp value) value)
        ((consp value) (cons (static-site--copy (car value)) (static-site--copy (cdr value))))
        (t value)))

(defun static-site-projects ()
  "Return registered canonical project roots."
  (hash-table-keys static-site--projects))

(defun static-site--function (value)
  "Capture VALUE's function object, independent of later symbol redefinition."
  (if (and (symbolp value) (fboundp value)) (indirect-function value) value))

(defun static-site--plugin-settings (root)
  "Compose ROOT's registered defaults."
  (let ((settings (static-site--copy (gethash root static-site--projects))))
    (dolist (plugin (gethash root static-site--plugins))
      (dolist (pair (plist-get (cdr plugin) :settings))
        (setf (alist-get (car pair) settings) (cdr pair)))
      (dolist (pair '((:route . static-site-preview-route-function)
                      (:decode . static-site-preview-status-function)))
        (when-let* ((value (plist-get (plist-get (cdr plugin) :preview) (car pair))))
          (setf (alist-get (cdr pair) settings) value)))
      (when-let* ((templates (plist-get (cdr plugin) :templates)))
        (let ((current (static-site--copy (alist-get 'static-site-templates settings))))
          (dolist (template templates)
            (setf (alist-get (car template) current nil nil #'equal) (cdr template)))
          (setf (alist-get 'static-site-templates settings) current))))
    settings))

(defun static-site-register-plugin (root id spec)
  "Register trusted plugin ID and versioned descriptor SPEC for ROOT.
Registration starts no jobs. Duplicate actions/templates need :replace names.
Setup/teardown receive a context; setup returns an opaque teardown value."
  (unless (and (symbolp id) (= (or (plist-get spec :api-version) 0) 1))
    (error "Unsupported static-site plugin API"))
  (cl-loop for (key _value) on spec by #'cddr do
           (unless (memq key '(:api-version :settings :actions :preview :templates :keymap :setup :teardown :replace))
             (error "Unknown plugin field %s" key)))
  (let* ((root (file-name-as-directory (file-truename root)))
         (spec (static-site--copy spec))
         (others (assq-delete-all id (static-site--copy (gethash root static-site--plugins)))))
    (dolist (setting (plist-get spec :settings))
      (unless (and (consp setting) (symbolp (car setting))
                   (string-prefix-p "static-site-" (symbol-name (car setting)))
                   (not (string-prefix-p "static-site--" (symbol-name (car setting)))))
        (error "Invalid plugin setting: %S" setting)))
    (dolist (kind '(:actions :templates))
      (let ((seen nil))
        (dolist (entry (plist-get spec kind))
          (when (or (member (car entry) seen)
                    (and (cl-some (lambda (p) (assoc (car entry) (plist-get (cdr p) kind))) others)
                         (not (member (car entry) (plist-get spec :replace)))))
            (error "Duplicate plugin contribution: %s" (car entry)))
          (push (car entry) seen))))
    (dolist (key '(:setup :teardown))
      (when (plist-get spec key) (setf (plist-get spec key) (static-site--function (plist-get spec key)))))
    (dolist (entry (plist-get spec :actions))
      (setcdr entry (static-site--function (cdr entry))))
    (dolist (key '(:route :decode))
      (when (plist-get (plist-get spec :preview) key)
        (setf (plist-get (plist-get spec :preview) key)
              (static-site--function (plist-get (plist-get spec :preview) key)))))
    (unless (gethash root static-site--projects) (puthash root nil static-site--projects))
    (puthash root (append others (list (cons id spec))) static-site--plugins)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p static-site-mode)
                   (equal root (static-site--root)))
          (static-site--activate-contributions))))
    id))

(defun static-site-context ()
  "Return a project snapshot. Treat the returned plist as read-only.
Contains :root, :backend, :buffer, :settings, :environment and :plugins."
  (static-site--configure)
  (when (and (bound-and-true-p static-site-mode) static-site--contributions
             (not (equal (static-site--root) (plist-get (caar static-site--contributions) :root))))
    (static-site--activate-contributions))
  (let* ((root (static-site--root)) (environment (static-site--environment root)))
    (list :root root :backend static-site-backend :buffer (current-buffer)
          :directory default-directory :file buffer-file-name
          :environment (copy-sequence (car environment)) :exec-path (copy-sequence (cdr environment))
          :plugins (static-site--copy (gethash root static-site--plugins))
          :settings (cl-loop for symbol in (delete-dups
                              (append (mapcar #'car (get 'static-site 'custom-group))
                                      (mapcar #'car (static-site--plugin-settings root))
                                      (mapcar (lambda (entry) (if (consp entry) (car entry) entry)) (buffer-local-variables))))
                             when (and (boundp symbol) (string-prefix-p "static-site-" (symbol-name symbol))
                                       (not (string-prefix-p "static-site--" (symbol-name symbol))))
                             collect (cons symbol (static-site--copy (symbol-value symbol)))))))

(defun static-site--with-context (context function)
  "Call FUNCTION in an isolated buffer with CONTEXT's captured configuration."
  (with-temp-buffer
    (setq default-directory (plist-get context :root))
    (dolist (setting (plist-get context :settings))
      (set (make-local-variable (car setting)) (static-site--copy (cdr setting))))
    (setq-local static-site-root (plist-get context :root))
    (let ((process-environment (copy-sequence (plist-get context :environment)))
          (exec-path (copy-sequence (plist-get context :exec-path)))
          (static-site--owner (plist-get context :action)))
      (funcall function))))

(defun static-site--context-state (context)
  "Return internal state for captured CONTEXT."
  (let ((root (plist-get context :root)))
    (or (gethash root static-site--states)
        (puthash root (static-site--make-state :root root) static-site--states))))

(defun static-site-action-available-p (action &optional context)
  "Whether CONTEXT has a provider for ACTION."
  (cl-some (lambda (p) (assq action (plist-get (cdr p) :actions)))
           (plist-get (or context (static-site-context)) :plugins)))

(defun static-site-invoke-action (action &optional context)
  "Start ACTION with exclusive project ownership before any async preflight.
Providers receive (CONTEXT DONE). DONE accepts a :status result plist."
  (interactive (list (intern (completing-read "Action: "
                    (delete-dups (append '(build verify)
                      (cl-mapcan (lambda (p) (mapcar #'car (plist-get (cdr p) :actions)))
                                 (plist-get (static-site-context) :plugins)))) nil t))))
  (let* ((context (static-site--copy (or context (static-site-context))))
         (state (static-site--context-state context))
         (token (list :action action :cancelled nil :done nil :cleanups nil :finish nil :result nil))
         (providers (cl-mapcan (lambda (p) (copy-sequence (plist-get (cdr p) :actions)))
                               (plist-get context :plugins)))
         (provider (cdr (assq action (reverse providers)))))
    (static-site--idle state t)
    (unless provider
      (setq provider
            (pcase action
              ('build (lambda (ctx done)
                        (static-site--with-context ctx
                         (lambda () (static-site-run-job ctx (list :steps (static-site--build-steps (plist-get ctx :root))) done)))))
              ('verify (lambda (ctx done)
                         (static-site--with-context ctx
                          (lambda () (static-site-run-job ctx (list :argv static-site-verify-command) done)))))
              (_ (user-error "No provider for %s" action)))))
    (setf (static-site--state-action state) token
          (plist-get context :action) token)
    (let ((done (lambda (result)
                  (unless (plist-get token :done)
                    (setf (plist-get token :done) t)
                    (dolist (cleanup (plist-get token :cleanups))
                      (condition-case err (funcall cleanup)
                        (error (message "Action cleanup failed: %s" (error-message-string err)))))
                    (when (eq token (static-site--state-action state))
                      (setf (static-site--state-action state) nil))
                    (setf (plist-get token :result)
                          (if (plist-get token :cancelled) '(:status cancelled) result))
                    (message "Site %s: %s" action (plist-get (plist-get token :result) :status))))))
      (setf (plist-get token :finish) done)
      (condition-case err
          (static-site--with-context context
            (lambda ()
              (if (functionp provider) (funcall provider context done)
                (static-site-run-job context provider done))))
        (error (static-site-log context (error-message-string err))
               (funcall done (list :status 'error :message (error-message-string err))))))
    token))

(defun static-site-run-job (context spec done)
  "Run SPEC's :steps or single :argv asynchronously in captured CONTEXT.
:directory is relative to the root; :environment overrides captured variables.
DONE is called once with :status success/error/cancelled. Returns job token."
  (let* ((state (static-site--context-state context)) (token (plist-get context :action)))
    (unless (and token (eq token (static-site--state-action state)) (not (plist-get token :done)))
      (user-error "Run jobs from an active action provider"))
    (when (plist-get token :cancelled) (user-error "Action was cancelled"))
    (static-site--with-context context
      (lambda ()
        (dolist (pair (plist-get spec :environment)) (setenv (car pair) (cdr pair)))
        (let* ((directory (file-name-as-directory (expand-file-name (or (plist-get spec :directory) ".") (plist-get context :root))))
               (steps (static-site--copy (or (plist-get spec :steps) (list (cons directory (plist-get spec :argv))))))
               (buffer (static-site--buffer state (symbol-name (plist-get token :action)))))
          (dolist (step steps)
            (unless (and (file-directory-p (car step)) (not (file-remote-p (car step)))) (error "Invalid job directory"))
            (setcdr step (static-site--command (cdr step))))
          (static-site--run state steps buffer
            (lambda (ok)
              (unless (plist-get token :done)
                (condition-case err
                    (funcall done (list :status (cond ((plist-get token :cancelled) 'cancelled) (ok 'success) (t 'error))))
                  (error (funcall (plist-get token :finish) (list :status 'error :message (error-message-string err)))))))))))
    token))

(defun static-site-log (context text)
  "Append TEXT to CONTEXT's diagnostics without exposing internal buffers."
  (let ((buffer (get-buffer-create (format "*static-site action: %s*" (plist-get context :root)))))
    (static-site--log buffer (concat text "\n"))))

(defun static-site-preview-state (context)
  "Return a detached public snapshot of CONTEXT's preview."
  (let ((session (static-site--state-preview (static-site--context-state context))))
    (cl-loop for key in '(:root :backend :url :owned :phase :revision :error)
             append (list key (static-site--copy (plist-get session key))))))

(defun static-site-preview-probe (context done)
  "Asynchronously check CONTEXT's preview endpoint; DONE gets a result plist.
:status is absent, occupied, matching, timeout, or error. No server is started."
  (require 'static-site-preview)
  (static-site--with-context context
    (lambda ()
      (let* ((state (static-site--context-state context))
             (current (static-site--state-preview state))
             (session (if (static-site-preview--active state current) current
                        (static-site-preview--session state nil)))
             (token (plist-get context :action)))
        (when token (push (lambda () (unless (eq session current) (static-site-preview--close-request session)))
                          (plist-get token :cleanups)))
        (static-site-preview--request session
          (lambda (code body)
            (unless (and token (or (plist-get token :done) (plist-get token :cancelled)))
              (let ((result (list :status (cond ((null code) 'absent) ((eq code 'timeout) 'timeout) (t 'occupied)) :code code)))
                (when (and (numberp code) (<= 200 code) (< code 300) (plist-get session :decoder))
                  (condition-case err
                      (let ((status (funcall (plist-get session :decoder) body)))
                        (static-site-preview--identity session status)
                        (setq result (list :status 'matching :preview status)))
                    (error (setq result (list :status 'occupied :message (error-message-string err))))))
                (condition-case err
                    (static-site--with-context context (lambda () (funcall done result)))
                  (error (if token
                             (funcall (plist-get token :finish) (list :status 'error :message (error-message-string err)))
                           (message "Preview probe callback failed: %s" (error-message-string err)))))))))))))

(defun static-site--deactivate-contributions ()
  "Undo this buffer's plugin contributions, preserving later user settings."
  (dolist (entry static-site--contributions)
    (when (nth 1 entry)
      (condition-case err (funcall (nth 1 entry) (nth 0 entry) (nth 2 entry))
        (error (message "Plugin teardown failed: %s" (error-message-string err))))))
  (setq static-site--contributions nil)
  (mapc #'static-site-buffer-withdraw static-site--contribution-tokens)
  (setq static-site--contribution-tokens nil)
  (when (and static-site--installed-map
             (eq (cdr (assq 'static-site-mode minor-mode-overriding-map-alist)) static-site--installed-map))
    (setq-local minor-mode-overriding-map-alist
                (assq-delete-all 'static-site-mode (copy-sequence minor-mode-overriding-map-alist)))
    (when static-site--saved-map (push (cons 'static-site-mode static-site--saved-map) minor-mode-overriding-map-alist)))
  (setq static-site--installed-map nil static-site--saved-map nil))

(defun static-site-buffer-contribute (variable values)
  "Add VALUES to buffer-local list VARIABLE and return a removal token.
Use for CAPF, AUCTeX local symbols/environments or other additive lists."
  (let* ((local (local-variable-p variable))
         (old (and (boundp variable) (symbol-value variable)))
         (added (cl-remove-if (lambda (value) (member value old)) (static-site--copy values))))
    (set (make-local-variable variable) (append added (copy-sequence old)))
    (let ((token (list variable added local old)))
      (push token static-site--contribution-tokens)
      token)))

(defun static-site-buffer-withdraw (token)
  "Remove only TOKEN's contributions, retaining subsequent user additions."
  (pcase-let ((`(,variable ,added ,local ,old) token))
    (set variable (cl-remove-if (lambda (entry) (memq entry added)) (symbol-value variable)))
    (when (and (not local) (equal (symbol-value variable) old)) (kill-local-variable variable))))

(defun static-site-expand-snippet (text fallback)
  "Expand TEXT with active YASnippet, otherwise insert literal FALLBACK.
Called from a root-local template function; installs no global snippet tables."
  (if (and (bound-and-true-p yas-minor-mode) (fboundp 'yas-expand-snippet))
      (funcall 'yas-expand-snippet text)
    (insert fallback)))

(defun static-site--activate-contributions ()
  "Apply root-local writing contributions exactly once in this buffer."
  (static-site--deactivate-contributions)
  (let* ((context (static-site-context)) (maps nil))
    (condition-case err
        (dolist (plugin (plist-get context :plugins))
          (let* ((spec (cdr plugin))
                 (entry (list context (plist-get spec :teardown) nil)))
            (push entry static-site--contributions)
            (when (plist-get spec :keymap) (push (plist-get spec :keymap) maps))
            (when (plist-get spec :setup) (setcar (nthcdr 2 entry) (funcall (plist-get spec :setup) context)))))
      (error (static-site--deactivate-contributions) (signal (car err) (cdr err))))
    (setq static-site--saved-map (cdr (assq 'static-site-mode minor-mode-overriding-map-alist)))
    (setq static-site--installed-map (make-composed-keymap
                                     (append (when static-site--saved-map (list static-site--saved-map)) maps (list static-site-mode-map))))
    (setq-local minor-mode-overriding-map-alist (assq-delete-all 'static-site-mode (copy-sequence minor-mode-overriding-map-alist)))
    (push (cons 'static-site-mode static-site--installed-map)
          minor-mode-overriding-map-alist)
    (add-hook 'kill-buffer-hook #'static-site--deactivate-contributions nil t)
    (add-hook 'change-major-mode-hook #'static-site--deactivate-contributions nil t)))

(provide 'static-site-api)
;;; static-site-api.el ends here
