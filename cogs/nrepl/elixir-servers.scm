;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; elixir-servers.scm - Elixir nREPL Server Registry (no-manifest fallback)
;;;
;;; When jack-in finds no project manifest anywhere in the workspace, an
;;; Elixir buffer can still start the repartee nREPL server
;;; (https://github.com/nrepl/nrepl-beam), either via its standalone escript
;;; or via `mix repartee.server` if a Mix project exists after all. This
;;; registry presents those launch methods in the same picker the Scheme and
;;; Clojure fallbacks use.
;;;
;;; The Mix recipe wraps the existing builder from jack-in-config.scm (the
;;; same code that runs when a mix.exs *is* found), so there is one source of
;;; truth for what a Mix jack-in command looks like. Recipes are always
;;; offered even if not viable on this machine - a missing launcher simply
;;; fails at spawn time and surfaces its output in the *nrepl* buffer.

(require "server-recipe.scm")
(require "jack-in-config.scm")

(provide elixir-servers)

;; Standalone repartee escript: no Mix project needed. Passes --port
;; explicitly (repartee defaults to an ephemeral port) and --no-port-file
;; (nrepl.hx manages its own .nrepl-port).
(define (build-repartee-standalone workspace-root port)
  (string-append "repartee --port " (number->string port) " --no-port-file"))

;;@doc
;; The known Elixir nREPL server launch methods, in picker order.
(define elixir-servers
  (list
    (make-server-recipe
      "Repartee (standalone)"
      "Run the repartee escript with no Mix project. Needs `repartee` on PATH (see github.com/nrepl/nrepl-beam)."
      build-repartee-standalone)
    (make-server-recipe
      "Mix project (mix repartee.server)"
      "Run `mix repartee.server` in the workspace root. Needs a mix.exs with repartee as a dependency."
      (lambda (workspace-root port) (build-elixir-mix-command port workspace-root)))))
