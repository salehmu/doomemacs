;;; core/cli/autoloads.el -*- lexical-binding: t; -*-

(require 'autoload)


(defvar doom-autoload-excluded-packages '("gh")
  "Packages that have silly or destructive autoload files that try to load
everyone in the universe and their dog, causing errors that make babies cry. No
one wants that.")

;; external variables
(defvar autoload-timestamps)
(defvar generated-autoload-load-name)
(defvar generated-autoload-file)


;;
;;; Commands

(defcli! (autoloads a) ()
  "Regenerates Doom's autoloads files.

It scans and reads autoload cookies (;;;###autoload) in core/autoload/*.el,
modules/*/*/autoload.el and modules/*/*/autoload/*.el, and generates and
byte-compiles `doom-autoload-file', as well as `doom-package-autoload-file'
(created from the concatenated autoloads files of all installed packages).

It also caches `load-path', `Info-directory-list', `doom-disabled-packages',
`package-activated-list' and `auto-mode-alist'."
  ;; REVIEW Can we avoid calling `straight-check-all' everywhere?
  (straight-check-all)
  (doom-reload-autoloads nil 'force))


;;
;;; Helpers

(defun doom-delete-autoloads-file (file)
  "Delete FILE (an autoloads file) and accompanying *.elc file, if any."
  (cl-check-type file string)
  (when (file-exists-p file)
    (when-let (buf (find-buffer-visiting file))
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (kill-buffer buf))
    (delete-file file)
    (ignore-errors (delete-file (byte-compile-dest-file file)))
    t))

(defun doom--warn-refresh-session-h ()
  (message "Restart or reload Doom Emacs for changes to take effect:\n")
  (message "  M-x doom/restart-and-restore")
  (message "  M-x doom/restart")
  (message "  M-x doom/reload"))

(defun doom--byte-compile-file (file)
  (let ((byte-compile-warnings (if doom-debug-mode byte-compile-warnings))
        (byte-compile-dynamic t)
        (byte-compile-dynamic-docstrings t))
    (condition-case-unless-debug e
        (when (byte-compile-file file)
          (prog1 (load file 'noerror 'nomessage)
            (when noninteractive
              (add-hook 'doom-cli-post-success-execute-hook #'doom--warn-refresh-session-h))))
      ((debug error)
       (let ((backup-file (concat file ".bk")))
         (print! (warn "Copied backup to %s") (relpath backup-file))
         (copy-file file backup-file 'overwrite))
       (doom-delete-autoloads-file file)
       (signal 'doom-autoload-error (list file e))))))

(defun doom-reload-autoloads (&optional file force-p)
  "Reloads FILE (an autoload file), if it needs reloading.

FILE should be one of `doom-autoload-file' or `doom-package-autoload-file'. If
it is nil, it will try to reload both. If FORCE-P (universal argument) do it
even if it doesn't need reloading!"
  (or (null file)
      (stringp file)
      (signal 'wrong-type-argument (list 'stringp file)))
  (if (stringp file)
      (cond ((file-equal-p file doom-autoload-file)
             (doom-reload-core-autoloads force-p))
            ((file-equal-p file doom-package-autoload-file)
             (doom-reload-package-autoloads force-p))
            ((error "Invalid autoloads file: %s" file)))
    (doom-reload-core-autoloads force-p)
    (doom-reload-package-autoloads force-p)))


;;
;;; Doom autoloads

(defun doom--generate-header (func)
  (goto-char (point-min))
  (insert ";; -*- lexical-binding:t; -*-\n"
          ";; This file is autogenerated by `" (symbol-name func) "', DO NOT EDIT !!\n\n"))

(defun doom--generate-autoloads (targets)
  (let ((n 0))
    (dolist (file targets)
      (insert
       (with-temp-buffer
         (cond ((not (doom-file-cookie-p file))
                (print! (debug "Ignoring %s") (relpath file)))

               ((let ((generated-autoload-load-name (file-name-sans-extension file)))
                  (autoload-generate-file-autoloads file (current-buffer)))
                (print! (debug "Nothing in %s") (relpath file)))

               ((cl-incf n)
                (print! (debug "Scanning %s...") (relpath file))))
         (buffer-string))))
    (print! (class (if (> n 0) 'success 'info)
                   "Scanned %d file(s)")
            n)))

(defun doom--expand-autoload-paths (&optional allow-internal-paths)
  (let ((load-path
         ;; NOTE With `doom-private-dir' in `load-path', Doom autoloads files
         ;; will be unable to declare autoloads for the built-in autoload.el
         ;; Emacs package, should $DOOMDIR/autoload.el exist. Not sure why
         ;; they'd want to though, so it's an acceptable compromise.
         (append (list doom-private-dir)
                 doom-modules-dirs
                 (straight--directory-files (straight--build-dir) nil t)
                 load-path)))
    (defvar doom--autoloads-path-cache nil)
    (while (re-search-forward "^\\s-*(\\(?:custom-\\)?autoload\\s-+'[^ ]+\\s-+\"\\([^\"]*\\)\"" nil t)
      (let ((path (match-string 1)))
        (replace-match
         (or (cdr (assoc path doom--autoloads-path-cache))
             (when-let* ((libpath (or (and allow-internal-paths
                                           (locate-library path nil (cons doom-emacs-dir doom-modules-dirs)))
                                      (locate-library path)))
                         (libpath (file-name-sans-extension libpath))
                         (libpath (abbreviate-file-name libpath)))
               (push (cons path libpath) doom--autoloads-path-cache)
               libpath)
             path)
         t t nil 1)))))

(defun doom--generate-autodefs-1 (path &optional member-p)
  (let (forms)
    (while (re-search-forward "^;;;###autodef *\\([^\n]+\\)?\n" nil t)
      (let* ((sexp (sexp-at-point))
             (alt-sexp (match-string 1))
             (type (car sexp))
             (name (doom-unquote (cadr sexp)))
             (origin (doom-module-from-path path)))
        (cond
         ((and (not member-p)
               alt-sexp)
          (push (read alt-sexp) forms))

         ((memq type '(defun defmacro cl-defun cl-defmacro))
          (cl-destructuring-bind (_ _name arglist &rest body) sexp
            (appendq!
             forms
             (list (if member-p
                       (make-autoload sexp path)
                     (let ((docstring
                            (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                                    origin
                                    (if (stringp (car body))
                                        (pop body)
                                      "No documentation."))))
                       (condition-case-unless-debug e
                           (if alt-sexp
                               (read alt-sexp)
                             (append
                              (list (pcase type
                                      (`defun 'defmacro)
                                      (`cl-defun `cl-defmacro)
                                      (_ type))
                                    name arglist docstring)
                              (cl-loop for arg in arglist
                                       if (and (symbolp arg)
                                               (not (keywordp arg))
                                               (not (memq arg cl--lambda-list-keywords)))
                                       collect arg into syms
                                       else if (listp arg)
                                       collect (car arg) into syms
                                       finally return (if syms `((ignore ,@syms))))))
                         ('error
                          (print! "- Ignoring autodef %s (%s)" name e)
                          nil))))
                   `(put ',name 'doom-module ',origin)))))

         ((eq type 'defalias)
          (cl-destructuring-bind (_type name target &optional docstring) sexp
            (let ((name (doom-unquote name))
                  (target (doom-unquote target)))
              (unless member-p
                (setq target #'ignore
                      docstring
                      (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                              origin docstring)))
              (appendq! forms `((put ',name 'doom-module ',origin)
                                (defalias ',name #',target ,docstring))))))

         (member-p (push sexp forms)))))
    forms))

(defun doom--generate-autodefs (targets enabled-targets)
  (goto-char (point-max))
  (search-backward ";;;***" nil t)
  (save-excursion (insert "\n"))
  (dolist (path targets)
    (insert
     (with-temp-buffer
       (insert-file-contents path)
       (if-let (forms (doom--generate-autodefs-1 path (member path enabled-targets)))
           (concat (mapconcat #'prin1-to-string (nreverse forms) "\n")
                   "\n")
         "")))))

(defun doom--cleanup-autoloads ()
  (goto-char (point-min))
  (when (re-search-forward "^;;\\(;[^\n]*\\| no-byte-compile: t\\)\n" nil t)
    (replace-match "" t t)))

(defun doom-reload-core-autoloads (&optional force-p)
  "Refreshes `doom-autoload-file', if necessary (or if FORCE-P is non-nil).

It scans and reads autoload cookies (;;;###autoload) in core/autoload/*.el,
modules/*/*/autoload.el and modules/*/*/autoload/*.el, and generates
`doom-autoload-file'.

Run this whenever your `doom!' block, or a module autoload file, is modified."
  (let* ((default-directory doom-emacs-dir)
         (doom-modules (doom-modules))

         ;; The following bindings are in `package-generate-autoloads'.
         ;; Presumably for a good reason, so I just copied them
         (noninteractive t)
         (backup-inhibited t)
         (version-control 'never)
         (case-fold-search nil)  ; reduce magic
         (autoload-timestamps nil)

         ;; Where we'll store the files we'll scan for autoloads. This should
         ;; contain *all* autoload files, even in disabled modules, so we can
         ;; scan those for autodefs. We start with the core libraries.
         (targets (doom-glob doom-core-dir "autoload/*.el"))
         ;; A subset of `targets' in enabled modules
         (active-targets (copy-sequence targets)))

    (dolist (path (doom-module-load-path 'all-p))
      (when-let* ((files (cons (doom-glob path "autoload.el")
                               (doom-files-in (doom-path path "autoload")
                                              :match "\\.el$")))
                  (files (delq nil files)))
        (appendq! targets files)
        (when (or (doom-module-from-path path 'enabled-only)
                  (file-equal-p path doom-private-dir))
          (appendq! active-targets files))))

    (print! (start "Checking core autoloads file"))
    (print-group!
     (if (and (not force-p)
              (file-exists-p doom-autoload-file)
              (not (file-newer-than-file-p doom-emacs-dir doom-autoload-file))
              (not (cl-loop for dir
                            in (append (doom-glob doom-private-dir "init.el*")
                                       targets)
                            if (file-newer-than-file-p dir doom-autoload-file)
                            return t)))
         (ignore
          (print! (success "Skipping core autoloads, they are up-to-date"))
          (doom-load-autoloads-file doom-autoload-file))
       (print! (start "Regenerating core autoloads file"))

       (if (doom-delete-autoloads-file doom-autoload-file)
           (print! (success "Deleted old %s") (filename doom-autoload-file))
         (make-directory (file-name-directory doom-autoload-file) t))

       (with-temp-file doom-autoload-file
         (doom--generate-header 'doom-reload-core-autoloads)
         (save-excursion
           (doom--generate-autoloads active-targets)
           (print! (success "Generated new autoloads.el")))
         ;; Replace autoload paths (only for module autoloads) with absolute
         ;; paths for faster resolution during load and simpler `load-path'
         (save-excursion
           (doom--expand-autoload-paths 'allow-internal-paths)
           (print! (success "Expanded module autoload paths")))
         ;; Generates stub definitions for functions/macros defined in disabled
         ;; modules, so that you will never get a void-function when you use
         ;; them.
         (save-excursion
           (doom--generate-autodefs targets (reverse active-targets))
           (print! (success "Generated autodefs")))
         ;; Remove byte-compile-inhibiting file variables so we can byte-compile
         ;; the file, and autoload comments.
         (doom--cleanup-autoloads)
         (print! (success "Clean up autoloads")))
       ;; Byte compile it to give the file a chance to reveal errors (and buy us a
       ;; few marginal performance boosts)
       (print! "> Byte-compiling %s..." (relpath doom-autoload-file))
       (when (doom--byte-compile-file doom-autoload-file)
         (print! (success "Finished compiling %s") (relpath doom-autoload-file))))
     t)))


;;
;;; Package autoloads

(defun doom--generate-package-autoloads ()
  "Concatenates package autoload files, let-binds `load-file-name' around
them,and remove unnecessary `provide' statements or blank links."
  (dolist (pkg (hash-table-keys straight--build-cache))
    (unless (member pkg doom-autoload-excluded-packages)
      (let ((file (straight--autoloads-file pkg)))
        (when (file-exists-p file)
          (insert-file-contents file)
          (save-excursion
            (while (re-search-forward "\\(?:\\_<load-file-name\\|#\\$\\)\\_>" nil t)
              ;; `load-file-name' is meaningless in a concatenated
              ;; mega-autoloads file, so we replace references to it and #$ with
              ;; the file they came from.
              (unless (doom-point-in-string-or-comment-p)
                (replace-match (prin1-to-string (abbreviate-file-name file))
                               t t))))
          (while (re-search-forward "^\\(?:;;\\(.*\n\\)\\|\n\\|(provide '[^\n]+\\)" nil t)
            (unless (doom-point-in-string-p)
              (replace-match "" t t)))
          (unless (bolp) (insert "\n")))))))

(defun doom--generate-var-cache ()
  "Print a `setq' form for expensive-to-initialize variables, so we can cache
them in Doom's autoloads file."
  (doom-initialize-packages)
  (prin1 `(setq load-path ',load-path
                auto-mode-alist ',auto-mode-alist
                Info-directory-list ',Info-directory-list
                doom-disabled-packages ',doom-disabled-packages)
         (current-buffer)))

(defun doom--cleanup-package-autoloads ()
  "Remove (some) forms that modify `load-path' or `auto-mode-alist'.

These variables are cached all at once and at later, so these removed statements
served no purpose but to waste cycles."
  (while (re-search-forward "^\\s-*\\((\\(?:add-to-list\\|\\(?:when\\|if\\) (boundp\\)\\s-+'\\(?:load-path\\|auto-mode-alist\\)\\)" nil t)
    (goto-char (match-beginning 1))
    (kill-sexp)))

(defun doom-reload-package-autoloads (&optional force-p)
  "Compiles `doom-package-autoload-file' from the autoloads files of all
installed packages. It also caches `load-path', `Info-directory-list',
`doom-disabled-packages', `package-activated-list' and `auto-mode-alist'.

Will do nothing if none of your installed packages have been modified. If
FORCE-P (universal argument) is non-nil, regenerate it anyway.

This should be run whenever your `doom!' block or update your packages."
  (print! (start "Checking package autoloads file"))
  (print-group!
   (if (and (not force-p)
            (file-exists-p doom-package-autoload-file)
            (not (file-newer-than-file-p package-user-dir doom-package-autoload-file))
            (not (cl-loop for dir in (straight--directory-files (straight--build-dir))
                          if (cl-find-if
                              (lambda (dir)
                                (file-newer-than-file-p dir doom-package-autoload-file))
                              (doom-glob (straight--build-dir dir) "*.el"))
                          return t))
            (not (cl-loop with doom-modules = (doom-modules)
                          for key being the hash-keys of doom-modules
                          for path = (doom-module-path (car key) (cdr key) "packages.el")
                          if (file-newer-than-file-p path doom-package-autoload-file)
                          return t)))
       (ignore
        (print! (success "Skipping package autoloads, they are up-to-date"))
        (doom-load-autoloads-file doom-package-autoload-file))
     (let (;; The following bindings are in `package-generate-autoloads'.
           ;; Presumably for a good reason, so I just copied them
           (noninteractive t)
           (backup-inhibited t)
           (version-control 'never)
           (case-fold-search nil)  ; reduce magic
           (autoload-timestamps nil))
       (print! (start "Regenerating package autoloads file"))

       (if (doom-delete-autoloads-file doom-package-autoload-file)
           (print! (success "Deleted old %s") (filename doom-package-autoload-file))
         (make-directory (file-name-directory doom-autoload-file) t))

       (with-temp-file doom-package-autoload-file
         (doom--generate-header 'doom-reload-package-autoloads)

         (save-excursion
           ;; Cache important and expensive-to-initialize state here.
           (doom--generate-var-cache)
           (print! (success "Cached package state"))
           ;; Concatenate the autoloads of all installed packages.
           (doom--generate-package-autoloads)
           (print! (success "Package autoloads included")))

         ;; Replace autoload paths (only for module autoloads) with absolute
         ;; paths for faster resolution during load and simpler `load-path'
         (save-excursion
           (doom--expand-autoload-paths)
           (print! (success "Expanded module autoload paths")))

         ;; Remove `load-path' and `auto-mode-alist' modifications (most of them,
         ;; at least); they are cached later, so all those membership checks are
         ;; unnecessary overhead.
         (doom--cleanup-package-autoloads)
         (print! (success "Removed load-path/auto-mode-alist entries")))
       ;; Byte compile it to give the file a chance to reveal errors (and buy us a
       ;; few marginal performance boosts)
       (print! (start "Byte-compiling %s...") (relpath doom-package-autoload-file))
       (when (doom--byte-compile-file doom-package-autoload-file)
         (print! (success "Finished compiling %s") (relpath doom-package-autoload-file)))))
   t))
