;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; janet.scm - Janet Language Adapter
;;;
;;; Language adapter for Janet, targeting the janet nREPL server
;;; (https://github.com/janet-lang/nrepl-janet). Handles Janet-specific error
;;; prettification, a Janet-flavoured prompt, and the `#` comment syntax.
;;;
;;; Unlike the Scheme adapters, Janet has its own Helix language id (`janet`)
;;; and file extensions (.janet/.jdn), so it is selected by editor language in
;;; `select-adapter`. The server also names itself in its `describe` `versions`
;;; map (a `janet` key alongside `nrepl`); `capabilities-janet?` in nrepl.scm
;;; uses that fingerprint so connecting to a running Janet server from any
;;; buffer still picks this adapter. Jack-in is a single fixed launch command
;;; (`janet -e '(import nrepl)(nrepl/run-server ...)'`) driven by the Janet
;;; jack-in path in nrepl.scm rather than project detection, so
;;; `jack-in-cmd-janet` returns #f here.

(require "adapter-interface.scm")
(require "adapter-utils.scm")

(provide make-janet-adapter)

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
;; Transform Janet error text into a concise summary.
;;
;; Janet reports failures as "error: <message>" followed by a "  in <fn> …"
;; stack trace (e.g. "error: unknown symbol foobar", "error: could not find
;; method :+ for 1 or :r+ for \"a\"", "error: unexpected end of source, (
;; opened at line 1, column 1"). We drop the redundant "error: " framing (the
;; buffer already marks failures with ✗) and keep the descriptive first line,
;; with a few common cases given a friendlier canned summary. The full detail
;; (including the stack trace) is preserved in the commented block by
;; `format-result-common`.
(define (prettify-error-janet err-str)
  (let ([line (drop-prefix (take-first-line err-str) "error: ")])
    (cond
      [(string-contains? line "could not find module") "Module not found"]

      [(string-contains? line "could not find method")
        "Type error - no matching method for arguments"]

      [(or (string-contains? line "unexpected end of source")
          (string-contains? line "parse error")
          (string-contains? line "mismatched"))
        "Syntax error - malformed expression"]

      ;; Keep descriptive messages as-is (e.g. "unknown symbol foo",
      ;; "expected …").
      [else line])))

;;;; Prompt ;;;;

;;@doc
;; Janet-flavoured prompt, mirroring Janet's own `repl:N:>` interactive prompt,
;; where N is the per-session evaluation number. Falls back to `repl:>` when no
;; number is available (eval-number is #f). Janet has no nREPL namespace
;; concept, so the `namespace` argument is ignored.
(define (format-prompt-janet namespace code eval-number)
  (if eval-number
    (string-append "repl:" (number->string eval-number) ":> " code "\n")
    (string-append "repl:> " code "\n")))

;;;; Result Formatting ;;;;

;;@doc
;; Format evaluation result with Janet styling (using the `#` comment prefix).
(define (format-result-janet code result . opts)
  (apply format-result-common code result format-prompt-janet prettify-error-janet "#" opts))

;;;; Jack-In Support ;;;;

;;@doc
;; Project-detection jack-in is not used for Janet — the Janet jack-in path in
;; nrepl.scm uses a single fixed launch command rather than detecting a project
;; manifest. Returns #f to signal "not supported via project detection".
(define (jack-in-cmd-janet project-info port)
  #f)

;;;; Adapter Constructor ;;;;

;;@doc
;; Create a Janet language adapter instance.
(define (make-janet-adapter)
  (make-adapter prettify-error-janet
    format-prompt-janet
    format-result-janet
    "Janet"
    '(".janet" ".jdn")
    "#"
    jack-in-cmd-janet))
