;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; scheme-servers.scm - Scheme nREPL Server Registry
;;;
;;; Scheme has no universal project manifest (unlike Clojure's deps.edn), and
;;; Helix can't distinguish Guile from other Schemes by file extension. So
;;; jack-in for Scheme presents an explicit picker of known server launch
;;; methods rather than auto-detecting one.
;;;
;;; Each entry is sourced from a server's own documentation. The commands are
;;; always offered even when not viable on the current machine (e.g. ares isn't
;;; macOS-native): a non-viable command simply fails at spawn time and surfaces
;;; its output in the *nrepl* buffer. This keeps the picker stable and means an
;;; upstream fix starts working immediately, with no client change.
;;;
;;; Entries cover guile-ares-rs (https://git.sr.ht/~abcdw/guile-ares-rs) and
;;; nrepl-steel (https://github.com/waddie/nrepl-steel), each taken from its own
;;; README. The guile-ares-rs `run-nrepl-server` accepts `#:port` and otherwise
;;; writes `.nrepl-port`; nrepl-steel takes a `host:port` argument. Either way we
;;; pass the port jack-in allocated so readiness polling connects to the right
;;; socket. The connected adapter is chosen from the server's `describe`
;;; fingerprint after connect, so a single picker can launch either Scheme.

(require "server-recipe.scm")

(provide scheme-servers)

;;;; Command Builders ;;;;

;; The Guile expression that starts the ares nREPL server on a specific port.
(define (ares-run-expr port)
  (string-append "((@ (ares server) run-nrepl-server) #:port "
    (number->string port)
    ")"))

;; guix shell brings `guile` and `guile-ares-rs` into scope, so `(@ (ares
;; server) ...)` resolves without a local checkout. We use the explicit `-c`
;; form (rather than the `ares-nrepl` wrapper) so we can pass `#:port`.
(define (build-guix-shell workspace-root port)
  (string-append "guix shell guile guile-ares-rs -- "
    "guile -L "
    workspace-root
    " -c \""
    (ares-run-expr port)
    "\""))

;; Plain Guile: assumes guile-ares-rs is already on the system load path (e.g.
;; installed via Guix). `-L <workspace>` adds the user's own project sources.
(define (build-plain-guile workspace-root port)
  (string-append "guile -L " workspace-root
    " -c \""
    (ares-run-expr port)
    "\""))

;; Guile with the Guix reader extension loaded first, for projects that use
;; G-expression syntax (#~, #$, #$@).
(define (build-guile-guix-reader workspace-root port)
  (string-append "guile -L " workspace-root
    " -c \"(begin (use-modules (guix gexp)) "
    (ares-run-expr port)
    ")\""))

;; nrepl-steel: `nrepl-steel <host:port>`. Forge installs the entrypoint to
;; $STEEL_HOME/bin/nrepl-steel (i.e. ~/.steel/bin), which the user adds to PATH,
;; so we invoke it by name. The host:port argument is the port jack-in
;; allocated.
(define (build-steel workspace-root port)
  (string-append "nrepl-steel 127.0.0.1:" (number->string port)))

;;;; Registry ;;;;

;;@doc
;; The known Scheme nREPL server launch methods, in picker order.
(define scheme-servers
  (list
    (make-server-recipe
      "Steel (nrepl-steel)"
      "Run the pure-Scheme nrepl-steel server. Needs `nrepl-steel` on PATH - `forge install` it, then add ~/.steel/bin to PATH (see github.com/waddie/nrepl-steel)."
      build-steel)
    (make-server-recipe
      "Guix shell (guile-ares-rs)"
      "Run inside `guix shell guile guile-ares-rs`. No local ares checkout needed; Guix provides it. Requires Guix."
      build-guix-shell)
    (make-server-recipe
      "Plain Guile (guile-ares-rs)"
      "Run with your local guile, ares on the load path. Requires guile-ares-rs already installed (e.g. via Guix)."
      build-plain-guile)
    (make-server-recipe
      "Guile + Guix reader extension"
      "Like Plain Guile, but loads (guix gexp) first so G-expression syntax (#~, #$) reads. For Guix/gexp projects."
      build-guile-guix-reader)))
