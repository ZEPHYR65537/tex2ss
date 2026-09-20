;;; init-static-site.el --- Local static-site tools -*- lexical-binding: t -*-
;;; Commentary:
;; Independent Git checkout: ~/.emacs.d/pkg/static_site
;; Follow the existing Purcell init-* convention for locally maintained
;; packages.  Project settings belong in trusted directory-local variables.
;;; Code:

(add-to-list 'load-path (expand-file-name "pkg/static_site" user-emacs-directory))

;; Avoid loading compilation/EWW and the package itself during startup.
(dolist (command '(static-site-mode
                   static-site-make4ht-setup
                   static-site-build
                   static-site-cancel
                   static-site-open-project
                   static-site-open-public
                   static-site-preview-start
                   static-site-preview-stop
                   static-site-preview-browser
                   static-site-preview-eww
                   static-site-deploy-preview
                   static-site-deploy-publish
                   static-site-deploy-forget))
  (autoload command "static-site" nil t))

(provide 'init-static-site)
;;; init-static-site.el ends here
