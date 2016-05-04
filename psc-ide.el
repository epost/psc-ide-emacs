;;; psc-ide.el --- Minor mode for PureScript's psc-ide tool. -*- lexical-binding: t -*-

;; Copyright (C) 2015 The psc-ide-emacs authors

;; Author   : Erik Post <erik@shinsetsu.nl>
;;            Dmitry Bushenko <d.bushenko@gmail.com>
;;            Christoph Hegemann
;;            Brian Sermons
;; Homepage : https://github.com/epost/psc-ide-emacs
;; Version  : 0.1.0
;; Package-Requires: ((dash "2.11.0") (company "0.8.7") (cl-lib "0.5") (s "1.10.0"))
;; Keywords : languages

;;; Commentary:

;; Emacs integration for PureScript's psc-ide tool

;;; Code:


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Imports

(require 'company)
(require 'cl-lib)
(require 'dash)
(require 's)
(require 'psc-ide-backported)
(require 'psc-ide-protocol)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; psc-ide-mode definition

;;;###autoload
(define-minor-mode psc-ide-mode
  "psc-ide-mode definition"
  :lighter " psc-ide"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-s") 'psc-ide-server-start)
            (define-key map (kbd "C-c C-q") 'psc-ide-server-quit)
            (define-key map (kbd "C-c C-l") 'psc-ide-load-all)
            (define-key map (kbd "C-c C-S-l") 'psc-ide-load-module)
            (define-key map (kbd "C-c C-a") 'psc-ide-add-clause)
            (define-key map (kbd "C-c C-c") 'psc-ide-case-split)
            (define-key map (kbd "C-c C-i") 'psc-ide-add-import)
            (define-key map (kbd "C-c C-t") 'psc-ide-show-type)
            (define-key map (kbd "C-<SPC>") 'company-complete)
            map))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Settings, override as needed.

(defgroup psc-ide nil
  "Settings for psc-ide."
  :prefix "psc-ide-"
  :group 'psc-ide)

(defcustom psc-ide-client-executable "psc-ide-client"
  "Path to the 'psc-ide-client' executable."
  :group 'psc-ide
  :type  'string)

(defcustom psc-ide-server-executable "psc-ide-server"
  "Path to the 'psc-ide-server' executable."
  :group 'psc-ide
  :type  'string)

(defcustom psc-ide-completion-matcher "flex"
  "The method used for completions."
  :options '("flex" "prefix")
  :group 'psc-ide
  :type  'string)

(defcustom psc-ide-add-import-on-completion "t"
  "Whether to add imports on completion"
  :group 'psc-ide
  :type 'boolean)

(defconst psc-ide-import-regex
  (rx (and line-start "import" (1+ space) (opt (and "qualified" (1+ space)))
        (group (and (1+ (any word "."))))
        (opt (1+ space) "as" (1+ space) (group (and (1+ word))))
        (opt (1+ space) "(" (group (0+ not-newline)) ")"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Interactive.

(add-hook 'after-save-hook
          (lambda ()
            (set 'psc-ide-buffer-import-list
                 (psc-ide-parse-imports-in-buffer)))
          nil t)

(defun psc-ide-init ()
  (interactive)

  (set (make-local-variable 'psc-ide-buffer-import-list)
       (psc-ide-parse-imports-in-buffer)))


(defun company-psc-ide-backend (command &optional arg &rest ignored)
  "The psc-ide backend for 'company-mode'."
  (interactive (list 'interactive))

  (cl-case command
    (interactive (company-begin-backend 'company-psc-ide-backend))

    (init (psc-ide-init))

    (prefix (when (and (eq major-mode 'purescript-mode)
                       (not (company-in-string-or-comment)))
              ;; (psc-ide-ident-at-point)
              (let ((symbol (company-grab-symbol)))
                (if symbol
                    (if (psc-ide-qualified-p symbol)
                        (progn
                          (cons (car (last (s-split "\\." symbol))) t))
                      symbol)
                  'stop))))

    (candidates (cons :async
                      (lambda (cb)
                        (psc-ide-complete-impl arg cb company--manual-action))))

    (sorted t)

    (annotation (psc-ide-annotation arg))

    (meta (get-text-property 0 :type arg))

    (post-completion
     (unless (or
              ;; Don't add an import when the option to do so is disabled
              (not psc-ide-add-import-on-completion)
              ;; or when a qualified identifier was completed
              (get-text-property 0 :qualifier arg))
       (psc-ide-add-import-impl arg (vector
                                     (psc-ide-filter-modules
                                      (list (get-text-property 0 :module arg)))))))))


(defun psc-ide-server-start (dir-name)
  "Start 'psc-ide-server'."
  (interactive (list (read-directory-name "Project root? "
                                          (psc-ide-suggest-project-dir))))
  (psc-ide-server-start-impl dir-name))

(defun psc-ide-server-quit ()
  "Quit 'psc-ide-server'."
  (interactive)
  (psc-ide-send-async psc-ide-command-quit nil))

(defun psc-ide-load-module (module-name)
  "Provide module to load"
  (interactive (list (read-string "Module: " (psc-ide-get-module-name))))
  (psc-ide-load-module-impl module-name))

(defun psc-ide-load-all ()
  "Loads all the modules in the current project"
  (interactive)
  (psc-ide-send-async psc-ide-command-load-all nil))

(defun psc-ide-complete ()
  "Complete prefix string using psc-ide."
  (interactive)
  (psc-ide-complete-impl (psc-ide-ident-at-point)))

(defun psc-ide-show-type ()
  "Show type of the symbol under cursor."
  (interactive)
  (let ((ident (psc-ide-ident-at-point)))
    (psc-ide-show-type-impl ident)))

(defun psc-ide-case-split (type)
  "Case Split on identifier under cursor."
  (interactive "sType: ")
  (psc-ide-case-split-impl
   type
   (lambda (new-lines)
     (beginning-of-line) (kill-line) ;; clears the current line
     (insert (mapconcat 'identity new-lines "\n")))))

(defun psc-ide-add-clause ()
  "Add clause on identifier under cursor."
  (interactive)
  (psc-ide-add-clause-impl
   (lambda (new-lines)
     (beginning-of-line) (kill-line) ;; clears the current line
     (insert (mapconcat 'identity new-lines "\n")))))

(defun psc-ide-add-import ()
  "Add an import for the symbol under the cursor."
  (interactive)
  (psc-ide-add-import-impl (psc-ide-ident-at-point)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Non-interactive.

(defun psc-ide-case-split-impl (type callback)
  "Case Split on TYPE and send results to CALLBACK."
  (let ((reg (psc-ide-ident-pos-at-point)))
    (psc-ide-send-async
     (psc-ide-command-case-split
      (substring (thing-at-point 'line t) 0 -1)
      (save-excursion (goto-char (car reg)) (current-column))
      (save-excursion (goto-char (cdr reg)) (current-column))
      type)
     callback
     t)))

(defun psc-ide-add-clause-impl (callback)
  "Add clause on identifier under cursor and send results to CALLBACK."
  (let ((reg (psc-ide-ident-pos-at-point)))
    (psc-ide-send-async
     (psc-ide-command-add-clause
      (substring (thing-at-point 'line t) 0 -1) nil)
     callback
     t)))

(defun psc-ide-get-module-name ()
  "Return the qualified name of the module in the current buffer."
  (save-excursion
   (save-restriction (widen)
    (goto-char (point-min))
    (when (re-search-forward "module +\\([A-Z][A-Za-z0-9.]*\\)" nil t)
      (buffer-substring-no-properties (match-beginning 1) (match-end 1))))))

(defun psc-ide-parse-exposed (exposed)
  "Parsed the EXPOSED names from a qualified import."
  (if exposed
      (mapcar (lambda (item)
                (s-trim item))
              (s-split "," exposed))
    nil))

(defun psc-ide-extract-import-from-match-data (&optional string)

  "Helper function for use when using the `psc-ide-import-regex' to match
imports to extract the relevant info from the groups.  STRING is for
use when the search used was with `string-match'."

  (let* ((data (match-data))
         (len (length data))
         (idx 3)
         result)
    (push `(module . ,(match-string-no-properties 1 string)) result)
    (push `(alias . ,(match-string-no-properties 2 string)) result)
    (push `(exposing . ,(psc-ide-parse-exposed (match-string-no-properties 3 string))) result)
    result))

(defun psc-ide-parse-imports-in-buffer (&optional buffer)

  "Parse the list of imports for the current purescript BUFFER."

  (let ((module-name (psc-ide-get-module-name))
        (matches))
    (save-match-data
      (save-excursion
        (with-current-buffer (or buffer (current-buffer))
          (save-restriction
            (widen)
            (goto-char (point-min))
            (when module-name
              (push `((module . ,module-name)) matches))
            (while (search-forward-regexp psc-ide-import-regex nil t 1)
              (push (psc-ide-extract-import-from-match-data) matches))))))
    matches))

(defun psc-ide-send (cmd)
  "Send a command to psc-ide."
  (let* ((shellcmd (format "echo '%s'| %s"
                           cmd
                           psc-ide-client-executable))
         (resp (shell-command-to-string shellcmd)))
    ;; (message "Cmd %s\nReceived %s" cmd resp)
    resp))

(defun psc-ide-send-async (cmd callback &optional unwrap)
  "Send a CMD to psc-ide, returning the results to CALLBACK.
If UNWRAP is non-nil, then decode json and unwrap the result before sending it to CALLBACK."
  (let (process)
    (condition-case err
        (let ((process-connection-type nil))
          (setq process (start-process "psc-ide" nil psc-ide-client-executable))
          (set-process-filter process #'psc-ide-receive-output)
          (set-process-sentinel process #'psc-ide-handle-signal)
          (set-process-query-on-exit-flag process nil)
          (process-put process 'psc-ide-command cmd)
          (process-put process 'psc-ide-callback callback)
          (process-put process 'psc-ide-callback-unwrap unwrap)
          (process-send-string process cmd)
          (process-send-string process "\n")
          (process-send-eof process)
          process)
      (error
       (when process
         (delete-process process))
       (signal (car err) (cdr err))))))

(defun psc-ide-receive-output (process output)
  (push output (process-get process 'psc-ide-pending-output)))

(defun psc-ide-get-output (process)
  (with-demoted-errors "Error getting process output: %S"
    (let ((pending-output (process-get process 'psc-ide-pending-output)))
      (apply #'concat (nreverse pending-output)))))

(defun psc-ide-handle-signal (process sig)
  (when (eq (process-status process) 'exit)
    (let ((output (psc-ide-get-output process))
          (callback (process-get process 'psc-ide-callback))
          (unwrap (process-get process 'psc-ide-callback-unwrap)))
      (when callback
        (if unwrap
            (funcall callback (psc-ide-unwrap-result (json-read-from-string output)))
          (funcall callback output))))))


(defun psc-ide-ask-project-dir (cb)
  "Ask psc-ide-server for the project dir."
  (psc-ide-send-async psc-ide-command-cwd (lambda (result) (funcall cb result))))

(defun psc-ide-server-start-impl (dir-name)
  "Start psc-ide-server."
  (apply #'start-process `("*psc-ide-server*" "*psc-ide-server*"
                           ,@(split-string psc-ide-server-executable)
                           "-d" ,dir-name)))

(defun psc-ide-load-module-impl (module-name)
  "Load PureScript module and its dependencies."
  (psc-ide-send-async (psc-ide-command-load
                       [] (list module-name))
                       nil
                       t))

(defun psc-ide-add-import-impl (identifier &optional filters)
  "Invoke the addImport command"
  (let* ((tmp-file (make-temp-file "psc-ide-add-import"))
         (filename (buffer-file-name (current-buffer))))
    (write-region (point-min) (point-max) tmp-file)
    (psc-ide-send-async
     (psc-ide-command-add-import identifier filters tmp-file tmp-file)
     (lambda (result)
       (if (not (stringp result))
           (let ((selection
                  (completing-read "Which Module to import from: "
                                   (-map (lambda (x)
                                           (cdr (assoc 'module x))) result))))
             (psc-ide-add-import-impl identifier (vector (psc-ide-filter-modules (vector selection)))))
         (progn (message (concat "Added import for " identifier))
                (save-restriction
                  (widen)
                  ;; command successful, insert file with replacement to preserve
                  ;; markers.
                  (insert-file-contents tmp-file nil nil nil t))))
       (delete-file tmp-file))
     t)))

(defun psc-ide-filter-bare-imports (imports)
  "Filter out all alias imports."
  (->> imports
       (-filter (lambda (import)
                  (and
                   ;;(not (cdr (assoc 'exposing import)))
                   (not (cdr (assoc 'alias import))))))
       (-map (lambda (import)
               (cdr (assoc 'module import))))))


(defun psc-ide-filter-imports-by-alias (imports alias)
  "Filters the IMPORTS by ALIAS.  If nothing is found then just return ALIAS
unchanged."
  (let ((result (->> imports
                     (-filter (lambda (import)
                                (equal (cdr (assoc 'alias import))
                                       alias)))
                     (-map (lambda (import)
                             (cdr (assoc 'module import)))))))
    (if result
        result
      (list alias))))

(defun psc-ide-find-import (imports name)
  (-find (lambda (import)
           (equal (assoc 'module import) name))
         imports))

(defun psc-ide-qualified-p (name)
  (s-contains-p "." name))


(defun psc-ide-get-ident-context (prefix imports)
  "Split the prefix into the qualifier and search term from PREFIX.
Returns an plist with the search, qualifier, and relevant modules."
  (let* ((components (s-split "\\." prefix))
         (search (car (last components)))
         (qualifier (s-join "." (butlast components))))
    (if (equal "" qualifier)
        (list 'search search 'qualifier nil 'modules (psc-ide-filter-bare-imports imports))
      (list 'search search 'qualifier qualifier 'modules (psc-ide-filter-imports-by-alias imports qualifier)))))


(defun psc-ide-make-module-filter (type modules)
  (list :filter type
        :params (list :modules modules)))

(defun psc-ide-filter-results-p (imports search qualifier result)
  (let ((completion (cdr (assoc 'identifier result)))
        (type (cdr (assoc 'type result)))
        (module (cdr (assoc 'module result))))
    (if qualifier
        t ;; return all results from qualified imports
      (-find (lambda (import)
               ;; return t for explicit imported names and open imports
               (if (and
                    (equal module (cdr (assoc 'module import)))
                    (not (cdr (assoc 'alias import)))
                    (or (not (cdr (assoc 'exposing import)))
                        (-contains? (cdr (assoc 'exposing import)) completion)))
                   t
                 nil))
             imports))))

(defun psc-ide-complete-impl (prefix cb &optional nofilter)
  "Complete."
  (when psc-ide-buffer-import-list
    (let* ((pprefix (psc-ide-get-ident-context
                     (company-grab-symbol)
                     psc-ide-buffer-import-list))
           (search (plist-get pprefix 'search))
           (qualifier (plist-get pprefix 'qualifier))
           (moduleFilters (plist-get pprefix 'modules))
           (annotate (lambda (type module qualifier str)
                       (add-text-properties 0 1 (list :type type
                                                      :module module
                                                      :qualifier qualifier) str)
                       str))
           (prefilter (psc-ide-filter-prefix prefix))
           (filters (-non-nil (list (psc-ide-make-module-filter "modules" moduleFilters) prefilter))))
      (psc-ide-send-async
       (psc-ide-command-complete
        (if nofilter
            (vector prefilter) ;; (vconcat nil) = []
          (vconcat filters)))
       (lambda (result)
         (funcall cb (->> result
                          (remove-if-not
                           (lambda (x)
                             (or nofilter (psc-ide-filter-results-p psc-ide-buffer-import-list search qualifier x))))
                          (mapcar
                           (lambda (x)
                             (let ((completion (cdr (assoc 'identifier x)))
                                   (type (cdr (assoc 'type x)))
                                   (module (cdr (assoc 'module x))))
                               (funcall annotate type module qualifier completion)))))))
       t))))


(defun psc-ide-show-type-impl (ident)
  "Returns a string that describes the type of IDENT.
Returns NIL if the type of IDENT is not found."

  (let* ((pprefix (psc-ide-get-ident-context
                   ident
                   psc-ide-buffer-import-list))
         (search (plist-get pprefix 'search))
         (qualifier (plist-get pprefix 'qualifier))
         (moduleFilters (plist-get pprefix 'modules)))
    (psc-ide-send-async (psc-ide-command-show-type
                         (vector (psc-ide-make-module-filter "modules" moduleFilters))
                         search)
                        (lambda (result)
                          (when (not (zerop (length result)))
                            (-if-let (type-description (cdr (assoc 'type (aref result 0))))
                                (message type-description)
                              (message (concat "Know nothing about type of `%s'. "
                                               "Have you loaded the corresponding module?")
                                       ident))))
                        t)))

(defun psc-ide-annotation (s)
  (format " (%s)" (get-text-property 0 :module s)))

(defun psc-ide-suggest-project-dir ()
  (if (fboundp 'projectile-project-root)
      (projectile-project-root)
      (file-name-directory (buffer-file-name))))

(setq company-tooltip-align-annotations t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Utilities

(add-to-list 'company-backends 'company-psc-ide-backend)

(provide 'psc-ide)

;;; psc-ide.el ends here
