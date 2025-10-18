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
;;;   :nrepl-set-timeout [seconds]       - Set/view eval timeout (default: 60s)
;;;   :nrepl-set-orientation [vsplit|hsplit] - Set/view buffer split orientation (default: vsplit)
;;;   :nrepl-stats                       - Display connection/session statistics
;;;   :nrepl-eval-prompt                 - Prompt for code and evaluate
;;;   :nrepl-eval-selection              - Evaluate current selection (primary)
;;;   :nrepl-eval-buffer                 - Evaluate entire buffer
;;;   :nrepl-eval-multiple-selections    - Evaluate all selections in sequence
;;;   :nrepl-load-file [filename]        - Load and evaluate a file
;;;
;;; The plugin maintains a *nrepl* buffer where all evaluation results are displayed
;;; in a standard REPL format with prompts, output, and values.

(require-builtin helix/components)
(require-builtin steel/ports)
(require-builtin helix/core/text as text.)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/editor.scm")
(require "helix/misc.scm")

;; Load language-agnostic core client
(require "cogs/nrepl/core.scm")

;; Load adapter interface for accessors
(require "cogs/nrepl/adapter-interface.scm")

;; Load language adapters
(require "cogs/nrepl/clojure.scm")
(require "cogs/nrepl/python.scm")
(require "cogs/nrepl/generic.scm")

;; Load lookup picker component
(require "cogs/nrepl/lookup-picker.scm")

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-set-timeout
         nrepl-set-orientation
         nrepl-toggle-debug
         nrepl-stats
         nrepl-eval-prompt
         nrepl-eval-selection
         nrepl-eval-buffer
         nrepl-eval-multiple-selections
         nrepl-load-file
         nrepl-lookup)

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

;;;; Helper Functions ;;;;

;;@doc
;; Extract and echo the value line from formatted result
;; Formatted results have structure: prompt\nvalue\noutput...
;; This function echoes just the value line for quick feedback
(define (echo-value-from-result formatted)
  (when (string-contains? formatted "\n")
    (let ([lines (split-many formatted "\n")])
      (when (> (length lines) 1)
        (helix.echo (list-ref lines 1))))))

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
    [(or (equal? lang "clojure")) (make-clojure-adapter)]

    ;; Python
    [(or (equal? lang "python")) (make-python-adapter)]

    ;; Fallback to generic adapter
    [else (make-generic-adapter)]))

