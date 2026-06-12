;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; steel.scm - Steel Scheme Language Adapter
;;;
;;; Language adapter for Steel, targeting the nrepl-steel server
;;; (https://github.com/waddie/nrepl-steel), a pure-Scheme nREPL server that
;;; runs inside a Steel runtime. Handles Steel-specific error prettification and
;;; a Steel-flavoured prompt.
;;;
;;; Steel is not distinguishable from other Schemes by file extension alone
;;; (Helix maps .scm/.ss/.sld to a single `scheme` language). This adapter is
;;; therefore selected from the server's `describe` capabilities — nrepl-steel
;;; advertises a `nrepl-steel` implementation in its `versions` map — see
;;; `capabilities-steel?` in nrepl.scm. Jack-in is driven by the Scheme-server
;;; picker rather than project detection, so `jack-in-cmd-steel` returns #f here.

(require "adapter-interface.scm")
(require "adapter-utils.scm")

(provide make-steel-adapter)

;;;; Error Prettification ;;;;

;; Drop a fixed prefix from the front of a string when present, else return it
;; unchanged.
(define (drop-prefix str prefix)
  (let ([plen (string-length prefix)])
    (if (and (>= (string-length str) plen)
         (string=? (substring str 0 plen) prefix))
      (substring str plen (string-length str))
      str)))

;;@doc
;; Transform Steel error text into a concise summary.
;;
;; The nrepl-steel server reports eval failures in the `ex` field as
;; "Error: <Kind>: <message>" — e.g. "Error: TypeMismatch: + expects a number,
;; found: \"a\"" or "Error: FreeIdentifier: Cannot reference an identifier
;; before its definition: undefined-var". We drop the redundant "Error: "
;; framing (the buffer already marks failures with ✗) and the non-informative
;; "Generic: " kind label, while keeping meaningful kinds (TypeMismatch,
;; FreeIdentifier, ArityMismatch, …) whose messages are already descriptive. A
;; few common cases get a friendlier canned summary.
(define (prettify-error-steel err-str)
  (let ([line (drop-prefix (take-first-line err-str) "Error: ")])
    (cond
      [(string-contains? line "division by zero") "Division by zero"]

      [(string-contains? line "ArityMismatch")
        "Arity mismatch - wrong number of arguments"]

      [(or (string-contains? line "BadSyntax")
          (string-contains? line "Parse"))
        "Syntax error - malformed expression"]

      ;; Keep descriptive kinds as-is; strip only the noise "Generic:" label.
      [else (drop-prefix line "Generic: ")])))

;;;; Prompt ;;;;

;;@doc
;; Steel-flavoured prompt. Mirrors Steel's own interactive `λ >` prompt. Steel
;; has no module/namespace concept, so the `namespace` argument is ignored
;; (nrepl-steel never reports an `ns`).
(define (format-prompt-steel namespace code)
  (string-append "λ > " code "\n"))

;;;; Result Formatting ;;;;

;;@doc
;; Format evaluation result with Steel styling
(define (format-result-steel code result)
  (format-result-common code result format-prompt-steel prettify-error-steel ";;"))

;;;; Jack-In Support ;;;;

;;@doc
;; Project-detection jack-in is not used for Steel — there is no universal Steel
;; manifest, so jack-in is driven by the Scheme-server picker instead. Returns
;; #f to signal "not supported via project detection".
(define (jack-in-cmd-steel project-info port)
  #f)

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Steel language adapter instance.
(define (make-steel-adapter)
  (make-adapter prettify-error-steel
    format-prompt-steel
    format-result-steel
    "Steel"
    '(".scm" ".ss")
    ";;"
    jack-in-cmd-steel))
