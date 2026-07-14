;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; erlang-servers.scm - Erlang nREPL Server Registry
;;;
;;; Erlang has a single known launch method: the dialtone nREPL server from
;;; nrepl-beam. Presenting it through the same picker the other languages use
;;; gives Erlang jack-in the command preview and the project-picker toggle for
;;; free. A recipe is offered even if not viable on this machine: a missing
;;; launcher simply fails at spawn time and surfaces its output in the *nrepl*
;;; buffer.

(require "server-recipe.scm")

(provide erlang-servers)

;; Passes --port explicitly (dialtone defaults to an ephemeral port) and
;; --no-port-file (nrepl.hx manages its own .nrepl-port).
(define (build-dialtone workspace-root port)
  (string-append "dialtone --port " (number->string port) " --no-port-file"))

;;@doc
;; The known Erlang nREPL server launch methods, in picker order.
(define erlang-servers
  (list
    (make-server-recipe
      "Erlang (dialtone)"
      "Run the dialtone nREPL server. Needs `dialtone` on PATH (see github.com/nrepl/nrepl-beam)."
      build-dialtone)))
