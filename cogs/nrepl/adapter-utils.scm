;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; adapter-utils.scm - Shared Utilities for Language Adapters
;;;
;;; The result/error/output formatting helpers now live in the shared
;;; repl-ui.hx package so they can be reused by other REPL plugins. This module
;;; re-exports them under their original names so the language adapters continue
;;; to require "adapter-utils.scm" unchanged.

(require "repl-ui.hx/format.scm")

(provide take-first-line
  whitespace-only?
  format-output-list
  format-result-common
  transport-error-summary)

;;@doc
;; Concise summary for nREPL transport and timeout errors, or #f when err-str
;; is not one. Shared by the adapters' prettify-error implementations so the
;; connection/timeout wording stays identical across languages.
(define (transport-error-summary err-str)
  (cond
    [(string-contains? err-str "Connection")
      (cond
        [(string-contains? err-str "refused") "Connection refused - Is nREPL server running?"]
        [(string-contains? err-str "timeout") "Connection timeout - Check address and firewall"]
        [(string-contains? err-str "reset") "Connection lost - Server closed the connection"]
        [else (take-first-line err-str)])]
    [(string-contains? err-str "timed out")
      "Evaluation timed out - Expression took too long to execute"]
    [else #f]))
