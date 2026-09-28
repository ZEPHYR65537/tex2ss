;;; static-site-deploy-rsync.el --- Optional rsync provider -*- lexical-binding: t; -*-
(require 'static-site)
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

(defun static-site--check-tree (directory)
  "Reject symlinks and special files anywhere under DIRECTORY."
  (when (file-symlink-p (directory-file-name directory))
    (user-error "Publish output must not contain symlinks: %s" directory))
  (dolist (entry (directory-files directory t directory-files-no-dot-files-regexp))
    (cond ((file-symlink-p entry) (user-error "Publish output contains a symlink: %s" entry))
          ((file-directory-p entry) (static-site--check-tree entry))
          ((not (file-regular-p entry)) (user-error "Not a regular publish file: %s" entry)))))

(defconst static-site-rsync--library-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun static-site--snapshot-directory (root)
  "Allocate an owned empty snapshot inside ROOT."
  (let ((cache (expand-file-name ".cache/" root)))
    (when (or (file-symlink-p (directory-file-name cache))
              (not (file-in-directory-p (file-truename cache) root)))
      (user-error "Deployment cache must stay inside this project"))
    (make-directory cache t)
    (make-temp-file (expand-file-name "static-site-deploy-" cache) t)))

(defun static-site--fill-snapshot (root source snapshot entry-file)
  "Validate SOURCE and fill owned SNAPSHOT. Called by the batch helper."
  (unless (and (file-in-directory-p snapshot (expand-file-name ".cache/" root))
               (not (file-symlink-p snapshot))
               (string-prefix-p "static-site-deploy-" (file-name-nondirectory snapshot))
               (null (directory-files snapshot nil directory-files-no-dot-files-regexp)))
    (error "Snapshot must be an empty owned directory"))
  (let ((entry (expand-file-name entry-file source)))
    (unless (and (file-directory-p source) (file-in-directory-p entry source)
                 (file-regular-p entry) (> (file-attribute-size (file-attributes entry)) 0))
      (user-error "Publish output needs a nonempty entry file inside it: %s" entry)))
  (static-site--check-tree source)
  (copy-directory source snapshot t t t)
  (set-file-modes snapshot #o700))

(defun static-site--snapshot (root source &optional entry-file)
  "Synchronous snapshot helper retained for compatibility and batch callers."
  (let ((snapshot (static-site--snapshot-directory root)))
    (condition-case err
        (progn (static-site--fill-snapshot root source snapshot (or entry-file static-site-entry-file)) snapshot)
      (error (static-site--remove-snapshot root snapshot) (signal (car err) (cdr err))))))

(defun static-site-rsync--snapshot-command (root source snapshot entry)
  "Return a shell-free batch Emacs command for snapshot IO."
  (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
        "-L" static-site-rsync--library-directory "-l"
        (expand-file-name "static-site-snapshot.el" static-site-rsync--library-directory)
        "--" root source snapshot entry))

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
(defun static-site-rsync-deploy-forget ()
  "Discard this project's prepared deployment snapshot."
  (interactive)
  (let ((state (static-site--state)))
    (static-site--idle state)
    (static-site--remove-snapshot (static-site--state-root state)
                                 (plist-get (static-site--state-plan state) :snapshot))
    (setf (static-site--state-plan state) nil)))

;;;###autoload
(defun static-site-rsync-deploy-preview ()
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
      (static-site-rsync-deploy-forget)
      (static-site--log buffer (format "Destination: %s\nRemove stale files: %s\n" destination delete))
      (static-site--run
       state steps buffer
       (lambda (ok)
         (if (not ok) (message "Deployment stopped: build/validation failed")
           (let ((snapshot (static-site--snapshot-directory root)))
             (static-site--run
              state (list (cons (file-name-as-directory snapshot)
                                (static-site-rsync--snapshot-command root source snapshot entry))
                          (cons (file-name-as-directory snapshot)
                                (append (list (car command) "--dry-run") (cdr command)))) buffer
              (lambda (success)
                (if success
                    (progn
                      (setf (static-site--state-plan state)
                            (list :snapshot snapshot :command command
                                  :environment (copy-sequence process-environment)
                                  :exec-path (copy-sequence exec-path)
                                  :destination destination :delete delete))
                      (message "Review the dry run, then M-x static-site-rsync-deploy-publish"))
                  (static-site--remove-snapshot root snapshot)
                  (message "Deployment preview failed; publishing is disabled")))))))))))

;;;###autoload
(defun static-site-rsync-deploy-publish ()
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
      (user-error "Run M-x static-site-rsync-deploy-preview successfully first"))
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


(provide 'static-site-deploy-rsync)
