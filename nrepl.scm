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

;;; nrepl.hx - Clojure nREPL integration for Helix
;;;
;;; A Helix plugin providing Clojure nREPL connectivity with a dedicated
;;; REPL buffer for interactive development.
;;;
;;; Usage:
;;;   :nrepl-connect [address]    - Connect to nREPL server (default: localhost:7888)
;;;   :nrepl-disconnect           - Close connection
;;;   :nrepl-eval-prompt          - Prompt for code and evaluate
;;;   :nrepl-show-buffer          - Show REPL buffer in split
;;;
;;; The plugin maintains a *nrepl* buffer where all evaluation results are displayed
;;; in a standard REPL format with prompts, output, and values.

(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")

;; Load the steel-nrepl dylib
(#%require-dylib "libsteel_nrepl"
  (only-in connect
           clone-session
           eval
           eval-with-timeout
           close))

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-eval-prompt
         nrepl-show-buffer)

;;;; State Management ;;;;

;; Connection state structure
(struct nrepl-state
  (conn-id      ; Connection ID (or #f if not connected)
   session      ; Session handle (or #f)
   address      ; Server address (e.g. "localhost:7888")
   namespace    ; Current namespace (from last eval)
   buffer-id))  ; DocumentId of the *nrepl* buffer

;; Global state - using a box for mutability
(define *nrepl-state*
  (box (nrepl-state #f #f #f "user" #f)))

;; State accessors
(define (get-state) (unbox *nrepl-state*))
(define (set-state! new-state) (set-box! *nrepl-state* new-state))

(define (connected?)
  (not (eq? #f (nrepl-state-conn-id (get-state)))))


;; State update helpers
(define (update-conn-id! conn-id)
  (let ([state (get-state)])
    (set-state! (nrepl-state conn-id
                             (nrepl-state-session state)
                             (nrepl-state-address state)
                             (nrepl-state-namespace state)
                             (nrepl-state-buffer-id state)))))

(define (update-session! session)
  (let ([state (get-state)])
    (set-state! (nrepl-state (nrepl-state-conn-id state)
                             session
                             (nrepl-state-address state)
                             (nrepl-state-namespace state)
                             (nrepl-state-buffer-id state)))))

(define (update-address! address)
  (let ([state (get-state)])
    (set-state! (nrepl-state (nrepl-state-conn-id state)
                             (nrepl-state-session state)
                             address
                             (nrepl-state-namespace state)
                             (nrepl-state-buffer-id state)))))

(define (update-namespace! ns)
  (let ([state (get-state)])
    (set-state! (nrepl-state (nrepl-state-conn-id state)
                             (nrepl-state-session state)
                             (nrepl-state-address state)
                             ns
                             (nrepl-state-buffer-id state)))))

(define (update-buffer-id! buffer-id)
  (let ([state (get-state)])
    (set-state! (nrepl-state (nrepl-state-conn-id state)
                             (nrepl-state-session state)
                             (nrepl-state-address state)
                             (nrepl-state-namespace state)
                             buffer-id))))

;; TODO: REPL buffer management - requires Helix transaction API
;; For now, results are displayed using helix.echo

;;;; Connection Commands ;;;;

;;@doc
;; Connect to an nREPL server
;;
;; Usage: :nrepl-connect [address]
;;
;; If no address is provided, defaults to localhost:7888.
;; Creates a session and displays the *nrepl* buffer.
(define (nrepl-connect)
  (if (connected?)
      (helix.echo "nREPL: Already connected. Use :nrepl-disconnect first")
      ;; TODO: Prompt user for address - need to investigate prompt API
      (let ([address "localhost:7888"])
        ;; Connect to server
        (let ([conn-id (connect address)])
          (update-conn-id! conn-id)
          (update-address! address)

          ;; Create session
          (let ([session (clone-session conn-id)])
            (update-session! session)

            ;; Status message
            (helix.echo "nREPL: Connected"))))))

;;@doc
;; Disconnect from the nREPL server
;;
;; Usage: :nrepl-disconnect
;;
;; Closes the connection and clears session state.
(define (nrepl-disconnect)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected")
      (let ([conn-id (nrepl-state-conn-id (get-state))])
        ;; Close connection
        (close conn-id)

        ;; Reset state
        (set-state! (nrepl-state #f #f #f "user" (nrepl-state-buffer-id (get-state))))

        ;; Notify user
        (helix.echo "nREPL: Disconnected"))))

;;;; Evaluation Commands ;;;;

;;@doc
;; Evaluate Clojure code from a prompt
;;
;; Usage: :nrepl-eval-prompt
;;
;; Prompts for code to evaluate and displays the result in the *nrepl* buffer.
(define (nrepl-eval-prompt)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      ;; TODO: Prompt user for code - need to investigate prompt API
      (let ([code "(+ 1 2)"])  ; Placeholder
        (let ([session (nrepl-state-session (get-state))])

          ;; Evaluate code (use default 60s timeout)
          (let ([value (eval session code)])

            ;; Display result directly for now
            ;; TODO: Write to REPL buffer once buffer API is working
            (helix.echo value))))))

;;@doc
;; Show the *nrepl* buffer in a split
;;
;; Usage: :nrepl-show-buffer
;;
;; Opens the REPL output buffer in a horizontal split if not already visible.
;; NOTE: Not yet implemented - requires Helix transaction API
(define (nrepl-show-buffer)
  (helix.echo "nREPL buffer not yet implemented"))
