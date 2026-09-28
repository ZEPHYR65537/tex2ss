;;; static-site-preview.el --- Project-owned preview sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; HTTP checks never block the editor.  A server adapter can supply an identity
;; and revision decoder; a plain server only needs a successful HTTP response.

;;; Code:
(require 'static-site)
(require 'url)
(require 'url-http)
(defvar url-http-response-status)

(defcustom static-site-preview-directory "."
  "Preview process directory relative to the project root."
  :type 'directory :group 'static-site)
(defcustom static-site-preview-status-path nil
  "Status endpoint relative to the preview URL, or nil to check the URL itself."
  :type '(choice (const nil) string) :group 'static-site)
(defcustom static-site-preview-status-function nil
  "Optional function decoding an HTTP body into a status plist.
Return :root, :backend, :token, :ready, and optionally :building, :revision,
and :error.  ROOT and BACKEND must identify the configured project.  Owned
servers must echo the STATIC_SITE_PREVIEW_TOKEN environment variable.
Only explicitly followed external servers may omit the token check."
  :type '(choice (const nil) function) :group 'static-site)
(defcustom static-site-preview-route-function nil
  "Optional function returning the current source's preview URL path."
  :type '(choice (const nil) function) :group 'static-site)
(defcustom static-site-preview-timeout 180
  "Maximum seconds to wait for initial readiness, including an initial build."
  :type 'number :group 'static-site)
(defcustom static-site-preview-request-timeout 3
  "Maximum seconds for one asynchronous HTTP check."
  :type 'number :group 'static-site)
(defcustom static-site-preview-poll-interval 2
  "Seconds between checks of an active preview."
  :type 'number :group 'static-site)
(dolist (variable '(static-site-preview-directory static-site-preview-status-path
                    static-site-preview-status-function static-site-preview-route-function
                    static-site-preview-timeout static-site-preview-request-timeout
                    static-site-preview-poll-interval))
  (make-variable-buffer-local variable))

(defun static-site-preview--active (state session)
  "Whether SESSION is still the current active session for STATE."
  (and (eq session (static-site--state-preview state))
       (memq (plist-get session :phase) '(checking starting ready building error))))

(defun static-site-preview--close-request (session)
  "Cancel SESSION's bounded HTTP request."
  (when-let* ((timer (plist-get session :request-timer))) (cancel-timer timer))
  (setf (plist-get session :request-timer) nil)
  (when-let* ((buffer (plist-get session :request)))
    (setf (plist-get session :request) nil)
    (when (buffer-live-p buffer)
      (when-let* ((process (get-buffer-process buffer))) (delete-process process))
      (kill-buffer buffer))))

(defun static-site-preview--request-start (session callback)
  "GET SESSION's endpoint once; call CALLBACK with HTTP code and body.
A nil code denotes a transport error, and `timeout' denotes a deadline.
Only one request is outstanding per session; proxies and cookies are unused."
  (let ((url-proxy-services nil)
        (url-automatic-caching nil)
        (url-request-extra-headers '(("Cache-Control" . "no-cache")))
        finished)
    (cl-labels ((finish (code body)
                 (unless finished
                   (setq finished t)
                   (static-site-preview--close-request session)
                   (funcall callback code body))))
      (condition-case err
          (setf (plist-get session :request)
                (url-retrieve
                 (plist-get session :endpoint)
                 (lambda (_status)
                   (let ((code url-http-response-status)
                         (body (save-excursion
                                 (goto-char (point-min))
                                 (if (re-search-forward "\r?\n\r?\n" nil t)
                                     (decode-coding-string
                                      (buffer-substring-no-properties (point) (point-max)) 'utf-8 t) ""))))
                     (finish code body))) nil t t))
        (error (finish nil (error-message-string err))))
      ;; url-retrieve can return nil on an immediate connection refusal
      ;; without invoking its callback.
      (unless (or finished (plist-get session :request)) (finish nil "Connection refused"))
      (unless finished
        (setf (plist-get session :request-timer)
              (run-at-time (plist-get session :request-timeout) nil
                           (lambda () (finish 'timeout "HTTP check timed out"))))))))

(defun static-site-preview--request (session callback)
  "Coalesce SESSION's concurrent callers onto one bounded HTTP request."
  (unless (plist-member session :request-callbacks) (nconc session (list :request-callbacks nil)))
  (push callback (plist-get session :request-callbacks))
  (unless (plist-get session :request)
    (static-site-preview--request-start
     session
     (lambda (code body)
       (let ((callbacks (plist-get session :request-callbacks)))
         (setf (plist-get session :request-callbacks) nil)
         (dolist (fn (reverse callbacks))
           (condition-case err (funcall fn code body)
             (error (message "Preview callback failed: %s" (error-message-string err))))))))))

(defvar-local static-site-preview--dirty-url nil)
(defun static-site-preview--visible (window)
  "Refresh a dirty EWW buffer when WINDOW displays it."
  (with-current-buffer (window-buffer window)
    (when static-site-preview--dirty-url
      (let ((url static-site-preview--dirty-url))
        (setq static-site-preview--dirty-url nil)
        (when (equal url (plist-get eww-data :url)) (eww-reload))))))

(defun static-site-preview-notify-save ()
  "Request a short burst of status checks; never start a build or server."
  (when-let* ((state (gethash (static-site--root) static-site--states))
              (session (static-site--state-preview state)))
    (when (static-site-preview--active state session)
      (setf (plist-get session :hurry-until) (+ (float-time) 8)
            (plist-get session :idle-count) 0)
      (unless (plist-get session :request)
        (when-let* ((timer (plist-get session :timer))) (cancel-timer timer))
        (setf (plist-get session :timer) (run-at-time 0.2 nil #'static-site-preview--poll state session))))))

(defun static-site-preview--show (session phase detail)
  "Show a changed PHASE and DETAIL without repeated failure notifications."
  (let ((changed (not (equal (list phase detail) (plist-get session :display)))))
    (setf (plist-get session :phase) phase
          (plist-get session :display) (list phase detail))
    (when (and changed (buffer-live-p (plist-get session :buffer)))
      (with-current-buffer (plist-get session :buffer)
        (setq header-line-format
              (propertize (format "Preview %s [%s]: %s" phase (plist-get session :backend)
                                  (if (memq phase '(error failed)) "See diagnostics below"
                                    (car (split-string detail "\n"))))
                          'face (if (memq phase '(error failed)) 'error 'mode-line))))
      (when (memq phase '(error failed))
        (static-site--log (plist-get session :buffer) (concat "\nPREVIEW FAILED: " detail "\n"))
        (display-buffer (plist-get session :buffer))
        (message "Preview failed: %s" (car (split-string detail "\n")))))))

(defun static-site-preview--fail (state session detail)
  "End SESSION after failure, stopping only its owned server."
  (static-site-preview--show session 'failed detail)
  (setf (plist-get session :callbacks) nil)
  (when-let* ((timer (plist-get session :timer))) (cancel-timer timer))
  (static-site-preview--close-request session)
  (when (and (plist-get session :owned) (process-live-p (static-site--state-server state)))
    (static-site--terminate (static-site--state-server state))))

(defun static-site-preview--identity (session status)
  "Reject STATUS from a different root, backend, or server instance."
  (unless (and (stringp (plist-get status :root))
               (not (file-remote-p (plist-get status :root)))
               (equal (file-name-as-directory (file-truename (plist-get status :root)))
                      (plist-get session :root))
               (equal (plist-get status :backend) (plist-get session :backend))
               (or (not (plist-get session :owned))
                   (equal (plist-get status :token) (plist-get session :token))))
    (error "Server identity does not match this project/backend/instance")))

(defun static-site-preview--update (state session status)
  "Apply verified server STATUS and refresh only this SESSION's EWW buffers."
  (when (plist-get session :decoder) (static-site-preview--identity session status))
  (let ((error-text (plist-get status :error))
        (revision (plist-get status :revision))
        (old (plist-get session :revision))
        (pages (plist-get status :page-revisions)))
    (cond
     (error-text (static-site-preview--show session 'error error-text))
     ((plist-get status :building) (static-site-preview--show session 'building "Building; previous output may be stale"))
     ((plist-get status :ready)
      (static-site-preview--show session 'ready (plist-get session :url))
      (setf (plist-get session :ready-once) t)
      (when (and revision old (not (equal revision old)))
        (setf (plist-get session :eww-buffers)
              (cl-remove-if-not #'buffer-live-p (plist-get session :eww-buffers)))
        (dolist (buffer (plist-get session :eww-buffers))
          (with-current-buffer buffer
            (when (and (derived-mode-p 'eww-mode)
                       (string-prefix-p (file-name-as-directory (plist-get session :url))
                                        (or (plist-get eww-data :url) ""))
                       (let* ((route (car (split-string (url-filename (url-generic-parse-url (plist-get eww-data :url))) "[?#]")))
                              (hash (cdr (assoc route pages))))
                         (or (null hash) (not (equal hash (cdr (assoc route (plist-get session :page-revisions))))))))
              (if (get-buffer-window buffer t) (eww-reload)
                (setq-local static-site-preview--dirty-url (plist-get eww-data :url))
                (add-hook 'window-buffer-change-functions #'static-site-preview--visible nil t))))))
      (setf (plist-get session :idle-count)
            (if (equal revision old) (1+ (or (plist-get session :idle-count) 0)) 0)
            (plist-get session :page-revisions) pages
            (plist-get session :revision) revision)
      (let ((callbacks (plist-get session :callbacks)))
        (setf (plist-get session :callbacks) nil)
        (dolist (callback callbacks)
          (condition-case err (funcall callback)
            (error (static-site--log (plist-get session :buffer)
                                    (concat (error-message-string err) "\n")))))))
     (t (static-site-preview--show session 'starting "Waiting for usable output"))))
  ;; A responding server with a build error remains observable, even during
  ;; initial compilation.  A build failure must not become a timeout message.
  (when (or (plist-get session :ready-once) (eq (plist-get session :phase) 'error))
    (setf (plist-get session :deadline) (+ (float-time) (plist-get session :startup-timeout))))
  (static-site-preview--schedule state session))

(defun static-site-preview--schedule (state session)
  "Schedule the next check for STATE and SESSION without overlapping requests."
  (when (static-site-preview--active state session)
    (when-let* ((timer (plist-get session :timer))) (cancel-timer timer))
    (setf (plist-get session :timer)
          (run-at-time (cond
                        ((memq (plist-get session :phase) '(starting building)) 0.3)
                        ((> (or (plist-get session :hurry-until) 0) (float-time)) 0.4)
                        (t (min 30 (* (plist-get session :interval)
                                      (expt 2 (min 4 (floor (or (plist-get session :idle-count) 0) 3))))))) nil
                       #'static-site-preview--poll state session))))

(defun static-site-preview--poll (state session)
  "Check readiness, identity, and build status for STATE's SESSION."
  (when (static-site-preview--active state session)
    (static-site-preview--request
     session
     (lambda (code body)
       (when (static-site-preview--active state session)
         (condition-case err
             (if (and (numberp code) (<= 200 code) (< code 300))
                 (let ((status (if-let* ((decoder (plist-get session :decoder)))
                                   (funcall decoder body) '(:ready t))))
                   (if (and (not (plist-get session :ready-once))
                            (not (plist-get status :ready)) (not (plist-get status :error))
                            (> (float-time) (plist-get session :deadline)))
                       (static-site-preview--fail state session "Initial build exceeded the readiness timeout")
                     (static-site-preview--update state session status)))
               (if (> (float-time) (plist-get session :deadline))
                   (static-site-preview--fail state session "Server did not become ready; see its output")
                 (static-site-preview--show session 'starting "Waiting for HTTP readiness")
                 (static-site-preview--schedule state session)))
           (error (static-site-preview--fail state session (error-message-string err)))))))))

(defun static-site-preview--spawn (state session)
  "Start STATE's captured SESSION and begin readiness checks."
  (condition-case err
      (let ((default-directory (plist-get session :directory))
            (process-environment (copy-sequence (plist-get session :environment)))
            (exec-path (copy-sequence (plist-get session :exec-path))))
        (setenv "STATIC_SITE_PREVIEW_TOKEN" (plist-get session :token))
        (static-site-preview--show session 'starting "Waiting for HTTP readiness")
        (setf (static-site--state-server state)
              (make-process
               :name "static-site-preview" :buffer (plist-get session :buffer)
               :command (plist-get session :command) :filter #'compilation-filter
               :connection-type 'pipe :coding 'utf-8-unix :noquery t
               :sentinel
               (lambda (process event)
                 (when (and (memq (process-status process) '(exit signal))
                            (static-site-preview--active state session))
                   (static-site-preview--fail state session (string-trim event))))))
        (static-site-preview--poll state session))
    (error (static-site-preview--fail state session (error-message-string err)))))

(defun static-site-preview--session (state owned)
  "Capture current settings in a new SESSION for STATE; OWNED starts a server."
  (let* ((root (static-site--state-root state))
         (context (static-site--environment root))
         (process-environment (car context)) (exec-path (cdr context))
         (directory (file-name-as-directory (expand-file-name static-site-preview-directory root)))
         (default-directory directory)
         (url (url-generic-parse-url static-site-preview-url)))
    (unless (and (equal (url-type url) "http")
                 (member (url-host url) '("127.0.0.1" "localhost" "::1" "[::1]")))
      (user-error "Preview URL must use HTTP on loopback"))
    (unless (and (not (file-remote-p directory)) (file-directory-p directory))
      (user-error "Preview working directory does not exist"))
    (list :root root :backend static-site-backend :owned owned
          :buffer nil :request nil :request-timer nil :timer nil :display nil
          :request-callbacks nil :idle-count 0 :hurry-until 0 :page-revisions nil :callbacks nil :revision nil :ready-once nil :eww-buffers nil
          :command (when owned (static-site--command static-site-preview-command))
          :directory directory :environment (copy-sequence process-environment)
          :exec-path (copy-sequence exec-path) :url static-site-preview-url
          :endpoint (if static-site-preview-status-path
                        (url-expand-file-name static-site-preview-status-path static-site-preview-url)
                      static-site-preview-url)
          :decoder static-site-preview-status-function :watches static-site-preview-watches
          :phase 'checking :token (format "%s-%s-%s" (emacs-pid) (float-time) (random))
          :deadline (+ (float-time) static-site-preview-timeout)
          :startup-timeout static-site-preview-timeout
          :request-timeout static-site-preview-request-timeout
          :interval static-site-preview-poll-interval)))

(defun static-site-preview--start (owned)
  "Start or follow the current project; OWNED selects a managed child process."
  (let* ((state (static-site--state))
         (candidate (static-site-preview--session state owned))
         (current (static-site--state-preview state)))
    (static-site--idle state)
    (if (static-site-preview--active state current)
        (dolist (key '(:backend :url :directory :command :environment :exec-path :decoder :endpoint :watches))
          (unless (equal (plist-get candidate key) (plist-get current key))
            (user-error "Preview settings changed; stop this project's preview before restarting")))
      (setf (static-site--state-preview state) candidate
            (static-site--state-watches state) static-site-preview-watches
            (plist-get candidate :buffer) (static-site--buffer state "preview"))
      (if (not owned)
          (static-site-preview--poll state candidate)
        (static-site-preview--show candidate 'checking "Checking for a port conflict")
        (static-site-preview--request
         candidate
         (lambda (code _body)
           (when (static-site-preview--active state candidate)
             (cond ((eq code 'timeout)
                    (static-site-preview--fail state candidate "Port check timed out"))
                   (code (static-site-preview--fail state candidate
                                                   "Port is occupied; choose another port or explicitly follow the matching server"))
                   (t (static-site-preview--spawn state candidate))))))))
    state))

;;;###autoload
(defun static-site-preview-start ()
  "Start this project's server asynchronously and wait for HTTP readiness."
  (interactive)
  (static-site-preview--start t))

;;;###autoload
(defun static-site-preview-follow ()
  "Follow an external server only after checking its project/backend identity."
  (interactive)
  (static-site--configure)
  (unless static-site-preview-status-function
    (user-error "Following an external server requires a status identity adapter"))
  (static-site-preview--start nil))

;;;###autoload
(defun static-site-preview-stop ()
  "Cancel this project's checks and stop its owned server only."
  (interactive)
  (let* ((state (static-site--state)) (session (static-site--state-preview state)))
    (when session
      (static-site-preview--show session
        (if (and (plist-get session :owned) (process-live-p (static-site--state-server state))) 'stopping 'stopped)
        "Stopping owned preview")
      (setf (plist-get session :callbacks) nil)
      (when-let* ((timer (plist-get session :timer))) (cancel-timer timer))
      (static-site-preview--close-request session)
      (when (plist-get session :owned)
        (static-site--terminate (static-site--state-server state))
        (cl-labels ((finished ()
                      (when (eq session (static-site--state-preview state))
                        (if (let ((server (static-site--state-server state)))
                              (and server (or (process-live-p server)
                                              (process-get server 'static-site-stopping))))
                            (run-at-time 0.05 nil #'finished)
                          (static-site-preview--show session 'stopped "Stopped")))))
          (finished))))))

(defun static-site-preview--open (browser)
  "Open this project's preview in BROWSER after verified readiness."
  (static-site--configure)
  (let* ((url (if static-site-preview-route-function
                  (url-expand-file-name (funcall static-site-preview-route-function) static-site-preview-url)
                static-site-preview-url))
         (state (static-site--state))
         (existing (static-site--state-preview state))
         (_ (static-site-preview--start (if (static-site-preview--active state existing)
                                           (plist-get existing :owned) t)))
         (session (static-site--state-preview state))
         (open (lambda ()
                 (if browser (browse-url-default-browser url)
                   (let* ((buffer (get-buffer-create (format "*site EWW: %s*" (static-site--state-root state))))
                          (window (display-buffer-in-side-window buffer '((side . right) (window-width . 0.46)))))
                     (with-selected-window window
                       (unless (derived-mode-p 'eww-mode) (eww-mode))
                       (setq-local static-site-root (static-site--state-root state))
                       (eww url))
                     (cl-pushnew buffer (plist-get session :eww-buffers)))))))
    (if (eq (plist-get session :phase) 'ready) (funcall open)
      (push open (plist-get session :callbacks))
      (message "Waiting for this project's preview to become ready"))))

;;;###autoload
(defun static-site-preview-browser ()
  "Open this project's ready preview in the default browser."
  (interactive) (static-site-preview--open t))

;;;###autoload
(defun static-site-preview-eww ()
  "Open this project's ready preview in an EWW side window."
  (interactive) (static-site-preview--open nil))

;;;###autoload
(defun static-site-preview-status ()
  "Display this project's preview status and diagnostics."
  (interactive)
  (let ((session (static-site--state-preview (static-site--state))))
    (unless session (user-error "No preview session for this project"))
    (display-buffer (plist-get session :buffer))
    (message "Preview %s: %s" (plist-get session :phase) (plist-get session :url))))

(provide 'static-site-preview)
;;; static-site-preview.el ends here
