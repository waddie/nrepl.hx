;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; nrepl.hx - nREPL integration for Helix
;;;
;;; A Helix plugin providing nREPL connectivity with a dedicated
;;; REPL buffer for interactive development. Works with any nREPL server.
;;;
;;; Usage:
;;;   :nrepl-connect [host:port]         - Connect to nREPL server
;;;   :nrepl-disconnect                  - Close connection
;;;   :nrepl-eval-prompt                 - Prompt for code and evaluate
;;;   :nrepl-eval-selection              - Evaluate current selection (primary)
;;;   :nrepl-eval-buffer                 - Evaluate entire buffer
;;;   :nrepl-eval-multiple-selections    - Evaluate all selections in sequence
;;;
;;; The plugin maintains a *nrepl* buffer where all evaluation results are displayed
;;; in a standard REPL format with prompts, output, and values.

(require-builtin helix/components)
(require-builtin helix/core/text as text.)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")

;; Load language-agnostic core client
(require "cogs/nrepl/core.scm")

;; Load language adapters
(require "cogs/nrepl/clojure.scm")
(require "cogs/nrepl/generic.scm")

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-eval-prompt
         nrepl-eval-selection
         nrepl-eval-buffer
         nrepl-eval-multiple-selections)

;;;; State Management ;;;;

;; Global state - using a box for mutability
(define *nrepl-state* (box #f))

;; State accessors
(define (get-state)
  (unbox *nrepl-state*))

(define (set-state! new-state)
  (set-box! *nrepl-state* new-state))

(define (connected?)
  (let ([state (get-state)]) (and state (nrepl-state-conn-id state))))

;;;; Language Detection & Adapter Loading ;;;;

;;@doc
;; Get the current buffer's language identifier
(define (get-current-language)
  (let* ([focus (editor-focus)]
         [doc-id (editor->doc-id focus)]
         [lang (editor-document->language doc-id)])
    lang))

;;@doc
;; Load appropriate language adapter based on language ID
(define (load-language-adapter lang)
  (cond
    ;; Clojure variants
    [(or (equal? lang "clojure")
         (equal? lang "clj")
         (equal? lang "clojurescript")
         (equal? lang "cljs"))
     (make-clojure-adapter)]

    ;; Fallback to generic adapter
    [else (make-generic-adapter)]))

;;@doc
;; Initialize or get state with appropriate adapter
(define (ensure-state)
  (let ([state (get-state)])
    (if state
        state
        (let* ([lang (get-current-language)]
               [adapter (load-language-adapter lang)]
               [new-state (make-nrepl-state adapter)])
          (set-state! new-state)
          new-state))))

;;;; Helix Context ;;;;

;;@doc
;; Create a hash of Helix API functions for core client
(define (make-helix-context)
  (hash 'editor-focus
        editor-focus
        'editor-mode
        editor-mode
        'editor->doc-id
        editor->doc-id
        'editor-document->language
        editor-document->language
        'editor->text
        editor->text
        'editor-doc-in-view?
        editor-doc-in-view?
        'editor-set-focus!
        editor-set-focus!
        'editor-switch!
        editor-switch!
        'editor-set-mode!
        editor-set-mode!
        'helix.new
        helix.new
        'set-scratch-buffer-name!
        set-scratch-buffer-name!
        'helix.set-language
        helix.set-language
        'helix.static.select_all
        helix.static.select_all
        'helix.static.collapse_selection
        helix.static.collapse_selection
        'helix.static.insert_string
        helix.static.insert_string
        'helix.static.align_view_bottom
        helix.static.align_view_bottom))

;;;; Helix Commands ;;;;

;;@doc
;; Connect to an nREPL server. Accepts an optional address (host:port).
(define (nrepl-connect . args)
  (if (connected?)
      (helix.echo "nREPL: Already connected. Use :nrepl-disconnect first")
      (let ([address (if (null? args)
                         #f
                         (car args))])
        (if (and address (not (string=? address "")))
            ;; Address provided - connect directly
            (do-connect address)
            ;; No address provided - prompt for it with default
            (push-component! (prompt "nREPL address (default: localhost:7888):"
                                     (lambda (addr)
                                       (let ([address (if (or (not addr) (string=? (trim addr) ""))
                                                          "localhost:7888"
                                                          addr)])
                                         (do-connect address)))))))))

;;@doc
;; Internal: Create the nREPL connection and buffer
(define (do-connect address)
  (let ([state (ensure-state)]
        [ctx (make-helix-context)])
    (nrepl:connect
     state
     address
     ;; On success
     (lambda (new-state)
       (set-state! new-state)
       ;; Ensure buffer exists
       (nrepl:ensure-buffer new-state
                            ctx
                            (lambda (state-with-buffer)
                              (set-state! state-with-buffer)
                              ;; Log connection to buffer
                              (nrepl:append-to-buffer state-with-buffer
                                                      (string-append ";; Connected to " address "\n")
                                                      ctx)
                              ;; Status message
                              (helix.echo "nREPL: Connected"))))
     ;; On error
     (lambda (err-msg) (helix.echo (string-append "nREPL: " err-msg))))))

;;@doc
;; Disconnect from the nREPL server.
(define (nrepl-disconnect)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected")
      (let ([state (get-state)]
            [ctx (make-helix-context)]
            [address (nrepl-state-address (get-state))])
        (nrepl:disconnect
         state
         ;; On success
         (lambda (new-state)
           (set-state! new-state)
           ;; Log disconnection to buffer
           (nrepl:append-to-buffer new-state (string-append ";; Disconnected from " address "\n") ctx)
           ;; Notify user
           (helix.echo "nREPL: Disconnected"))
         ;; On error
         (lambda (err-msg) (helix.echo (string-append "nREPL: Error disconnecting - " err-msg)))))))

;;@doc
;; Evaluate code from a prompt.
(define (nrepl-eval-prompt)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (push-component!
       (prompt "eval:"
               (lambda (code)
                 (let ([trimmed-code (trim code)]
                       [state (get-state)]
                       [ctx (make-helix-context)])
                   ;; Ensure buffer exists
                   (nrepl:ensure-buffer
                    state
                    ctx
                    (lambda (state-with-buffer)
                      (set-state! state-with-buffer)
                      ;; Evaluate code
                      (nrepl:eval-code state-with-buffer
                                       trimmed-code
                                       ;; On success
                                       (lambda (new-state formatted)
                                         (set-state! new-state)
                                         (nrepl:append-to-buffer new-state formatted ctx)
                                         ;; Echo just the value for quick feedback
                                         (when (string-contains? formatted "\n")
                                           (let ([lines (split-many formatted "\n")])
                                             (when (> (length lines) 1)
                                               (helix.echo (list-ref lines 1))))))
                                       ;; On error
                                       (lambda (err-msg formatted)
                                         (nrepl:append-to-buffer state-with-buffer formatted ctx)
                                         (helix.echo err-msg)))))))))))

