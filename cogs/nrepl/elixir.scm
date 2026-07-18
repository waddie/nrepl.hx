;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; elixir.scm - Elixir Language Adapter
;;;
;;; Language adapter for Elixir, targeting the repartee nREPL server
;;; (https://github.com/nrepl/nrepl-beam). Handles repartee's error format, an
;;; IEx-flavoured prompt, and the `#` comment syntax.
;;;
;;; Elixir has its own Helix language id (`elixir`), so it is selected by
;;; editor language in `select-adapter`. The server also names itself in its
;;; `describe` `versions` map (an `elixir` key alongside `dialtone`/`nrepl`);
;;; `capabilities-elixir?` in nrepl.scm uses that fingerprint so connecting to
;;; a running repartee from any buffer still picks this adapter. Jack-in goes
;;; through project detection (mix.exs -> 'elixir-mix), with a server picker
;;; fallback for Elixir buffers in workspaces without a manifest.

(require "adapter-interface.scm")
(require "adapter-utils.scm")
(require "string-utils.scm")
(require "project-detection.scm")
(require "jack-in-config.scm")

(provide make-elixir-adapter)

;;;; Error Prettification ;;;;

;;@doc
;; Transform repartee error text into a concise summary.
;;
;; repartee reports failures with a one-line `ex` (preferred here by
;; `format-result-common`) and the full `Exception.format` text in `err`.
;; `ex` is the exception struct name for raised errors (e.g. "ArithmeticError",
;; "UndefinedFunctionError"), or the kind plus inspected reason for non-error
;; kinds (e.g. "throw::boom", "exit::bye"). Reader and eval-message failures
;; use fixed markers ("syntax-error", "compile-error", "bad-request"). Struct
;; names are already concise, so they pass through; the full detail (message
;; and stack trace) is preserved in the commented block by
;; `format-result-common`.
(define (prettify-error-elixir err-str)
  (let ([line (take-first-line err-str)])
    (cond
      [(string=? line "syntax-error") "Syntax error - malformed expression"]
      [(string=? line "compile-error") "Compile error - module failed to compile"]
      [(string=? line "bad-request") "Bad request - malformed eval message"]

      [(string-prefix? line "throw:")
        (string-append "Uncaught throw: " (drop-prefix line "throw:"))]

      [(string-prefix? line "exit:")
        (string-append "Exit: " (drop-prefix line "exit:"))]

      ;; Exception struct names ("ArithmeticError", "CompileError", ...) and
      ;; anything unrecognised pass through as-is.
      [else line])))

;;;; Prompt ;;;;

;;@doc
;; IEx-flavoured prompt, mirroring `iex(N)>` where N is the per-session
;; evaluation number. Falls back to `repartee>` when no number is available
;; (eval-number is #f). repartee never sends an `ns` field on eval responses,
;; so the `namespace` argument is ignored.
(define (format-prompt-elixir namespace code eval-number)
  (if eval-number
    (string-append "repartee(" (number->string eval-number) ")> " code "\n")
    (string-append "repartee> " code "\n")))

;;;; Result Formatting ;;;;

;;@doc
;; Format evaluation result with Elixir styling (using the `#` comment prefix).
(define (format-result-elixir code result . opts)
  (apply format-result-common code result format-prompt-elixir prettify-error-elixir "#" opts))

;;;; Jack-In Support ;;;;

;;@doc
;; Generate the jack-in command for a detected Mix project ('elixir-mix). The
;; command template lives in jack-in-config.scm (user-overridable via
;; `nrepl-configure-jack-in`); the project root is threaded through so the
;; command can `cd` there before running `mix repartee.server`.
(define (jack-in-cmd-elixir project-info port)
  (get-jack-in-command (project-info-project-type project-info)
    port
    (project-info-aliases project-info)
    (project-info-project-root project-info)))

;;;; Adapter Constructor ;;;;

;;@doc
;; Create an Elixir language adapter instance.
(define (make-elixir-adapter)
  (make-adapter prettify-error-elixir
    format-prompt-elixir
    format-result-elixir
    "Elixir"
    '(".ex" ".exs")
    "#"
    jack-in-cmd-elixir))
