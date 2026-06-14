;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; clojure-servers.scm - Clojure nREPL Server Registry (no-manifest fallback)
;;;
;;; When jack-in finds no project manifest (deps.edn / bb.edn / project.clj)
;;; anywhere in the workspace, a Clojure buffer can still start a perfectly good
;;; nREPL by injecting nREPL + cider-nrepl via the clojure CLI's -Sdeps, or by
;;; using babashka / Leiningen directly. This registry presents those known
;;; launch methods in the same picker the Scheme fallback uses.
;;;
;;; The command strings are the project-detection defaults reused verbatim: each
;;; recipe wraps the existing builder from jack-in-config.scm (the same code that
;;; runs when a manifest *is* found), so there is one source of truth for what a
;;; Clojure jack-in command looks like. Recipes are always offered even if a tool
;;; (clojure/bb/lein) isn't installed — a missing one simply fails at spawn time
;;; and surfaces its output in the *nrepl* buffer.

(require "server-recipe.scm")
(require "jack-in-config.scm")

(provide clojure-servers)

;;@doc
;; The known Clojure nREPL server launch methods, in picker order.
(define clojure-servers
  (list
    (make-server-recipe
      "Clojure CLI (nREPL + cider-nrepl)"
      "Run `clojure -M` with nREPL + cider-nrepl injected via -Sdeps. Needs the clojure CLI on PATH. No deps.edn required."
      ;; #f aliases -> default-clojure-with-sdeps: the -Sdeps clojure -M ... line.
      (lambda (workspace-root port) (build-clojure-command port #f)))
    (make-server-recipe
      "Babashka"
      "Run `bb nrepl-server`. Needs babashka (bb) on PATH."
      (lambda (workspace-root port) (build-babashka-command port)))
    (make-server-recipe
      "Leiningen"
      "Run `lein trampoline repl :headless`. Needs Leiningen (lein) on PATH."
      (lambda (workspace-root port) (build-leiningen-command port)))))
