;;; check-workflow.el --- Project and preview integration regressions -*- lexical-binding: t; -*-
(setq load-prefer-newer t)
(defvar static-site-test-defer t)
(load (expand-file-name "static-site-tests.el" (file-name-directory load-file-name)) nil t)
(require 'static-site-preview)
(require 'static-site-author)
(require 'json)
(setq url-proxy-services nil url-automatic-caching nil)

(ert-deftest static-site-environment-survives-sentinels-and-callbacks ()
  (static-site-test--project
    (let* ((state (static-site--state)) (buffer (static-site--buffer state "environment"))
           (emacs (expand-file-name invocation-name invocation-directory))
           (argv (list emacs "--batch" "-Q" "--eval" "(princ (getenv \"SITE_TEST_TEMP\"))"))
           finished callback-environment callback-path)
      (let ((process-environment (copy-sequence process-environment))
            (exec-path (cons "captured/path" exec-path)))
        (setenv "SITE_TEST_TEMP" "original-environment")
        (static-site--run state (list (cons default-directory argv) (cons default-directory argv)) buffer
                          (lambda (ok) (setq finished ok callback-environment (getenv "SITE_TEST_TEMP") callback-path (car exec-path)))))
      (static-site-test--wait (lambda () finished))
      (should (equal callback-environment "original-environment"))
      (should (equal callback-path "captured/path"))
      (with-current-buffer buffer
        (should (= 2 (how-many "original-environment" (point-min) (point-max))))))))

(ert-deftest static-site-project-manager-and-local-overrides ()
  (static-site-test--project
    (let ((root static-site-root) (static-site-root nil))
      (cl-letf (((symbol-function 'projectile-project-root) (lambda () root))
                ((symbol-function 'project-current) (lambda (&rest _) (ert-fail "Projectile should take precedence"))))
        (should (equal (static-site--root) (file-name-as-directory (file-truename root))))))))

(ert-deftest static-site-adapter-defaults-do-not-overwrite-dir-locals ()
  (static-site-test--project
    (let ((static-site--projects (make-hash-table :test #'equal)) (root static-site-root))
      (static-site-register-project root '((static-site-backend . "first")))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory root))
        (static-site--configure)
        (should (equal static-site-backend "first"))
        (setq-local static-site-backend "user-selected")
        (static-site-register-project root '((static-site-backend . "second")))
        (static-site--configure)
        (should (equal static-site-backend "user-selected"))))))

(ert-deftest static-site-subprojects-change-with-the-current-buffer ()
  (static-site-test--project
    (let ((static-site--projects (make-hash-table :test #'equal))
          (root static-site-root) (static-site-root nil))
      (dolist (name '("one" "two"))
        (make-directory (expand-file-name name root))
        (static-site-register-project (expand-file-name name root) `((static-site-backend . ,name))))
      (with-temp-buffer
        (dolist (name '("one" "two" "one"))
          (setq default-directory (file-name-as-directory (expand-file-name name root)))
          (static-site--configure)
          (should (equal static-site-backend name)))))))

(ert-deftest static-site-framework-pipeline-and-static-only-project ()
  (static-site-test--project
    (let ((static-site-build-command nil)) (should-not (static-site--build-steps static-site-root)))
    (make-directory (expand-file-name "frontend" static-site-root))
    (let ((static-site-build-directory "frontend")
          (static-site-generators '(("tex" "emacs" "tex-step")))
          (static-site-build-command '("emacs" "any-framework"))
          (static-site-post-build-generators '(("assets" "emacs" "assets-step")))
          (static-site-verify-command '("emacs" "verify-step")))
      (let ((steps (static-site--build-steps static-site-root)))
        (should (equal (mapcar (lambda (step) (car (last step))) steps)
                       '("tex-step" "any-framework" "assets-step" "verify-step")))
        (should (cl-every (lambda (step) (string-suffix-p "/frontend/" (car step))) steps))))))

(ert-deftest static-site-environment-overrides-and-executable-path ()
  (static-site-test--project
    (let* ((static-site-environment '(("SITE_TEST_VAR" . "value") ("PATH" . "custom-bin")))
           (static-site-exec-path '("bin"))
           (context (static-site--environment static-site-root))
           (process-environment (car context)))
      (should (equal (getenv "SITE_TEST_VAR") "value"))
      (should (equal (car (cdr context)) (expand-file-name "bin" static-site-root)))
      (should (string-suffix-p "custom-bin" (getenv "PATH"))))))

(ert-deftest static-site-metadata-completion-is-context-sensitive ()
  (with-temp-buffer
    (setq-local static-site-metadata-command "BlogSetup"
                static-site-metadata-keys '(("title") ("visibility" "draft" "published")))
    (insert "\\BlogSetup{title={comma, {nested}},\n visi")
    (should (member "visibility" (nth 2 (static-site-completion-at-point))))
    (insert "bility={dr")
    (should (equal '("draft" "published") (nth 2 (static-site-completion-at-point))))
    (insert "aft}}\n prose visi")
    (should-not (static-site-completion-at-point))
    (erase-buffer)
    (insert "\\BlogSetup{ % visi")
    (should-not (static-site-completion-at-point))))

(ert-deftest static-site-templates-are-project-defined-and-atomic ()
  (with-temp-buffer
    (setq-local static-site-templates '(("widget" . "before{{point}}after")))
    (static-site-insert-template "widget")
    (should (equal (buffer-string) "beforeafter"))
    (should (= (point) 7))
    (should-error (static-site-insert-template "missing") :type 'user-error)))

(ert-deftest static-site-native-error-table-jumps-to-source ()
  (static-site-test--project
    (let* ((file (expand-file-name "source space.tex" static-site-root))
           (state (static-site--state)) (buffer (static-site--buffer state "navigation")))
      (with-temp-file file (insert "first\nsecond\nthird\n"))
      (static-site--log buffer "Running make4ht\n\n[ERROR] htlatex: source space.tex\t3\tUndefined control sequence.\n")
      (with-current-buffer buffer (compilation-next-error-function 1 t))
      (with-current-buffer (window-buffer (selected-window))
        (should (file-equal-p buffer-file-name file))
        (should (= (line-number-at-pos) 3)))
    (when-let* ((buffer (get-file-buffer (expand-file-name "source space.tex" static-site-root))))
      (kill-buffer buffer)))))

(defun static-site-test--port ()
  (let ((server (make-network-process :name "site-test-port" :server t :host "127.0.0.1" :service t)))
    (prog1 (process-contact server :service) (delete-process server))))

(defmacro static-site-test--preview (&rest body)
  (declare (indent 0))
  `(static-site-test--project
     (skip-unless (executable-find "node"))
     (let* ((port (static-site-test--port))
            (static-site-backend "test")
            (static-site-preview-url (format "http://127.0.0.1:%s/" port))
            (static-site-preview-status-path "/status")
            (static-site-preview-status-function
             (lambda (body) (json-parse-string body :object-type 'plist :null-object nil :false-object nil)))
            (static-site-preview-command
             (list (executable-find "node") (expand-file-name "test/preview-server.mjs" static-site-test--root)
                   (number-to-string port) "300"))
            (static-site-preview-timeout 6)
            (static-site-preview-request-timeout 2.5)
            (static-site-preview-poll-interval 0.1)
            (static-site-preview-watches t)
            (state (static-site--state)))
       (unwind-protect (progn ,@body) (static-site-preview-stop)))))

(ert-deftest static-site-preview-waits-and-captures-instance ()
  (static-site-test--preview
    (let (opened)
      (cl-letf (((symbol-function 'browse-url-default-browser) (lambda (url &rest _) (setq opened url))))
        (static-site-preview-browser)
        (should-not opened)
        (should-error (static-site-build) :type 'user-error)
        (static-site-test--wait (lambda () opened))
        (should (equal opened static-site-preview-url))
        (should (eq (plist-get (static-site--state-preview state) :phase) 'ready))
        (should (process-live-p (static-site--state-server state)))
        (let ((static-site-backend "different"))
          (should-error (static-site-preview-start) :type 'user-error))))))

(ert-deftest static-site-preview-rejects-incorrect-server-identity ()
  (static-site-test--preview
    (with-temp-file "status.json" (insert "{\"backend\":\"wrong\"}"))
    (static-site-preview-start)
    (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'failed)))
    (should (string-match-p "identity" (cadr (plist-get (static-site--state-preview state) :display))))))

(ert-deftest static-site-preview-failure-and-recovery-are-visible ()
  (static-site-test--preview
    (static-site-preview-start)
    (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'ready)))
    (with-temp-file "status.json" (insert "{\"error\":\"source.tex:7: error: bad macro\"}"))
    (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'error)))
    (should-error (static-site-build) :type 'user-error)
    (with-current-buffer (plist-get (static-site--state-preview state) :buffer)
      (should (string-match-p "source.tex:7" (buffer-string))))
    (with-temp-file "status.json" (insert "{\"revision\":2}"))
    (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'ready)))))

(ert-deftest static-site-preview-http-timeout-is-bounded ()
  (static-site-test--preview
    (setq static-site-preview-command (append (butlast static-site-preview-command) '("0" "hang"))
          static-site-preview-timeout 0.8)
    (static-site-preview-start)
    (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'failed)))
    (should-not (plist-get (static-site--state-preview state) :request))))

(ert-deftest static-site-preview-stop-during-startup-clears-callbacks ()
  (static-site-test--preview
    (let (opened)
      (cl-letf (((symbol-function 'browse-url-default-browser) (lambda (&rest _) (setq opened t))))
        (static-site-preview-browser)
        (static-site-preview-stop)
        (accept-process-output nil 0.5)
        (should-not opened)
        (should (eq (plist-get (static-site--state-preview state) :phase) 'stopped))
        (should-not (plist-get (static-site--state-preview state) :request))))))

(ert-deftest static-site-preview-identity-checks-root-and-token ()
  (let* ((root (file-name-as-directory (file-truename default-directory)))
         (session (list :root root :backend "test" :owned t :token "instance-one"))
         (status (list :root root :backend "test" :token "instance-one")))
    (static-site-preview--identity session status)
    (should-error (static-site-preview--identity session (plist-put (copy-sequence status) :token "other")))
    (should-error (static-site-preview--identity session (plist-put (copy-sequence status) :root "../")))))

(ert-deftest static-site-mapped-diagnostic-jumps-to-original-file ()
  (static-site-test--project
    (let* ((static-site-error-regexp-alist '(gnu))
           (file (expand-file-name "original source.tex" static-site-root))
           (buffer (static-site--buffer (static-site--state) "mapped source")))
      (with-temp-file file (insert "one\ntwo\nthree\n"))
      (static-site--log buffer (format "Build failed\n%s:2: error: Undefined control sequence\n[ERROR] htlatex: ./staged.tex\t9\tUndefined control sequence\n" file))
      (with-current-buffer buffer (compilation-next-error-function 1 t))
      (with-current-buffer (window-buffer (selected-window))
        (should (file-equal-p buffer-file-name file))
        (should (= (line-number-at-pos) 2)))
      (with-current-buffer buffer (should-error (compilation-next-error-function 1)))
      (kill-buffer (get-file-buffer file)))))

(ert-deftest static-site-preview-follow-and-port-conflict-preserve-external-server ()
  (static-site-test--preview
    (let ((external (make-process :name "external-site-fixture" :buffer nil
                                  :command static-site-preview-command :noquery t)))
      (unwind-protect
          (progn
            (static-site-preview-follow)
            (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'ready)))
            (static-site-preview-stop)
            (should (process-live-p external))
            (static-site-preview-start)
            (static-site-test--wait (lambda () (eq (plist-get (static-site--state-preview state) :phase) 'failed)))
            (should (string-match-p "occupied" (cadr (plist-get (static-site--state-preview state) :display))))
            (should (process-live-p external)))
        (static-site--terminate external)))))

(ert-run-tests-batch-and-exit (or (getenv "STATIC_SITE_TEST_SELECTOR") t))
;;; check-workflow.el ends here
