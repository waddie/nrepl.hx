;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;;; nREPL client for Helix
;;;
;;; Main entry point for the steel-nrepl plugin

(#%require-dylib "libsteel_nrepl"
  (only-in nrepl-connect!
           nrepl-close!
           nrepl-eval!
           nrepl-load-file!
           nrepl-interrupt!))

(require "helix/commands.scm")
(require "helix/editor.scm")
(require "helix/misc.scm")

(provide connect-repl
         disconnect-repl
         eval-form
         eval-selection
         eval-buffer
         load-file
         repl-interrupt)

;;; Connection state
(struct ReplConnection (conn-id host port active? output-buffer))

(define *active-connection* (box #f))

;;; Commands

;;@doc
;; Connect to an nREPL server
(define (connect-repl host port)
  (let ([conn-id (nrepl-connect! host port)])
    (set-box! *active-connection*
              (ReplConnection conn-id host port #t (new-scratch-buffer)))
    (set-status! (string-append "Connected to " host ":" (number->string port)))))

;;@doc
;; Disconnect from the active REPL
(define (disconnect-repl)
  (when-let ([conn (unbox *active-connection*)])
    (nrepl-close! (ReplConnection-conn-id conn))
    (set-box! *active-connection* #f)
    (set-status! "Disconnected from REPL")))

;;@doc
;; Evaluate the current form
(define (eval-form)
  (let ([code (current-selection)]  ; TODO: Implement proper form detection
        [conn (require-active-connection)])
    (nrepl-eval! (ReplConnection-conn-id conn)
                 code
                 display-result)))

;;@doc
;; Evaluate the current selection
(define (eval-selection)
  (let ([code (current-selection)]
        [conn (require-active-connection)])
    (nrepl-eval! (ReplConnection-conn-id conn)
                 code
                 display-result)))

;;@doc
;; Evaluate the entire buffer
(define (eval-buffer)
  (let ([code (rope->string (editor->text))]
        [conn (require-active-connection)])
    (nrepl-eval! (ReplConnection-conn-id conn)
                 code
                 display-result)))

;;@doc
;; Load the current file into the REPL
(define (load-file)
  (let ([path (cx->current-file)]
        [conn (require-active-connection)])
    (nrepl-load-file! (ReplConnection-conn-id conn)
                      path
                      (lambda (result)
                        (set-status! (string-append "Loaded " path))))))

;;@doc
;; Interrupt the current evaluation
(define (repl-interrupt)
  (when-let ([conn (unbox *active-connection*)])
    (nrepl-interrupt! (ReplConnection-conn-id conn))
    (set-status! "Interrupted")))

;;; Helper functions

(define (require-active-connection)
  (or (unbox *active-connection*)
      (error "No active REPL connection. Use :connect-repl first")))

(define (display-result result)
  ;; TODO: Implement proper result display
  ;; For now, just show in status line
  (set-status! (string-append "=> " (hash-ref result 'value ""))))

(define (new-scratch-buffer)
  ;; TODO: Create *nrepl-output* buffer
  ;; For now, return placeholder
  #f)
