;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Alias selection persistence for nREPL jack-in
;; Stores user's alias selections per workspace

(require "cogs/nrepl/string-utils.scm")

(provide save-alias-selection
         load-alias-selection)

;;; Configuration

(define SELECTION_FILE_NAME ".helix/nrepl-aliases.edn")

;;; File I/O helpers

(define (get-selection-file-path workspace-root)
  "Get full path to selection file for workspace"
  (string-append workspace-root "/" SELECTION_FILE_NAME))

(define (ensure-helix-dir workspace-root)
  "Ensure .helix directory exists in workspace root.
   Returns #t on success, #f on failure."
  (let ([helix-dir (string-append workspace-root "/.helix")])
    (if (is-dir? helix-dir)
        #t
        ;; Try to create directory using mkdir command directly
        (begin
          (helix.run-shell-command "mkdir" "-p" helix-dir)
          ;; Check if it was created
          (is-dir? helix-dir)))))

;;; String helpers

(define (find-char-index str char)
  "Find index of first occurrence of char in str. Returns index or #f."
  (let loop ([idx 0])
    (if (>= idx (string-length str))
        #f
        (if (equal? (substring str idx (+ idx 1)) (string char))
            idx
            (loop (+ idx 1))))))

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
      (let* ([bracket-start (find-char-index content #\[)]
             [bracket-end (find-char-index content #\])])
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

(define (save-alias-selection workspace-root alias-names)
  "Save alias selection to workspace.
   workspace-root: path to workspace root directory
   alias-names: list of alias name strings
   Returns #t on success, #f on failure."
  (if (not workspace-root)
      #f
      (let ([file-path (get-selection-file-path workspace-root)])
        ;; Ensure .helix directory exists
        (if (not (ensure-helix-dir workspace-root))
            #f
            ;; Write selection file using Steel's file I/O
            (let ([content (format-selection-edn alias-names)])
              (let ([port (open-output-file file-path)])
                (display content port)
                (close-output-port port)
                ;; Check if file was created
                (is-file? file-path)))))))

(define (load-alias-selection workspace-root)
  "Load alias selection from workspace.
   workspace-root: path to workspace root directory
   Returns list of alias name strings, or #f if no saved selection exists."
  (if (not workspace-root)
      #f
      (let ([file-path (get-selection-file-path workspace-root)])
        (if (not (is-file? file-path))
            #f
            ;; Read and parse file
            (let ([content (read-port-to-string (open-input-file file-path))])
              (parse-selection-edn content))))))