;;@doc
;; Initialize or get state with appropriate adapter
;; If state exists but adapter doesn't match current language, update it
(define (ensure-state)
  (let ([state (get-state)])
    (if state
        ;; State exists - update adapter if language changed
        (let* ([lang (get-current-language)]
               [current-adapter (nrepl-state-adapter state)]
               [new-adapter (load-language-adapter lang)])
          (if (eq? current-adapter new-adapter)
              state ; Adapter matches, return as-is
              ;; Language changed - update adapter but preserve other fields
              (let ([updated-state (nrepl-state (nrepl-state-conn-id state)
                                                (nrepl-state-session state)
                                                (nrepl-state-address state)
                                                (nrepl-state-namespace state)
                                                (nrepl-state-buffer-id state)
                                                new-adapter
                                                (nrepl-state-timeout-ms state)
                                                (nrepl-state-orientation state)
                                                (nrepl-state-debug state))])
                (set-state! updated-state)
                updated-state)))
        ;; No state - create new
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
        'editor-doc-exists?
        editor-doc-exists?
        'editor-set-focus!
        editor-set-focus!
        'editor-switch!
        editor-switch!
        'editor-set-mode!
        editor-set-mode!
        'helix.new
        helix.new
        'helix.vsplit
        helix.vsplit
        'helix.hsplit
        helix.hsplit
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
;; Connect to nREPL server at host:port (default: localhost:7888)
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
    ;; Show immediate feedback
    (helix.echo (string-append "nREPL: Connecting to " address "..."))
    (nrepl:connect
     state
     address
     ;; On success
     (lambda (new-state)
       (set-state! new-state)
       ;; Ensure buffer exists
       (nrepl:ensure-buffer
        new-state
        ctx
        (lambda (state-with-buffer)
          (set-state! state-with-buffer)
          ;; Log connection to buffer with language name
          (let* ([adapter (nrepl-state-adapter state-with-buffer)]
                 [lang-name (adapter-language-name adapter)]
                 [comment-prefix (adapter-comment-prefix adapter)])
            (set-state!
             (nrepl:append-to-buffer
              state-with-buffer
              (string-append comment-prefix " nREPL (" lang-name "): Connected to " address "\n")
              ctx))
            ;; Status message
            (helix.echo (string-append "nREPL (" lang-name "): Connected to " address))))))
     ;; On error
     (lambda (err-msg) (helix.echo (string-append "nREPL: " err-msg))))))

;;@doc
;; Disconnect from the nREPL server
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
           ;; Log disconnection to buffer with language name
           (let* ([adapter (nrepl-state-adapter state)]
                  [lang-name (adapter-language-name adapter)]
                  [comment-prefix (adapter-comment-prefix adapter)])
             (set-state! (nrepl:append-to-buffer new-state
                                                 (string-append comment-prefix
                                                                " nREPL ("
                                                                lang-name
                                                                "): Disconnected from "
                                                                address
                                                                "\n")
                                                 ctx))
             ;; Notify user
             (helix.echo (string-append "nREPL (" lang-name "): Disconnected from " address))))
         ;; On error
         (lambda (err-msg) (helix.echo (string-append "nREPL: Error disconnecting - " err-msg)))))))

