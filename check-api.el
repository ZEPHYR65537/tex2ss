;;; check-api.el --- Public API and isolation regressions -*- lexical-binding: t; -*-
(setq load-prefer-newer t)
(require 'ert)
(require 'static-site)
(require 'static-site-preview)
(require 'static-site-author)
(defvar static-site-test-defer t)
(load (expand-file-name "static-site-tests.el" (file-name-directory load-file-name)) nil t)

(ert-deftest static-site-api-preflight-lock-cancel-and-late-callback ()
  (static-site-test--project
    (let ((static-site--plugins (make-hash-table :test #'equal))
          (static-site--projects (make-hash-table :test #'equal)) callback token)
      (static-site-register-plugin static-site-root 'fixture
       (list :api-version 1 :actions (list (cons 'build (lambda (_ done) (setq callback done))))))
      (setq token (static-site-invoke-action 'build))
      (should-error (static-site-invoke-action 'build) :type 'user-error)
      (static-site-cancel)
      (should (eq (plist-get (plist-get token :result) :status) 'cancelled))
      (funcall callback '(:status success))
      (should (eq (plist-get (plist-get token :result) :status) 'cancelled))
      (should-not (static-site--state-action (static-site--state))))))

(ert-deftest static-site-api-repeated-cancel-retains-stopping-ownership ()
  (let* ((finished nil)
         (token (list :cancelled nil :finish (lambda (_) (setq finished t))))
         (state (static-site--make-state :process 'stopping-parent :action token)))
    (cl-letf (((symbol-function 'static-site--state) (lambda () state))
              ((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'process-get) (lambda (_ property) (eq property 'static-site-stopping))))
      (static-site-cancel)
      (should (plist-get token :cancelled))
      (should-not finished)
      (should (eq token (static-site--state-action state))))))

(ert-deftest static-site-api-real-job-second-generator-and-environment ()
  (static-site-test--project
    (let ((static-site--plugins (make-hash-table :test #'equal))
          (static-site--projects (make-hash-table :test #'equal))
          (node (executable-find "node")))
      (static-site-register-plugin static-site-root 'plain-html
       (list :api-version 1
             :settings '((static-site-backend . "plain-html") (static-site-environment . (("SITE_VALUE" . "captured"))))
             :actions (list (cons 'build (lambda (context done)
                       (static-site-run-job context
                        (list :argv (list node "-e" "require('fs').writeFileSync('result.txt', process.env.SITE_VALUE)")) done))))))
      (let ((token (static-site-invoke-action 'build)))
        (static-site-test--wait (lambda () (plist-get token :done)))
        (should (eq (plist-get (plist-get token :result) :status) 'success))
        (should (equal (with-temp-buffer (insert-file-contents "result.txt") (buffer-string)) "captured"))))))

(ert-deftest static-site-api-snapshots-and-conflict-policy ()
  (static-site-test--project
    (let ((static-site--plugins (make-hash-table :test #'equal))
          (static-site--projects (make-hash-table :test #'equal)) value)
      (static-site-register-plugin static-site-root 'example
       (list :api-version 1 :actions (list (cons 'doctor (lambda (_ done) (setq value 1) (funcall done '(:status success)))))))
      (let ((old (static-site-context)))
        (static-site-register-plugin static-site-root 'example
         (list :api-version 1 :actions (list (cons 'doctor (lambda (_ done) (setq value 2) (funcall done '(:status success)))))))
        (static-site-invoke-action 'doctor old)
        (should (= value 1))
        (static-site-invoke-action 'doctor)
        (should (= value 2)))
      (should-error (static-site-register-plugin static-site-root 'other
                    (list :api-version 1 :actions '((doctor . ignore)))))
      (should-error (static-site-register-plugin static-site-root 'future '(:api-version 99))))))

(defvar static-site-test-local-list '(original))
(ert-deftest static-site-api-buffer-lifecycle-preserves-user-and-global-settings ()
  (static-site-test--project
    (let ((static-site--plugins (make-hash-table :test #'equal))
          (static-site--projects (make-hash-table :test #'equal)))
      (static-site-register-plugin static-site-root 'writing
       (list :api-version 1 :setup (lambda (_) (static-site-buffer-contribute 'static-site-test-local-list '(plugin)))
             :teardown (lambda (_ token) (static-site-buffer-withdraw token))))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory static-site-root))
        (latex-mode)
        (static-site-mode 1)
        (static-site-mode 1)
        (should (equal static-site-test-local-list '(plugin original)))
        (push 'user static-site-test-local-list)
        (static-site-mode -1)
        (should (equal static-site-test-local-list '(user original))))
      (should (equal (default-value 'static-site-test-local-list) '(original)))
      (with-temp-buffer (latex-mode) (should-not static-site-mode)
                        (should (equal static-site-test-local-list '(original)))))))

(ert-deftest static-site-api-completion-nesting-comments-and-bound ()
  (with-temp-buffer
    (setq-local static-site-metadata-command "Meta" static-site-metadata-keys '(("visibility" "draft" "public") ("title")))
    (insert "\\Meta{title={nested {x,y} and \\{z\\}},visibility={dr")
    (should (equal (nth 2 (static-site-completion-at-point)) '("draft" "public")))
    (insert "% ignored,")
    (should-not (static-site-completion-at-point))
    (erase-buffer) (insert "\\Meta{title={" (make-string 21000 ?x) "},vis")
    (should-not (static-site-completion-at-point))))

(ert-deftest static-site-api-probe-coalesces-and-idle-backs-off ()
  (let ((session (list :phase 'ready :interval 2 :idle-count 12 :request nil :hurry-until 0 :timer nil))
        (state (static-site--make-state)) callback (requests 0) (calls 0) delay)
    (setf (static-site--state-preview state) session)
    (cl-letf (((symbol-function 'static-site-preview--request-start)
               (lambda (s fn) (cl-incf requests) (setq callback fn) (setf (plist-get s :request) t))))
      (static-site-preview--request session (lambda (&rest _) (cl-incf calls)))
      (static-site-preview--request session (lambda (&rest _) (cl-incf calls)))
      (funcall callback 200 "ok")
      (should (= requests 1)) (should (= calls 2)))
    (cl-letf (((symbol-function 'run-at-time) (lambda (seconds &rest _) (setq delay seconds) nil)))
      (static-site-preview--schedule state session)
      (should (= delay 30))
      (setf (plist-get session :hurry-until) (+ (float-time) 5))
      (static-site-preview--schedule state session)
      (should (< delay 1)))))

(ert-deftest static-site-api-hidden-eww-and-page-revision ()
  (let* ((buffer (generate-new-buffer " *hidden site*"))
         (state (static-site--make-state))
         (session (list :phase 'ready :url "http://127.0.0.1:9000/" :decoder nil
                        :revision 1 :page-revisions '(("/a/" . "one")) :idle-count 0
                        :ready-once t :callbacks nil :display nil :buffer nil :deadline 0
                        :startup-timeout 30 :eww-buffers (list buffer)))
         (reloads 0))
    (setf (static-site--state-preview state) session)
    (unwind-protect
        (cl-letf (((symbol-function 'static-site-preview--schedule) #'ignore)
                  ((symbol-function 'eww-reload) (lambda (&rest _) (cl-incf reloads))))
          (with-current-buffer buffer (eww-mode) (setq-local eww-data '(:url "http://127.0.0.1:9000/a/")))
          (static-site-preview--update state session '(:ready t :revision 2 :page-revisions (("/a/" . "one"))))
          (with-current-buffer buffer (should-not static-site-preview--dirty-url))
          (static-site-preview--update state session '(:ready t :revision 3 :page-revisions (("/a/" . "two"))))
          (with-current-buffer buffer (should static-site-preview--dirty-url))
          (should (= reloads 0))
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (static-site-preview--visible (selected-window))
            (should (= reloads 1))))
      (kill-buffer buffer))))

(ert-deftest static-site-api-root-switch-and-failed-setup-cleanup ()
  (static-site-test--project
    (let* ((static-site--plugins (make-hash-table :test #'equal))
           (static-site--projects (make-hash-table :test #'equal))
           (second (expand-file-name "second/" static-site-root))
           (global-map (copy-tree (default-value 'minor-mode-overriding-map-alist))))
      (make-directory second)
      (static-site-register-plugin static-site-root 'one
       (list :api-version 1 :setup (lambda (_) (static-site-buffer-contribute 'static-site-test-local-list '(one)))))
      (static-site-register-plugin second 'two
       (list :api-version 1 :setup (lambda (_) (static-site-buffer-contribute 'static-site-test-local-list '(two)))))
      (with-temp-buffer
        (setq default-directory (file-name-as-directory static-site-root))
        (static-site-mode 1)
        (should (equal static-site-test-local-list '(one original)))
        (setq-local static-site-root second)
        (static-site-context)
        (should (equal static-site-test-local-list '(two original)))
        (static-site-mode -1))
      (should (equal (default-value 'minor-mode-overriding-map-alist) global-map))
      (static-site-register-plugin second 'two
       (list :api-version 1 :setup (lambda (_)
                                    (static-site-buffer-contribute 'static-site-test-local-list '(failed))
                                    (error "Setup failed"))))
      (with-temp-buffer
        (setq-local static-site-root second)
        (should-error (static-site-mode 1))
        (should (equal static-site-test-local-list '(original)))))))

(ert-run-tests-batch-and-exit "static-site-api-")
