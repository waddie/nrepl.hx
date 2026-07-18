;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; erlang.scm - Erlang Language Adapter
;;;
;;; Language adapter for Erlang, targeting the dialtone nREPL server
;;; (https://github.com/nrepl/nrepl-beam). Handles dialtone's Class:Reason
;;; error format, an erl-shell-flavoured prompt, and the `%` comment syntax.
;;;
;;; Erlang has its own Helix language id (`erlang`), so it is selected by
;;; editor language in `select-adapter`. The server also names itself in its
;;; `describe` `versions` map (a `dialtone` key, with `erlang` but no `elixir`
;;; alongside - repartee carries `elixir` too); `capabilities-erlang?` in
;;; nrepl.scm uses that fingerprint so connecting to a running dialtone from
;;; any buffer still picks this adapter. Jack-in is a single fixed launch
;;; command (`dialtone --port N`) driven by the Erlang jack-in path in
;;; nrepl.scm rather than project detection, so `jack-in-cmd-erlang` returns
;;; #f here.

(require "adapter-interface.scm")
(require "adapter-utils.scm")
(require "string-utils.scm")

(provide make-erlang-adapter)

;;;; Error Prettification ;;;;

;;@doc
;; Transform dialtone error text into a concise summary.
;;
;; dialtone reports failures with a one-line `ex` (preferred here by
;; `format-result-common`) rendered as `Class:Reason` (e.g. "error:badarith",
;; "error:{badmatch,2}", "throw:boom", "exit:bye") and the full
;; `erl_error:format_exception` text in `err`. Reader and eval-message
;; failures use fixed markers ("syntax-error", "compile-error",
;; "bad-request"). Common error reasons get a friendlier canned summary; the
;; full detail (including the stack trace) is preserved in the commented
;; block by `format-result-common`.
(define (prettify-error-erlang err-str)
  (let ([line (take-first-line err-str)])
    (cond
      [(string=? line "syntax-error") "Syntax error - malformed expression"]
      [(string=? line "compile-error") "Compile error - module failed to compile"]
      [(string=? line "bad-request") "Bad request - malformed eval message"]

      [(string=? line "error:badarith") "Arithmetic error - bad argument"]
      [(string=? line "error:undef") "Undefined function"]
      [(string=? line "error:function_clause") "Function clause error - no matching clause"]
      [(string=? line "error:badarg") "Bad argument"]

      [(string-prefix? line "error:{badmatch")
        "Match error - no match of right-hand side value"]

      [(string-prefix? line "throw:")
        (string-append "Uncaught throw: " (drop-prefix line "throw:"))]

      [(string-prefix? line "exit:")
        (string-append "Exit: " (drop-prefix line "exit:"))]

      ;; Other Class:Reason pairs pass through as-is (already one line).
      [else line])))

;;;; Prompt ;;;;

;;@doc
;; erl-shell-flavoured prompt, mirroring `N>` where N is the per-session
;; evaluation number. Falls back to a bare `>` when no number is available
;; (eval-number is #f). dialtone never sends an `ns` field on eval responses,
;; so the `namespace` argument is ignored.
(define (format-prompt-erlang namespace code eval-number)
  (if eval-number
    (string-append (number->string eval-number) "> " code "\n")
    (string-append "> " code "\n")))

;;;; Result Formatting ;;;;

;;@doc
;; Format evaluation result with Erlang styling (using the `%` comment prefix).
(define (format-result-erlang code result . opts)
  (apply format-result-common code result format-prompt-erlang prettify-error-erlang "%" opts))

;;;; Jack-In Support ;;;;

;;@doc
;; Project-detection jack-in is not used for Erlang - the Erlang jack-in path
;; in nrepl.scm uses a single fixed launch command rather than detecting a
;; project manifest. Returns #f to signal "not supported via project
;; detection".
(define (jack-in-cmd-erlang project-info port)
  #f)

;;;; Adapter Constructor ;;;;

;;@doc
;; Create an Erlang language adapter instance.
(define (make-erlang-adapter)
  (make-adapter prettify-error-erlang
    format-prompt-erlang
    format-result-erlang
    "Erlang"
    '(".erl" ".hrl")
    "%"
    jack-in-cmd-erlang))
