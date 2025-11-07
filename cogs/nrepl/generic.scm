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
(require "cogs/nrepl/adapter-utils.scm")

(provide make-generic-adapter)

;;;; Adapter Implementation ;;;;

;;@doc
;; Simple error prettification - just take first line
(define (prettify-error-generic err-str)
  (take-first-line err-str))

;;@doc
;; Generic prompt format with namespace support
(define (format-prompt-generic namespace code)
  (let ([prompt (if (and namespace (not (eq? namespace #f)))
                    (string-append namespace "=> ")
                    "=> ")])
    (string-append prompt code "\n")))

;;@doc
;; Format evaluation result with generic styling
(define (format-result-generic code result)
  (format-result-common code result format-prompt-generic prettify-error-generic ";;"))

;;;; Jack-In Support ;;;;

;;@doc
;; Jack-in not supported for generic adapter
;;
;; Returns #f to indicate jack-in is not available
(define (jack-in-cmd-generic project-info port)
  "Generic adapter does not support jack-in"
  #f)

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
                ";;"
                jack-in-cmd-generic))
