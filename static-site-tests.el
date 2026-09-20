;;; static-site-tests.el --- Offline workflow regression tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'static-site)

(defconst static-site-test--root
  (file-name-directory load-file-name))

(defmacro static-site-test--project (&rest body)
  "Run BODY with an isolated local project and clean up its owned files."
  (declare (indent 0) (debug t))
  `(let* ((cache (expand-file-name ".cache/" static-site-test--root))
          (_ (make-directory cache t))
          (static-site-root (make-temp-file (expand-file-name "workflow-test-" cache) t))
          (default-directory (file-name-as-directory static-site-root))
          (static-site--states (make-hash-table :test #'equal))
          (static-site-public-directory "public/")
          (static-site-entry-file "index.html")
          (static-site-generators nil)
          (static-site-deploy-host "deploy@example.test")
          (static-site-deploy-directory "/srv/www/my blog/")
          (static-site-deploy-delete nil)
          (static-site-ssh-config nil)
          (static-site-rsync-program "emacs")
          (static-site-ssh-program "emacs")
          (static-site-build-command (list invocation-name "--batch" "-Q"))
          (static-site-verify-command nil))
     (unwind-protect (progn ,@body)
       (maphash (lambda (_ state)
                  (dolist (process (list (static-site--state-process state)
                                        (static-site--state-server state)))
                    (when (process-live-p process) (delete-process process))))
                static-site--states)
       (when (file-in-directory-p (file-truename static-site-root) cache)
         (delete-directory static-site-root t)))))

(defun static-site-test--public ()
  (let ((public (expand-file-name "public/" static-site-root)))
    (make-directory public t)
    (with-temp-file (expand-file-name "index.html" public) (insert "<h1>Version one</h1>"))
    (make-directory (expand-file-name "中文 space/" public))
    (with-temp-file (expand-file-name "中文 space/article.html" public) (insert "Unicode article"))
    public))

(defun static-site-test--wait (predicate)
  (let ((deadline (+ (float-time) 15)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02)))
  (should (funcall predicate)))

(ert-deftest static-site-destinations-reject-injection-and-broad-paths ()
  (static-site-test--project
    (should (equal (static-site--destination) "deploy@example.test:/srv/www/my blog/"))
    (dolist (host '(nil "-oProxyCommand=oops" "host:22" "host;id" "host\nother" "rsync://host"))
      (let ((static-site-deploy-host host)) (should-error (static-site--destination) :type 'user-error)))
    (dolist (path '(nil "/" "/var/www" "relative" "/srv/../etc" "/srv/./blog"
                        "//server/share" "/srv/blog*" "/srv/blog;id" "/srv/blog\nother"))
      (let ((static-site-deploy-directory path)) (should-error (static-site--destination) :type 'user-error)))))

(ert-deftest static-site-ssh-enforces-host-verification-and-key-auth ()
  (static-site-test--project
    (let* ((command (static-site--rsync-command (static-site--destination)))
           (ssh (cadr (member "-e" command))))
      (dolist (option '("StrictHostKeyChecking=yes" "BatchMode=yes" "ForwardAgent=no"
                        "PasswordAuthentication=no" "ControlPath=none" "ClearAllForwardings=yes"))
        (should (string-match-p (regexp-quote option) ssh)))
      (should (member "-s" command))
      (should (equal (last command 3) '("--" "./" "deploy@example.test:/srv/www/my blog/")))
      (should-not (member "--delete-delay" command))
      (let ((static-site-deploy-delete t))
        (should (member "--delete-delay" (static-site--rsync-command (static-site--destination))))))))

(ert-deftest static-site-rsync-quotes-its-own-parser ()
  (should (equal (static-site--rsh-quote "C:/Program Files/O'Brien/ssh.exe")
                 "'C:/Program Files/O''Brien/ssh.exe'"))
  (should-error (static-site--rsh-quote "bad\nargument") :type 'user-error))

(ert-deftest static-site-programs-and-config-fail-early ()
  (static-site-test--project
    (should-error (static-site--command nil) :type 'user-error)
    (should-error (static-site--command '("definitely-not-a-real-program-123")) :type 'user-error)
    (let ((static-site-ssh-config "missing.conf"))
      (should-error (static-site--rsync-command (static-site--destination)) :type 'user-error))))

(ert-deftest static-site-output-cannot-be-root-or-outside-project ()
  (static-site-test--project
    (dolist (path '("." "../" "/ssh:example.test:/tmp/"))
      (let ((static-site-public-directory path))
        (should-error (static-site--public (static-site--root)) :type 'user-error)))))

(ert-deftest static-site-snapshot-is-isolated-and-retains-unicode ()
  (static-site-test--project
    (let* ((public (static-site-test--public))
           (snapshot (static-site--snapshot (static-site--root) public)))
      (with-temp-file (expand-file-name "index.html" public) (insert "Changed later"))
      (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "index.html" snapshot))
                                      (buffer-string)) "<h1>Version one</h1>"))
      (should (file-exists-p (expand-file-name "中文 space/article.html" snapshot)))
      (static-site--remove-snapshot (static-site--root) snapshot)
      (should-not (file-exists-p snapshot)))))

(ert-deftest static-site-snapshot-rejects-empty-build ()
  (static-site-test--project
    (let ((public (expand-file-name "public/" static-site-root)))
      (make-directory public)
      (should-error (static-site--snapshot (static-site--root) public) :type 'user-error)
      (with-temp-file (expand-file-name "index.html" public))
      (should-error (static-site--snapshot (static-site--root) public) :type 'user-error))))

(ert-deftest static-site-symlink-and-cleanup-boundaries ()
  (static-site-test--project
    (let* ((public (static-site-test--public))
           (original (symbol-function 'file-symlink-p)))
      ;; Simulate a link on Windows without requiring symlink privileges.
      (cl-letf (((symbol-function 'file-symlink-p)
                 (lambda (path) (if (string-suffix-p "index.html" path) "outside" (funcall original path)))))
        (should-error (static-site--check-tree public) :type 'user-error))
      (should-error (static-site--remove-snapshot (static-site--root) public))
      (should (file-exists-p public)))))

(ert-deftest static-site-real-processes-are-serial-and-shell-free ()
  (static-site-test--project
    (let* ((state (static-site--state))
           (buffer (static-site--buffer state "test"))
           (emacs (expand-file-name invocation-name invocation-directory))
           (marker (expand-file-name "space ' ; marker.txt" static-site-root))
           (first (list emacs "--batch" "-Q" "--eval"
                        (format "(with-temp-file %S (insert \"one\"))" marker)))
           (second (list emacs "--batch" "-Q" "--eval"
                         (format "(unless (file-exists-p %S) (kill-emacs 7))" marker)))
           done result)
      (static-site--run state (list (cons default-directory first) (cons default-directory second))
                        buffer (lambda (ok) (setq result ok done t)))
      (should-error (static-site--idle state) :type 'user-error)
      (static-site-test--wait (lambda () done))
      (should result)
      (should (file-exists-p marker)))))

(ert-deftest static-site-real-failure-prevents-later-steps ()
  (static-site-test--project
    (let* ((state (static-site--state))
           (emacs (expand-file-name invocation-name invocation-directory))
           (marker (expand-file-name "must-not-exist" static-site-root))
           (steps (list (cons default-directory (list emacs "--batch" "-Q" "--eval" "(kill-emacs 3)"))
                        (cons default-directory (list emacs "--batch" "-Q" "--eval"
                                                      (format "(with-temp-file %S)" marker)))))
           done result)
      (static-site--run state steps (static-site--buffer state "test")
                        (lambda (ok) (setq done t result ok)))
      (static-site-test--wait (lambda () done))
      (should-not result)
      (should-not (file-exists-p marker)))))

(ert-deftest static-site-real-cancel-does-not-report-success ()
  (static-site-test--project
    (let* ((state (static-site--state))
           (emacs (expand-file-name invocation-name invocation-directory))
           done result)
      (static-site--run state
                        (list (cons default-directory (list emacs "--batch" "-Q" "--eval" "(sleep-for 20)")))
                        (static-site--buffer state "test")
                        (lambda (ok) (setq done t result ok)))
      (static-site-cancel)
      (static-site-test--wait (lambda () done))
      (should-not result)
      (should-not (static-site--state-process state)))))

(ert-deftest static-site-spawn-failure-clears-job ()
  (static-site-test--project
    (let ((state (static-site--state)) done result)
      (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (error "Cannot start process"))))
        (static-site--run state (list (cons default-directory '("missing")))
                          (static-site--buffer state "test") (lambda (ok) (setq done t result ok))))
      (should done) (should-not result) (should-not (static-site--state-process state)))))

(ert-deftest static-site-projects-have-independent-state ()
  (static-site-test--project
    (let ((first (static-site--state))
          (other (expand-file-name "other" static-site-root)))
      (make-directory other)
      (let ((static-site-root other))
        (should-not (eq first (static-site--state)))))))

(ert-deftest static-site-deploy-build-failure-never-transfers ()
  (static-site-test--project
    (let ((calls 0))
      (cl-letf (((symbol-function 'static-site--run)
                 (lambda (_state _steps _buffer done) (cl-incf calls) (funcall done nil))))
        (static-site-deploy-preview))
      (should (= calls 1))
      (should-not (static-site--state-plan (static-site--state))))))

(ert-deftest static-site-failed-dry-run-cleans-snapshot-and-disables-publish ()
  (static-site-test--project
    (static-site-test--public)
    (let ((calls 0) snapshot)
      (cl-letf (((symbol-function 'static-site--run)
                 (lambda (_state steps _buffer done)
                   (cl-incf calls)
                   (when (= calls 2)
                     (setq snapshot (caar steps))
                     (should (member "--dry-run" (cdar steps))))
                   (funcall done (= calls 1)))))
        (static-site-deploy-preview))
      (should (= calls 2))
      (should-not (file-exists-p snapshot))
      (should-not (static-site--state-plan (static-site--state)))
      (should-error (static-site-deploy-publish) :type 'user-error))))

(ert-deftest static-site-publish-uses-reviewed-destination-options-and-content ()
  (static-site-test--project
    (let ((public (static-site-test--public)) commands directories prompt)
      (cl-letf (((symbol-function 'static-site--run)
                 (lambda (_state steps _buffer done)
                   (push (cdar steps) commands) (push (caar steps) directories)
                   (when (= (length commands) 3)
                     (should (equal (with-temp-buffer
                                      (insert-file-contents (expand-file-name "index.html" (caar steps)))
                                      (buffer-string)) "<h1>Version one</h1>")))
                   (funcall done t)))
                ((symbol-function 'yes-or-no-p) (lambda (text) (setq prompt text) t)))
        (static-site-deploy-preview)
        (should (static-site--state-plan (static-site--state)))
        (with-temp-file (expand-file-name "index.html" public) (insert "Unreviewed edit"))
        (let ((static-site-deploy-host "different.example") (static-site-deploy-delete t))
          (static-site-deploy-publish)))
      (should (= (length commands) 3))
      (should (member "--dry-run" (nth 1 commands)))
      (should-not (member "--dry-run" (car commands)))
      (should-not (member "--delete-delay" (car commands)))
      (should (string-match-p "deploy@example.test" prompt))
      (should (equal (car directories) (cadr directories)))
      (should-not (file-exists-p (car directories)))
      (should-not (static-site--state-plan (static-site--state))))))

(ert-deftest static-site-declining-publish-keeps-reviewed-plan ()
  (static-site-test--project
    (static-site-test--public)
    (cl-letf (((symbol-function 'static-site--run) (lambda (_s _steps _b done) (funcall done t))))
      (static-site-deploy-preview))
    (let ((plan (static-site--state-plan (static-site--state))))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil))
                ((symbol-function 'static-site--run) (lambda (&rest _) (ert-fail "Unexpected transfer"))))
        (static-site-deploy-publish))
      (should (eq plan (static-site--state-plan (static-site--state))))
      (static-site-deploy-forget)
      (should-not (file-exists-p (plist-get plan :snapshot))))))

(ert-deftest static-site-script-plugins-run-before-build-and-validation ()
  (static-site-test--project
    (let ((static-site-generators '(("figures" "emacs" "figures") ("catalog" "emacs" "catalog")))
          (static-site-build-command '("emacs" "build"))
          (static-site-verify-command '("emacs" "verify")))
      (should (equal (mapcar (lambda (step) (car (last step)))
                            (static-site--build-steps (static-site--root)))
                     '("figures" "catalog" "build" "verify"))))))

(ert-deftest static-site-make4ht-preset-is-framework-independent ()
  (static-site-test--project
    (let ((file (expand-file-name "main.tex" static-site-root))
          (static-site-make4ht-program "make4ht")
          (static-site-make4ht-options '("-x" "-f" "html5+common_domfilters" "-e" "build.mk4")))
      (with-temp-file file (insert "\\documentclass{article}"))
      (static-site-make4ht-setup file)
      (should (equal static-site-entry-file "main.html"))
      (should (equal static-site-build-command
                     '("make4ht" "-x" "-f" "html5+common_domfilters" "-e" "build.mk4"
                       "-d" "public/" "-B" ".cache/make4ht" "main.tex" "mathml")))
      (should-not (member "-s" static-site-build-command)))))

(ert-deftest static-site-document-entry-can-be-main-html ()
  (static-site-test--project
    (let ((public (static-site-test--public)))
      (with-temp-file (expand-file-name "main.html" public) (insert "Document"))
      (should (file-exists-p (expand-file-name "main.html"
                                               (static-site--snapshot (static-site--root) public "main.html"))))
      (should-error (static-site--snapshot (static-site--root) public "../outside.html") :type 'user-error))))

(ert-run-tests-batch-and-exit)
