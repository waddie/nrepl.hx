;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; guile.scm - Guile Scheme Language Adapter
;;;
;;; Language adapter for Guile, targeting the guile-ares-rs nREPL server.
;;; Handles Guile-specific condition/exception prettification and a
;;; Scheme-flavoured prompt.
;;;
;;; Guile is not distinguishable from other Schemes by file extension alone
;;; (Helix maps .scm/.ss/.sld to a single `scheme` language). This adapter is
;;; therefore selected from the server's `describe` capabilities — guile-ares-rs
;;; advertises `ares.guile.*` ops — see `capabilities-guile?` in nrepl.scm.
;;; Jack-in is driven by the Scheme-server picker rather than project
;;; detection, so `jack-in-cmd-guile` returns #f here.

(require "adapter-interface.scm")
(require "adapter-utils.scm")

(provide make-guile-adapter)

;;;; Error Prettification ;;;;

;;@doc
;; Transform Guile condition/exception text into a concise, friendly summary.
;;
;; guile-ares-rs surfaces the condition kind in the `ex` field (e.g.
;; "numerical-overflow") and the full message in stderr (`err`). We match on
;; either, since prettify is called with whichever summary is available.
(define (prettify-error-guile err-str)
  (cond
    [(or (string-contains? err-str "numerical-overflow")
        (string-contains? err-str "Division by zero"))
      "Division by zero / numerical overflow"]

    [(or (string-contains? err-str "unbound-variable")
        (string-contains? err-str "Unbound variable"))
      (take-first-line err-str)]

    [(or (string-contains? err-str "wrong-type-arg")
        (string-contains? err-str "Wrong type"))
      "Wrong type argument"]

    [(or (string-contains? err-str "wrong-number-of-args")
        (string-contains? err-str "Wrong number of arguments"))
      "Wrong number of arguments"]

    [(or (string-contains? err-str "out-of-range")
        (string-contains? err-str "out of range"))
      "Value out of range"]

    [(string-contains? err-str "syntax-error") "Syntax error"]

    [(string-contains? err-str "read-error") "Read error - malformed expression"]

    ;; Fallback: first meaningful line
    [else (take-first-line err-str)]))

;;;; Prompt ;;;;

;;@doc
;; Scheme-flavoured prompt. Mirrors Guile's own `scheme@(module)>` form when a
;; namespace (module) is reported, falling back to the default user module.
(define (format-prompt-guile namespace code)
  (let ([prompt (if (and namespace (not (eq? namespace #f)) (not (string=? namespace "")))
                 (string-append "scheme@(" namespace ")> ")
                 "scheme@(guile-user)> ")])
    (string-append prompt code "\n")))

;;;; Result Formatting ;;;;

;;@doc
;; Format evaluation result with Guile styling
(define (format-result-guile code result)
  (format-result-common code result format-prompt-guile prettify-error-guile ";;"))

;;;; Jack-In Support ;;;;

;;@doc
;; Project-detection jack-in is not used for Guile — there is no universal Guile
;; manifest, so jack-in is driven by the Scheme-server picker instead. Returns
;; #f to signal "not supported via project detection".
(define (jack-in-cmd-guile project-info port)
  #f)

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Guile language adapter instance.
(define (make-guile-adapter)
  (make-adapter prettify-error-guile
    format-prompt-guile
    format-result-guile
    "Guile"
    '(".scm" ".ss" ".sld" ".sls")
    ";;"
    jack-in-cmd-guile))
