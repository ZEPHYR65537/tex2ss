;;; static-site-snapshot.el --- Batch snapshot worker -*- lexical-binding: t; -*-
(setq load-prefer-newer t)
(require 'static-site-deploy-rsync)
(when (equal (car command-line-args-left) "--") (pop command-line-args-left))
(condition-case err
    (pcase-let ((`(,root ,source ,snapshot ,entry) command-line-args-left))
      (static-site--fill-snapshot root source snapshot entry)
      (setq command-line-args-left nil))
  (error (princ (error-message-string err)) (kill-emacs 1)))
