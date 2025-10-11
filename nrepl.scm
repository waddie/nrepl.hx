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

;;; nrepl.hx - nREPL integration for Helix
;;;
;;; A Helix plugin providing nREPL connectivity with a dedicated
;;; REPL buffer for interactive development. Works with any nREPL server.
;;;
;;; Usage:
;;;   :nrepl-connect [address]           - Connect to nREPL server
;;;   :nrepl-disconnect                  - Close connection
;;;   :nrepl-eval-prompt                 - Prompt for code and evaluate
;;;   :nrepl-eval-selection              - Evaluate current selection (primary)
;;;   :nrepl-eval-buffer                 - Evaluate entire buffer
;;;   :nrepl-eval-multiple-selections    - Evaluate all selections in sequence
;;;   :nrepl-show-buffer                 - Show REPL buffer in split
;;;
;;; The plugin maintains a *nrepl* buffer where all evaluation results are displayed
;;; in a standard REPL format with prompts, output, and values.

(require-builtin helix/components)
(require-builtin helix/core/text as text.)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")

;; Load the steel-nrepl dylib
(#%require-dylib "libsteel_nrepl"
  (prefix-in ffi.
    (only-in connect
             clone-session
             eval
             eval-with-timeout
             close)))

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-eval-prompt
         nrepl-eval-selection
         nrepl-eval-buffer
         nrepl-eval-multiple-selections
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

;;;; Connection Commands ;;;;

;;@doc
;; Connect to an nREPL server
;;
;; Usage: :nrepl-connect [address]
;;
;; Prompts for server address (e.g., "localhost:7888") if not provided and connects.
;; Creates a session and displays the *nrepl* buffer.
(define (nrepl-connect . args)
  (if (connected?)
    (helix.echo "nREPL: Already connected. Use :nrepl-disconnect first")
    (let ([address (if (null? args) #f (car args))])
      (if (and address (not (string=? address "")))
        ;; Address provided - connect directly
        (do-connect address)
        ;; No address provided - prompt for it
        (push-component!
          (prompt "nREPL address:"
            (lambda (addr)
              (do-connect addr))))))))

;;@doc
;; Create the nREPL connection and buffer
(define (do-connect address)
  ;; Connect to server
  (let ([conn-id (ffi.connect address)])
    (update-conn-id! conn-id)
    (update-address! address)

    ;; Create session
    (let ([session (ffi.clone-session conn-id)])
      (update-session! session)

      ;; Create buffer if it doesn't exist
      (when (not (nrepl-state-buffer-id (get-state)))
        (create-repl-buffer!))

      ;; Log connection to buffer
      (append-to-repl-buffer (string-append ";; Connected to " address "\n"))

      ;; Status message
      (helix.echo "nREPL: Connected"))))

;;@doc
;; Disconnect from the nREPL server
;;
;; Usage: :nrepl-disconnect
;;
;; Closes the connection and clears session state.
(define (nrepl-disconnect)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected")
      (let ([conn-id (nrepl-state-conn-id (get-state))]
            [address (nrepl-state-address (get-state))])
        ;; Close connection
        (ffi.close conn-id)

        ;; Log disconnection to buffer
        (append-to-repl-buffer (string-append ";; Disconnected from " address "\n"))

        ;; Reset state
        (set-state! (nrepl-state #f #f #f "user" (nrepl-state-buffer-id (get-state))))

        ;; Notify user
        (helix.echo "nREPL: Disconnected"))))

;;;; Evaluation Commands ;;;;

;;@doc
;; Evaluate code from a prompt
;;
;; Usage: :nrepl-eval-prompt
;;
;; Prompts for code to evaluate and displays the result in the *nrepl* buffer.
(define (nrepl-eval-prompt)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (push-component!
        (prompt "eval:"
          (lambda (code)
            (let ([session (nrepl-state-session (get-state))])

              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate code - result is a string
              (let ([value (ffi.eval session code)])
                ;; Format as REPL interaction and append to buffer
                (let ([output (string-append "=> " code "\n" value "\n")])
                  (append-to-repl-buffer output))
                ;; Also echo the result for quick feedback
                (helix.echo value))))))))

;;@doc
;; Evaluate the current selection (primary cursor)
;;
;; Usage: :nrepl-eval-selection
;;
;; Evaluates the text selected by the primary cursor and displays the result
;; in the *nrepl* buffer.
(define (nrepl-eval-selection)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let ([code (helix.static.current-highlighted-text!)])
        (if (or (not code) (string=? code ""))
            (helix.echo "nREPL: No text selected")
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate code - result is a string
              (let ([value (ffi.eval session code)])
                ;; Format as REPL interaction and append to buffer
                (let ([output (string-append "=> " code "\n" value "\n")])
                  (append-to-repl-buffer output))
                ;; Also echo the result for quick feedback
                (helix.echo value)))))))

