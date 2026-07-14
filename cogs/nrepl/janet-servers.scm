;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; janet-servers.scm - Janet nREPL Server Registry
;;;
;;; Janet has a single known launch method: the janet-nrepl module run via
;;; `janet -e`. Presenting it through the same picker the other languages use
;;; gives Janet jack-in the command preview and the project-picker toggle for
;;; free. A recipe is offered even if not viable on this machine: a missing
;;; launcher simply fails at spawn time and surfaces its output in the *nrepl*
;;; buffer.

(require "server-recipe.scm")

(provide janet-servers)

;; Imports the installed `nrepl` module and runs its server on localhost. The
;; whole command is handed to `sh -c`, so the single-quoted Janet expression
;; survives shell splitting intact.
(define (build-janet-nrepl workspace-root port)
  (string-append
    "janet -e '(import nrepl)(nrepl/run-server \"127.0.0.1\" \""
    (number->string port)
    "\")'"))

;;@doc
;; The known Janet nREPL server launch methods, in picker order.
(define janet-servers
  (list
    (make-server-recipe
      "Janet (janet-nrepl)"
      "Run the janet-nrepl server via `janet -e`. Needs `janet` on PATH with the nrepl module installed."
      build-janet-nrepl)))
