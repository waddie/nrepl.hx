;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; adapter-utils.scm - Shared Utilities for Language Adapters
;;;
;;; Common helper functions used across all language adapters.
;;; Provides string processing, error formatting, and result formatting utilities.

(provide take-first-line
         whitespace-only?
         format-error-as-comment
         format-result-common)

;;;; String Processing ;;;;

;;@doc
;; Extract the first meaningful line from an error message
(define (take-first-line err-str)
  (let ([lines (split-many err-str "\n")])
    (if (null? lines)
        err-str
        (trim (car lines)))))

;;@doc
;; Check if a string contains only whitespace
(define (whitespace-only? str)
  (string=? (trim str) ""))

;;;; Error Formatting ;;;;

;;@doc
;; Format an error string as commented lines using the specified comment prefix
;;
;; Parameters:
;;   err-str - The error message to format
;;   comment-prefix - The comment prefix for the language (e.g., ";;", "#", "//")
;;
;; Returns:
;;   String with each line prefixed by comment syntax
(define (format-error-as-comment err-str comment-prefix)
  (let* ([lines (split-many err-str "\n")]
         [commented-lines (map (lambda (line)
                                 (string-append comment-prefix " " line))
                               lines)])
    (string-join commented-lines "\n")))

;;;; Result Formatting ;;;;

;;@doc
;; Common result formatting logic for all adapters
;;
;; This function provides the standard structure for formatting evaluation results.
;; Adapters customize behavior by providing functions for prompt formatting and
;; error prettification.
;;
;; Parameters:
;;   code           - The code that was evaluated
;;   result         - Hash containing 'value, 'output, 'error, 'ns
;;   format-prompt  - Function (namespace code) -> string that formats the prompt line
;;   prettify-error - Function (err-str) -> string that simplifies error messages
;;   comment-prefix - String for commenting out full error details (e.g., ";;", "#")
;;
;; Returns:
;;   Formatted string ready for display in the REPL buffer
;;
;; The format-prompt function should return the complete prompt line with code,
;; including trailing newline. For example:
;;   - Clojure: "user=> (+ 1 2)\n"
;;   - Python:  ">>> print(42)\n"
(define (format-result-common code result format-prompt prettify-error comment-prefix)
  (let ([value (hash-get result 'value)]
        [output (hash-get result 'output)]
        [error (hash-get result 'error)]
        [ns (hash-get result 'ns)])

    ;; Build the output string
    (let ([parts '()])
      ;; Add the code that was evaluated with language-specific prompt
      (set! parts (cons (format-prompt ns code) parts))

      ;; Add any stdout output (skip whitespace-only)
      (when (and output (not (null? output)))
        (for-each (lambda (out)
                    (when (not (whitespace-only? out))
                      (set! parts (cons out parts))))
                  output))

      ;; Add any stderr/error output (skip whitespace-only)
      (when (and error (not (eq? error #f)) (not (whitespace-only? error)))
        (set! parts
              (cons (string-append "✗ "
                                   (prettify-error error)
                                   "\n"
                                   (format-error-as-comment error comment-prefix)
                                   "\n")
                    parts)))

      ;; Add the result value (skip whitespace-only)
      (when (and value (not (eq? value #f)) (not (whitespace-only? value)))
        (set! parts (cons (string-append value "\n") parts)))

      ;; Add trailing newline to separate responses
      (set! parts (cons "\n" parts))

      ;; Combine all parts in reverse order (since we cons'd them)
      (apply string-append (reverse parts)))))