;;@doc
;; Set or view evaluation timeout in seconds
(define (nrepl-set-timeout . args)
  (let ([state (get-state)])
    (if (null? args)
        ;; No argument - show current timeout
        (if state
            (let ([current-timeout-ms (nrepl-state-timeout-ms state)])
              (helix.echo (string-append "nREPL: Current timeout: "
                                         (number->string (/ current-timeout-ms 1000))
                                         " seconds")))
            (helix.echo "nREPL: Default timeout: 60 seconds (not yet connected)"))
        ;; Argument provided - set new timeout
        (let* ([seconds-str (car args)]
               [seconds (if (string? seconds-str)
                            (string->number seconds-str)
                            seconds-str)])
          (if (and seconds (number? seconds) (> seconds 0))
              (let* ([timeout-ms (* seconds 1000)]
                     [new-state (if state
                                    (nrepl:set-timeout state timeout-ms)
                                    ;; No state yet - create minimal state with generic adapter
                                    (nrepl-state #f
                                                 #f
                                                 #f
                                                 "user"
                                                 #f
                                                 (make-generic-adapter)
                                                 timeout-ms
                                                 'vsplit
                                                 #f))])
                (set-state! new-state)
                (helix.echo
                 (string-append "nREPL: Timeout set to " (number->string seconds) " seconds")))
              (helix.echo "nREPL: Invalid timeout. Provide a positive number of seconds"))))))

;;@doc
;; Set or view REPL buffer split orientation
(define (nrepl-set-orientation . args)
  (let ([state (get-state)])
    (if (null? args)
        ;; No argument - show current orientation
        (if state
            (let ([current-orientation (nrepl-state-orientation state)])
              (helix.echo (string-append "nREPL: Current orientation: "
                                         (symbol->string current-orientation))))
            (helix.echo "nREPL: Default orientation: vsplit (not yet connected)"))
        ;; Argument provided - set new orientation
        (let* ([orientation-str (car args)]
               [orientation (cond
                              [(or (string=? orientation-str "vsplit")
                                   (string=? orientation-str "v")
                                   (string=? orientation-str "vertical"))
                               'vsplit]
                              [(or (string=? orientation-str "hsplit")
                                   (string=? orientation-str "h")
                                   (string=? orientation-str "horizontal"))
                               'hsplit]
                              [else #f])])
          (if orientation
              (let ([new-state (if state
                                   (nrepl:set-orientation state orientation)
                                   ;; No state yet - create minimal state with generic adapter
                                   (nrepl-state #f
                                                #f
                                                #f
                                                "user"
                                                #f
                                                (make-generic-adapter)
                                                60000
                                                orientation
                                                #f))])
                (set-state! new-state)
                (helix.echo (string-append "nREPL: Orientation set to "
                                           (symbol->string orientation))))
              (helix.echo "nREPL: Invalid orientation. Use 'vsplit' or 'hsplit'"))))))

;;@doc
;; Display registry statistics for debugging
(define (nrepl-stats)
  (let* ([stats-str (nrepl:stats)]
         [stats (eval (read (open-input-string stats-str)))])
    (helix.echo (string-append "nREPL Stats - "
                               "Total Connections: "
                               (number->string (hash-get stats 'total-connections))
                               ", Total Sessions: "
                               (number->string (hash-get stats 'total-sessions))
                               ", Max Connections: "
                               (number->string (hash-get stats 'max-connections))))))

;;@doc
;; Evaluate code from a prompt
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
                      ;; Show immediate feedback
                      (helix.echo "nREPL: Evaluating...")
                      ;; Evaluate code
                      (nrepl:eval-code
                       state-with-buffer
                       trimmed-code
                       ;; On success
                       (lambda (new-state formatted)
                         (set-state! new-state)
                         (set-state! (nrepl:append-to-buffer new-state formatted ctx))
                         ;; Echo just the value for quick feedback
                         (echo-value-from-result formatted))
                       ;; On error
                       (lambda (err-msg formatted)
                         (set-state! (nrepl:append-to-buffer state-with-buffer formatted ctx))
                         (helix.echo err-msg)))))))))))

;;@doc
;; Evaluate the current selection (primary cursor)
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
                 ;; Show immediate feedback
                 (helix.echo "nREPL: Evaluating...")
                 ;; Evaluate code
                 (nrepl:eval-code
                  state-with-buffer
                  trimmed-code
                  ;; On success
                  (lambda (new-state formatted)
                    (set-state! new-state)
                    (set-state! (nrepl:append-to-buffer new-state formatted ctx))
                    ;; Echo just the value
                    (echo-value-from-result formatted))
                  ;; On error
                  (lambda (err-msg formatted)
                    (set-state! (nrepl:append-to-buffer state-with-buffer formatted ctx))
                    (helix.echo err-msg))))))))))

;;@doc
;; Evaluate the entire buffer
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
                 ;; Show immediate feedback
                 (helix.echo "nREPL: Evaluating...")
                 ;; Evaluate code
                 (nrepl:eval-code
                  state-with-buffer
                  trimmed-code
                  ;; On success
                  (lambda (new-state formatted)
                    (set-state! new-state)
                    (set-state! (nrepl:append-to-buffer new-state formatted ctx))
                    ;; Echo just the value
                    (echo-value-from-result formatted))
                  ;; On error
                  (lambda (err-msg formatted)
                    (set-state! (nrepl:append-to-buffer state-with-buffer formatted ctx))
                    (helix.echo err-msg))))))))))

;;@doc
;; Evaluate all selections in sequence
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
                                (let ([updated-state
                                       (nrepl:append-to-buffer new-state formatted ctx)])
                                  (loop (cdr remaining-ranges) updated-state (+ count 1))))
                              ;; On error
                              (lambda (err-msg formatted)
                                (let ([updated-state
                                       (nrepl:append-to-buffer current-state formatted ctx)])
                                  (loop (cdr remaining-ranges)
                                        updated-state
                                        (+ count 1))))))))))))))))

