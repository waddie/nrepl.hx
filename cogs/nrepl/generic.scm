;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; generic.scm - Generic nREPL Language Adapter
;;;
;;; Fallback adapter for languages without specific implementations.
;;; Provides minimal formatting without language-specific error parsing
;;; or syntax handling.

(require "cogs/nrepl/adapter-interface.scm")

(provide make-generic-adapter)

;;;; Helper Functions ;;;;

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

;;@doc
;; Format an error string as commented lines
(define (format-error-as-comment err-str)
  (let* ([lines (split-many err-str "\n")]
         [commented-lines (map (lambda (line) (string-append "# " line)) lines)])
    (string-join commented-lines "\n")))

;;;; Adapter Implementation ;;;;

;;@doc
;; Simple error prettification - just take first line
(define (prettify-error-generic err-str)
  (take-first-line err-str))

;;@doc
;; Generic prompt format - simple "=> " prefix
(define (format-prompt-generic namespace code)
  (string-append "=> " code "\n"))

;;@doc
;; Format evaluation result with generic styling
(define (format-result-generic code result)
  (let ([value (hash-get result 'value)]
        [output (hash-get result 'output)]
        [error (hash-get result 'error)]
        [ns (hash-get result 'ns)])

    ;; Build the output string
    (let ([parts '()]
          [prompt "=> "])
      ;; Add the code that was evaluated with generic prompt
      (set! parts (cons (string-append prompt code "\n") parts))

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
                                   (prettify-error-generic error)
                                   "\n"
                                   (format-error-as-comment error)
                                   "\n")
                    parts)))

      ;; Add the result value (skip whitespace-only)
      (when (and value (not (eq? value #f)) (not (whitespace-only? value)))
        (set! parts (cons (string-append value "\n") parts)))

      ;; Add trailing newline to separate responses
      (set! parts (cons "\n" parts))

      ;; Combine all parts in reverse order (since we cons'd them)
      (apply string-append (reverse parts)))))

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a generic language adapter instance
;;
;; This adapter provides minimal formatting suitable for any language
;; that doesn't have a specific adapter implementation.
(define (make-generic-adapter)
  (make-adapter prettify-error-generic
                format-prompt-generic
                format-result-generic
                "Generic nREPL"
                '()
                "#"))
