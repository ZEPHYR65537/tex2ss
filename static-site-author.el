;;; static-site-author.el --- Small configurable authoring helpers -*- lexical-binding: t; -*-
;;; Commentary:
;; Metadata grammar and templates belong to the project.  There is no template
;; engine: values are literal text with one cursor marker, or Elisp functions.
;;; Code:
(require 'static-site)

(defcustom static-site-metadata-command nil
  "TeX command containing literal key/value metadata, without its backslash."
  :type '(choice (const nil) string) :group 'static-site)
(defcustom static-site-metadata-keys nil
  "Metadata completion alist: (KEY . ENUM-VALUES).
Use nil ENUM-VALUES for free text.  This is completion, not a TeX parser."
  :type '(alist :key-type string :value-type (repeat string)) :group 'static-site)
(defcustom static-site-templates
  '(("article" . "\\documentclass{article}\n\\title{Untitled}\n\\begin{document}\n\\maketitle\n{{point}}\n\\end{document}\n")
    ("media" . "\\includegraphics{media/{{point}}}"))
  "Templates as (NAME . TEXT-OR-FUNCTION).
TEXT is inserted literally; {{point}} marks the cursor.  A function inserts
its own content and may prompt.  Projects may add widgets or replace article
and media templates.  No blog macros are imposed on general TeX projects."
  :type '(alist :key-type string :value-type (choice string function)) :group 'static-site)
(dolist (variable '(static-site-metadata-command static-site-metadata-keys static-site-templates))
  (make-variable-buffer-local variable))

(defvar static-site-author--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?% "<" table)
    (modify-syntax-entry ?\n ">" table)
    table))

(defun static-site-completion-at-point ()
  "Complete literal metadata with a bounded single scan of its contents."
  (when (and static-site-metadata-command static-site-metadata-keys)
    (save-excursion
      (let ((end (point)) (limit (max (point-min) (- (point) 20000))))
        (when (re-search-backward
               (concat "\\\\" (regexp-quote static-site-metadata-command) "[ \t\n]*{") limit t)
          (let ((start (match-end 0)) (entry (match-end 0)) (depth 1) comment)
            (with-syntax-table static-site-author--syntax-table
              (unless (nth 4 (parse-partial-sexp (line-beginning-position) (point)))
                (goto-char start)
                (while (and (< (point) end) (> depth 0))
                  (let ((char (char-after)))
                    (cond
                     (comment (when (= char ?\n) (setq comment nil)))
                     ((= char ?\\) (when (< (1+ (point)) end) (forward-char)))
                     ((= char ?%) (setq comment t))
                     ((= char ?{) (setq depth (1+ depth)))
                     ((= char ?}) (setq depth (1- depth)))
                     ((and (= char ?,) (= depth 1)) (setq entry (1+ (point)))))
                    (forward-char)))
                  (when (and (> depth 0) (not comment))
                    (let ((text (buffer-substring-no-properties entry end)))
                      (cond
                       ((string-match "\\`[ \t\n]*\\([a-zA-Z0-9_.-]*\\)\\'" text)
			(list (- end (length (match-string 1 text))) end
                              (mapcar #'car static-site-metadata-keys) :exclusive 'no))
                       ((string-match "\\`[ \t\n]*\\([a-zA-Z0-9_.-]+\\)[ \t\n]*=[ \t\n]*{?\\([a-zA-Z0-9_-]*\\)\\'" text)
			(when-let* ((values (cdr (assoc (match-string 1 text) static-site-metadata-keys))))
                          (list (- end (length (match-string 2 text))) end values :exclusive 'no))))))))))))))

;;;###autoload
(defun static-site-insert-template (name)
  "Insert project template NAME at point."
  (interactive
   (progn (static-site--configure)
          (list (completing-read "Template: " static-site-templates nil t))))
  (static-site--configure)
  (let ((template (cdr (assoc name static-site-templates))))
    (cond
     ((stringp template)
      (atomic-change-group
        (let ((start (point)))
          (insert template)
          (when (search-backward "{{point}}" start t)
            (delete-char (length "{{point}}"))))))
     ((functionp template) (funcall template))
     (t (user-error "No %s template configured for this project" name)))))

;;;###autoload
(defun static-site-new-article (file)
  "Create a new article FILE within the current project, without overwriting."
  (interactive (list (read-file-name "New article file: " (static-site--root) nil nil "index.tex")))
  (static-site--configure)
  (let ((root (static-site--root))
        (templates (copy-tree static-site-templates))
        (file (expand-file-name file)))
    (unless (and (not (file-remote-p file)) (file-in-directory-p (file-truename file) root))
      (user-error "Article must be inside this project"))
    (when (file-exists-p file) (user-error "File already exists: %s" file))
    (when-let* ((buffer (get-file-buffer file)))
      (when (buffer-modified-p buffer) (user-error "An unsaved article already exists in that buffer")))
    (make-directory (file-name-directory file) t)
    (find-file file)
    (setq-local static-site-root root static-site-templates templates)
    (static-site-author-mode 1)
    (static-site-insert-template "article")))

;;;###autoload
(define-minor-mode static-site-author-mode
  "Opt-in completion and templates; keep the existing TeX major mode."
  :lighter " Author"
  (if static-site-author-mode
      (progn (static-site--configure)
             (add-hook 'completion-at-point-functions #'static-site-completion-at-point nil t))
    (remove-hook 'completion-at-point-functions #'static-site-completion-at-point t)))

(provide 'static-site-author)
;;; static-site-author.el ends here