;;@doc
;; Evaluate the current selection (primary cursor).
(define (nrepl-eval-selection)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let* ([code (helix.static.current-highlighted-text!)]
             [trimmed-code (if code
                               (trim code)
                               "")])
        (if (or (not code) (string=? trimmed-code ""))
            (helix.echo "nREPL: No text selected")
            (let ([state (get-state)]
                  [ctx (make-helix-context)])
              ;; Ensure buffer exists
              (nrepl:ensure-buffer
               state
               ctx
               (lambda (state-with-buffer)
                 (set-state! state-with-buffer)
                 ;; Evaluate code
                 (nrepl:eval-code state-with-buffer
                                  trimmed-code
                                  ;; On success
                                  (lambda (new-state formatted)
                                    (set-state! new-state)
                                    (nrepl:append-to-buffer new-state formatted ctx)
                                    ;; Echo just the value
                                    (when (string-contains? formatted "\n")
                                      (let ([lines (split-many formatted "\n")])
                                        (when (> (length lines) 1)
                                          (helix.echo (list-ref lines 1))))))
                                  ;; On error
                                  (lambda (err-msg formatted)
                                    (nrepl:append-to-buffer state-with-buffer formatted ctx)
                                    (helix.echo err-msg))))))))))

;;@doc
;; Evaluate the entire buffer.
(define (nrepl-eval-buffer)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let* ([focus (editor-focus)]
             [focus-doc-id (editor->doc-id focus)]
             [code (text.rope->string (editor->text focus-doc-id))]
             [trimmed-code (if code
                               (trim code)
                               "")])
        (if (or (not code) (string=? trimmed-code ""))
            (helix.echo "nREPL: Buffer is empty")
            (let ([state (get-state)]
                  [ctx (make-helix-context)])
              ;; Ensure buffer exists
              (nrepl:ensure-buffer
               state
               ctx
               (lambda (state-with-buffer)
                 (set-state! state-with-buffer)
                 ;; Evaluate code
                 (nrepl:eval-code state-with-buffer
                                  trimmed-code
                                  ;; On success
                                  (lambda (new-state formatted)
                                    (set-state! new-state)
                                    (nrepl:append-to-buffer new-state formatted ctx)
                                    ;; Echo just the value
                                    (when (string-contains? formatted "\n")
                                      (let ([lines (split-many formatted "\n")])
                                        (when (> (length lines) 1)
                                          (helix.echo (list-ref lines 1))))))
                                  ;; On error
                                  (lambda (err-msg formatted)
                                    (nrepl:append-to-buffer state-with-buffer formatted ctx)
                                    (helix.echo err-msg))))))))))

;;@doc
;; Evaluate all selections in sequence.
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
            (let ([state (get-state)]
                  [ctx (make-helix-context)])
              ;; Ensure buffer exists
              (nrepl:ensure-buffer
               state
               ctx
               (lambda (state-with-buffer)
                 (set-state! state-with-buffer)
                 ;; Evaluate each selection
                 (let loop ([remaining-ranges ranges]
                            [current-state state-with-buffer]
                            [count 0])
                   (if (null? remaining-ranges)
                       ;; Done - echo count
                       (helix.echo
                        (string-append "nREPL: Evaluated " (number->string count) " selection(s)"))
                       ;; Evaluate next range
                       (let* ([range (car remaining-ranges)]
                              [from (helix.static.range->from range)]
                              [to (helix.static.range->to range)]
                              [code (text.rope->string (text.rope->slice rope from to))]
                              [trimmed-code (trim code)])
                         (if (string=? trimmed-code "")
                             ;; Skip empty selection
                             (loop (cdr remaining-ranges) current-state count)
                             ;; Evaluate
                             (nrepl:eval-code
                              current-state
                              trimmed-code
                              ;; On success
                              (lambda (new-state formatted)
                                (nrepl:append-to-buffer new-state formatted ctx)
                                (loop (cdr remaining-ranges) new-state (+ count 1)))
                              ;; On error
                              (lambda (err-msg formatted)
                                (nrepl:append-to-buffer current-state formatted ctx)
                                (loop (cdr remaining-ranges) current-state (+ count 1)))))))))))))))
