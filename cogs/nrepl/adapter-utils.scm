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
  format-output-list
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
         [commented-lines (map (lambda (line) (string-append comment-prefix " " line)) lines)])
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
;;   format-prompt  - Function (namespace code eval-number) -> string that formats the prompt line
;;   prettify-error - Function (err-str) -> string that simplifies error messages
;;   comment-prefix - String for commenting out full error details (e.g., ";;", "#")
;;   opts           - Optional: include-prompt? (default #t) and eval-number
;;                    (default #f), the REPL prompt number passed to format-prompt
;;
;; Returns:
;;   Formatted string ready for display in the REPL buffer
;;
;; The format-prompt function should return the complete prompt line with code,
;; including trailing newline. For example:
;;   - Clojure: "user=> (+ 1 2)\n"
;;   - Python:  ">>> print(42)\n"
;; Safely read a key that may be absent from older result hashes.
(define (result-ref result key)
  (if (hash-contains? result key)
    (hash-get result key)
    #f))

;;@doc
;; Concatenate a list of stdout strings into a single string, skipping
;; whitespace-only entries. Shared by format-result-common and the poll loop's
;; need-input branch (which renders partial output before the stdin prompt) so
;; both apply the same whitespace-skipping rule. Returns "" for empty/#f input.
(define (format-output-list output)
  (if (and output (not (null? output)))
    (let loop ([items output] [acc '()])
      (if (null? items)
        (apply string-append (reverse acc))
        (loop (cdr items)
          (if (whitespace-only? (car items))
            acc
            (cons (car items) acc)))))
    ""))

(define (format-result-common code result format-prompt prettify-error comment-prefix . opts)
  (define include-prompt? (if (null? opts) #t (car opts)))
  ;; Optional second opt: the REPL prompt number for this evaluation (or #f).
  (define eval-number (if (or (null? opts) (null? (cdr opts))) #f (cadr opts)))
  (let ([value (hash-get result 'value)]
        [output (hash-get result 'output)]
        [error (hash-get result 'error)]
        ;; Explicit exception (from `ex`/`root-ex`) and interrupted status.
        ;; Failures are now detected from these rather than inferred from stderr.
        [ex (result-ref result 'ex)]
        [interrupted (result-ref result 'interrupted)]
        [ns (hash-get result 'ns)])

    ;; Build the output string
    (let ([parts '()])
      ;; Add the code that was evaluated with language-specific prompt, unless
      ;; the caller already echoed it (e.g. at submit time, so partial output
      ;; from a need-input pause renders after the prompt rather than before).
      (when include-prompt?
        (set! parts (cons (format-prompt ns code eval-number) parts)))

      ;; Add any stdout output (skip whitespace-only)
      (let ([out-str (format-output-list output)])
        (when (not (whitespace-only? out-str))
          (set! parts (cons out-str parts))))

      ;; Interrupted marker (status, not stderr text)
      (when (and interrupted (not (eq? interrupted #f)))
        (set! parts (cons (string-append comment-prefix " ⊘ Interrupted\n") parts)))

      ;; Error block: summarise from the explicit exception (`ex`) when present,
      ;; otherwise fall back to stderr text. The commented detail shows stderr
      ;; when available so stack traces are preserved.
      (let ([summary (cond
                      [(and ex (not (eq? ex #f)) (not (whitespace-only? ex))) ex]
                      [(and error (not (eq? error #f)) (not (whitespace-only? error))) error]
                      [else #f])])
        (when summary
          (set! parts
            (cons (string-append "✗ "
                   (prettify-error summary)
                   "\n"
                   (format-error-as-comment
                     (if (and error (not (eq? error #f)) (not (whitespace-only? error)))
                       error
                       summary)
                     comment-prefix)
                   "\n")
              parts))))

      ;; Add the result value (skip whitespace-only)
      (when (and value (not (eq? value #f)) (not (whitespace-only? value)))
        (set! parts (cons (string-append value "\n") parts)))

      ;; Add trailing newline to separate responses
      (set! parts (cons "\n" parts))

      ;; Combine all parts in reverse order (since we cons'd them)
      (apply string-append (reverse parts)))))
