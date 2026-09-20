;;; init-static-site.el --- Local static-site tools -*- lexical-binding: t -*-
;;; Commentary:
;; Independent Git checkout: ~/.emacs.d/pkg/static_site
;; Follow the existing Purcell init-* convention for locally maintained
;; packages.  Project settings belong in trusted directory-local variables.
;;; Code:
(defvar projectile-command-map)
(defvar project-prefix-map)

(add-to-list 'load-path (expand-file-name "pkg/static_site" user-emacs-directory))

;; Avoid loading compilation/EWW and the package itself during startup.
(dolist (command '(static-site-mode
                   static-site-project-dispatch
                   static-site-make4ht-setup
                   static-site-build
                   static-site-cancel
                   static-site-open-project
                   static-site-open-public
                   static-site-deploy-preview
                   static-site-deploy-publish
                   static-site-deploy-forget))
  (autoload command "static-site" nil t))
(dolist (command '(static-site-preview-start static-site-preview-stop
                   static-site-preview-follow static-site-preview-status
                   static-site-preview-browser static-site-preview-eww))
  (autoload command "static-site-preview" nil t))
(dolist (command '(static-site-author-mode static-site-insert-template static-site-new-article))
  (autoload command "static-site-author" nil t))

;; Keep Purcell's lazy Projectile activation and existing prefix unchanged.
(with-eval-after-load 'projectile
  (unless (lookup-key projectile-command-map (kbd "C-s"))
    (define-key projectile-command-map (kbd "C-s") #'static-site-project-dispatch)))
(with-eval-after-load 'project
  (unless (lookup-key project-prefix-map (kbd "C-s"))
    (define-key project-prefix-map (kbd "C-s") #'static-site-project-dispatch)))

(provide 'init-static-site)
;;; init-static-site.el ends here