;;@doc
;; Evaluate the entire buffer
;;
;; Usage: :nrepl-eval-buffer
;;
;; Evaluates all the text in the current buffer and displays the result
;; in the *nrepl* buffer.
(define (nrepl-eval-buffer)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let* ([focus (editor-focus)]
             [focus-doc-id (editor->doc-id focus)]
             [code (text.rope->string (editor->text focus-doc-id))])
        (if (or (not code) (string=? code ""))
            (helix.echo "nREPL: Buffer is empty")
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate code - result is a string
              (let ([value (ffi.eval session code)])
                ;; Format as REPL interaction and append to buffer
                (let ([output (string-append "=> " code "\n" value "\n")])
                  (append-to-repl-buffer output))
                ;; Also echo the result for quick feedback
                (helix.echo value)))))))

;;@doc
;; Evaluate all selections in sequence
;;
;; Usage: :nrepl-eval-multiple-selections
;;
;; Evaluates each selection in sequence and displays all results
;; in the *nrepl* buffer.
(define (nrepl-eval-multiple-selections)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let* ([selection-obj (helix.static.current-selection-object)]
             [ranges (helix.static.selection->ranges selection-obj)]
             [focus (editor-focus)]
             [focus-doc-id (editor->doc-id focus)]
             [rope (editor->text focus-doc-id)])
        (if (null? ranges)
            (helix.echo "nREPL: No selections")
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate each selection
              (for-each
                (lambda (range)
                  (let* ([from (helix.static.range->from range)]
                         [to (helix.static.range->to range)]
                         [code (text.rope->string (text.rope->slice rope from to))])
                    (when (not (string=? code ""))
                      ;; Evaluate code - result is a string
                      (let ([value (ffi.eval session code)])
                        ;; Format as REPL interaction and append to buffer
                        (let ([output (string-append "=> " code "\n" value "\n")])
                          (append-to-repl-buffer output))))))
                ranges)

              ;; Echo count of evaluations
              (helix.echo (string-append "nREPL: Evaluated "
                                         (number->string (length ranges))
                                         " selection(s)")))))))

;;@doc
;; Show the *nrepl* buffer in a split
;;
;; Usage: :nrepl-show-buffer
;;
;; Opens the REPL output buffer in a horizontal split if not already visible.
;; NOTE: Not yet implemented - requires Helix transaction API
(define (nrepl-show-buffer)
  (helix.echo "nREPL buffer not yet implemented"))

;;@doc
;; Append text to the REPL buffer
;;
;; Always writes to the buffer, whether visible or not. Temporarily switches
;; to the buffer to write, then returns to original view.
(define (append-to-repl-buffer text)
  (let ([state (get-state)]
        [original-focus (editor-focus)]
        [original-mode (editor-mode)])
    (let ([buffer-id (nrepl-state-buffer-id state)])
      (if (not buffer-id)
          (helix.echo "nREPL: No buffer created yet")
          (begin
            ;; Check if buffer is already visible in a view
            (let ([maybe-view-id (editor-doc-in-view? buffer-id)])
              (if maybe-view-id
                  ;; Buffer is visible - switch focus to existing view
                  (editor-set-focus! maybe-view-id)
                  ;; Buffer not visible - temporarily switch to it in current view
                  (editor-switch! buffer-id)))
            ;; Go to end of file by selecting all then collapsing to end
            (helix.static.select_all)
            (helix.static.collapse_selection)
            ;; Insert the text
            (helix.static.insert_string text)
            ;; Return to original buffer and mode
            (editor-set-focus! original-focus)
            (editor-set-mode! original-mode))))))

;;@doc
;; Internal: Create the REPL buffer
;;
;; Creates a scratch buffer named *nrepl* for displaying REPL interactions
(define (create-repl-buffer!)
  ;; Get the language from the current buffer
  (let ([original-focus (editor-focus)]
        [original-doc-id (editor->doc-id (editor-focus))])
    (let ([language (editor-document->language original-doc-id)])
      ;; Create new scratch buffer
      (helix.new)
      ;; Set the buffer name
      (set-scratch-buffer-name! "*nrepl*")
      ;; Set language to match the current buffer, or default to "clojure" if none
      (when language
        (helix.set-language language))
      ;; Store the buffer ID for future use
      (let ([buffer-id (editor->doc-id (editor-focus))])
        (update-buffer-id! buffer-id)
        ;; Add initial content to preserve the buffer
        (helix.static.insert_string ";; nREPL REPL Buffer\n")))))
