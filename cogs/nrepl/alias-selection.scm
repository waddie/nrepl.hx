;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Alias selection persistence for nREPL jack-in
;; Stores user's alias selections per workspace

(require-builtin steel/filesystem)
(require "string-utils.scm")

(provide save-alias-selection
  load-alias-selection
  save-selection-file
  load-selection-file)

;;; File I/O helpers

(define (selection-file-path workspace-root filename)
  "Get full path to a selection file in the workspace's .helix directory"
  (string-append workspace-root "/.helix/" filename))

(define (ensure-helix-dir workspace-root)
  "Ensure .helix directory exists in workspace root.
   Returns #t on success, #f on failure."
  (let ([helix-dir (string-append workspace-root "/.helix")])
    (if (is-dir? helix-dir)
      #t
      ;; Create the directory (recursive, like `mkdir -p`).
      (with-handler (lambda (err) #f) ; Return #f on error
        (create-directory! helix-dir)
        (is-dir? helix-dir)))))

;;; EDN formatting

(define (format-selection-edn alias-names)
  "Format alias names as EDN. Returns string."
  (if (null? alias-names)
    "{:selected-aliases []}\n"
    (let ([quoted-names (map (lambda (name) (string-append "\"" name "\"")) alias-names)])
      (string-append "{:selected-aliases ["
        (apply string-append
          (let loop ([names quoted-names]
                     [result '()])
            (if (null? names)
              (reverse result)
              (loop (cdr names)
                (if (null? result)
                  (cons (car names) result)
                  (cons (car names) (cons " " result)))))))
        "]}\n"))))

(define (parse-selection-edn content)
  "Parse EDN content and extract alias names. Returns list of strings or #f on error."
  ;; Simple parser: look for strings between [ and ]
  ;; Format: {:selected-aliases ["dev" "test"]}
  (if (not (string-contains? content ":selected-aliases"))
    #f
    (let* ([bracket-start (find-char-index content #\[ 0)]
           [bracket-end (find-char-index content #\] 0)])
      (if (and (number? bracket-start) (number? bracket-end) (< bracket-start bracket-end))
        ;; Extract content between brackets
        (let* ([array-content (substring content (+ bracket-start 1) bracket-end)]
               ;; Tokenize on quotes and whitespace to get names
               [names (tokenize array-content " \t\n\r\"")])
          (if (null? names)
            '() ; Empty list is valid (no aliases selected)
            names))
        #f))))

;;; Public API

(define (save-selection-file workspace-root filename names)
  "Persist a list of name strings to .helix/<filename> (same EDN shape as
   the alias selection). Returns #t on success, #f on failure."
  (if (not workspace-root)
    #f
    (if (not (ensure-helix-dir workspace-root))
      #f
      (let ([content (format-selection-edn names)]
            [file-path (selection-file-path workspace-root filename)])
        (let ([port (open-output-file file-path #:exists 'truncate)])
          (display content port)
          (close-output-port port)
          ;; Check if file was created
          (is-file? file-path))))))

(define (load-selection-file workspace-root filename)
  "Load a list of name strings from .helix/<filename>.
   Returns the list, or #f if no saved selection exists."
  (if (not workspace-root)
    #f
    (let ([file-path (selection-file-path workspace-root filename)])
      (if (not (is-file? file-path))
        #f
        (parse-selection-edn
          (read-port-to-string (open-input-file file-path)))))))

(define (save-alias-selection workspace-root alias-names)
  "Save alias selection to workspace. Returns #t on success, #f on failure."
  (save-selection-file workspace-root "nrepl-aliases.edn" alias-names))

(define (load-alias-selection workspace-root)
  "Load alias selection from workspace.
   Returns list of alias name strings, or #f if no saved selection exists."
  (load-selection-file workspace-root "nrepl-aliases.edn"))