;;@doc
;; Load and evaluate a file
(define (nrepl-load-file . args)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let ([state (get-state)]
            [ctx (make-helix-context)])
        ;; Get current buffer's path as default
        (let* ([focus (editor-focus)]
               [focus-doc-id (editor->doc-id focus)]
               [current-path (editor-document->path focus-doc-id)]
               [default-path (if current-path current-path "")])
          (if (and (not (null? args)) (car args) (not (string=? (car args) "")))
              ;; Path provided as argument - load directly
              (do-load-file (car args) state ctx)
              ;; No path provided - prompt for it with current buffer as default
              (push-component! (prompt (string-append "Load file (default: " default-path "):")
                                       (lambda (filepath)
                                         (let ([path (if (or (not filepath)
                                                             (string=? (trim filepath) ""))
                                                         default-path
                                                         filepath)])
                                           (if (string=? path "")
                                               (helix.echo "nREPL: No file specified")
                                               (do-load-file path state ctx)))))))))))

;;@doc
;; Internal: Load file helper using Steel's port API
(define (do-load-file filepath state ctx)
  (with-handler
   (lambda (err)
     (helix.echo (string-append "nREPL: Error loading file - " (error-object-message err))))
   ;; Read file contents using Steel's port API
   (let* ([file-port (open-input-file filepath)]
          [file-contents (read-port-to-string file-port)]
          [_ (close-port file-port)]
          [file-name (let ([parts (split-many filepath "/")])
                       (if (null? parts)
                           filepath
                           (list-ref parts (- (length parts) 1))))])
     ;; Ensure buffer exists
     (nrepl:ensure-buffer
      state
      ctx
      (lambda (state-with-buffer)
        (set-state! state-with-buffer)
        ;; Show immediate feedback
        (helix.echo (string-append "nREPL: Loading file " filepath "..."))
        ;; Load file
        (nrepl:load-file state-with-buffer
                         file-contents
                         filepath
                         file-name
                         ;; On success
                         (lambda (new-state formatted)
                           (set-state! new-state)
                           (set-state! (nrepl:append-to-buffer new-state formatted ctx))
                           ;; Echo just the value for quick feedback
                           (echo-value-from-result formatted))
                         ;; On error
                         (lambda (err-msg formatted)
                           (set-state! (nrepl:append-to-buffer state-with-buffer formatted ctx))
                           (helix.echo err-msg))))))))

;;@doc
;; Toggle debug mode for lookup operations
(define (nrepl-toggle-debug)
  (let ([state (get-state)])
    (if state
        (let ([new-state (nrepl:toggle-debug state)])
          (set-state! new-state)
          (helix.echo (string-append "nREPL: Debug mode "
                                     (if (nrepl-state-debug new-state) "enabled" "disabled"))))
        (helix.echo "nREPL: Not initialized yet"))))

;;@doc
;; Look up symbol information with interactive picker
(define (nrepl-lookup)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (let* ([state (get-state)]
             [ctx (make-helix-context)]
             [adapter (nrepl-state-adapter state)]
             [comment-prefix (adapter-comment-prefix adapter)]
             [debug-enabled (nrepl-state-debug state)]
             [session (nrepl-state-session state)]
             ;; Debug callback - only appends to buffer if debug is enabled
             [debug-fn
              (lambda (msg)
                (when debug-enabled
                  (let* ([current-state (get-state)]
                         [debug-line (string-append comment-prefix " DEBUG: " msg "\n")]
                         [updated-state (nrepl:append-to-buffer current-state debug-line ctx)])
                    (set-state! updated-state))))])
        ;; Log that nrepl-lookup was called when debug is enabled
        (when debug-enabled
          (let* ([debug-line (string-append comment-prefix " nrepl-lookup called\n")]
                 [updated-state (nrepl:append-to-buffer state debug-line ctx)])
            (set-state! updated-state)))
        (show-lookup-picker session debug-fn))))
