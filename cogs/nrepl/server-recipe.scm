;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; server-recipe.scm - Named nREPL server launch method
;;;
;;; A language-agnostic descriptor for "one way to start an nREPL server". Both
;;; the Scheme registry (scheme-servers.scm) and the Clojure fallback registry
;;; (clojure-servers.scm) are lists of these, and the same picker
;;; (server-picker.scm) renders either. Languages with a project manifest detect
;;; their command instead; recipes are for the no-manifest fallback, where we
;;; offer a fixed menu of known launch methods.

(provide server-recipe
  server-recipe?
  make-server-recipe
  server-recipe-label
  server-recipe-description
  server-recipe-build-cmd
  server-recipe-command)

;; A named launch method for an nREPL server.
;;   label       - short name shown in the picker list
;;   description - one-line explanation shown in the preview pane
;;   build-cmd   - (workspace-root port) -> shell command string
(struct server-recipe (label description build-cmd) #:transparent)

(define (make-server-recipe label description build-cmd)
  (server-recipe label description build-cmd))

;;@doc
;; Resolve a recipe's command for a concrete workspace + port.
(define (server-recipe-command recipe workspace-root port)
  ((server-recipe-build-cmd recipe) workspace-root port))
