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
;;;   :nrepl-connect [host:port]             - Connect to nREPL server
;;;   :nrepl-jack-in                         - Start nREPL server for project and connect
;;;   :nrepl-disconnect                      - Close connection (prompts to kill jack-in servers)
;;;   :nrepl-set-timeout [seconds]           - Set/view eval timeout (default: 60s)
;;;   :nrepl-set-orientation [vsplit|hsplit] - Set/view buffer split orientation (default: vsplit)
;;;   :nrepl-stats                           - Display connection/session statistics
;;;   :nrepl-eval-prompt                     - Prompt for code and evaluate
;;;   :nrepl-eval-selection                  - Evaluate current selection (primary)
;;;   :nrepl-eval-buffer                     - Evaluate entire buffer
;;;   :nrepl-eval-multiple-selections        - Evaluate all selections in sequence
;;;   :nrepl-load-file [filename]            - Load and evaluate a file
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

;; Load alias picker component
(require "cogs/nrepl/alias-picker.scm")
(require "cogs/nrepl/alias-selection.scm")

;; Load jack-in modules
(require "cogs/nrepl/project-detection.scm")
(require "cogs/nrepl/port-management.scm")
(require "cogs/nrepl/process-manager.scm")
(require "cogs/nrepl/jack-in-config.scm")

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-jack-in
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
                                                (nrepl-state-debug state)
                                                (nrepl-state-spawned-process state))])
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
;; Internal: Perform disconnect and cleanup
(define (do-disconnect)
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
         (set-state!
          (nrepl:append-to-buffer
           new-state
           (string-append comment-prefix " nREPL (" lang-name "): Disconnected from " address "\n")
           ctx))
         ;; Return success message
         (string-append "nREPL (" lang-name "): Disconnected from " address)))
     ;; On error
     (lambda (err-msg) (helix.echo (string-append "nREPL: Error disconnecting - " err-msg))))))

;;@doc
;; Disconnect from the nREPL server
(define (nrepl-disconnect)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected")
      (let* ([state (get-state)]
             [spawned (nrepl-state-spawned-process state)])
        (if spawned
            ;; We spawned this server - ask if we should kill it
            (push-component!
             (prompt "Kill nREPL server? [y/n]:"
                     (lambda (choice)
                       (cond
                         [(string=? choice "y")
                          (kill-server spawned)
                          (delete-nrepl-port (spawned-process-workspace-root spawned))
                          (let ([result (do-disconnect)])
                            (when (string? result)
                              (helix.echo (string-append result " (server killed)"))))]
                         [(string=? choice "n")
                          (let ([result (do-disconnect)])
                            (when (string? result)
                              (helix.echo (string-append result " (server still running)"))))]
                         [else (helix.echo "nREPL: Cancelled")]))))
            ;; Not spawned by us - just disconnect
            (let ([result (do-disconnect)])
              (when (string? result)
                (helix.echo result)))))))

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
                                                 #f
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
                                                #f
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

;;@doc
;; Helper: Continue jack-in with selected aliases
(define (continue-jack-in-with-aliases project-info selected-alias-names)
  "Continue jack-in flow with filtered aliases"
  (let* ([all-aliases (project-info-aliases project-info)]
         ;; Filter to only selected aliases
         [filtered-aliases
          (if (and all-aliases selected-alias-names)
              (filter (lambda (ai) (member (alias-info-name ai) selected-alias-names)) all-aliases)
              all-aliases)]
         ;; Create new project-info with filtered aliases
         [filtered-project-info (make-project-info (project-info-project-type project-info)
                                                   (project-info-project-root project-info)
                                                   (project-info-project-file project-info)
                                                   filtered-aliases
                                                   (project-info-has-nrepl-port? project-info))]
         [workspace-root (project-info-project-root filtered-project-info)]
         [port (find-free-port 7888 7988)])
    (if (not port)
        (helix.echo "nREPL: No free ports in range 7888-7988")
        (let* ([state (ensure-state)]
               ;; Determine adapter based on PROJECT TYPE, not current buffer
               [project-type (project-info-project-type filtered-project-info)]
               [adapter (cond
                          [(or (equal? project-type 'clojure-cli)
                               (equal? project-type 'babashka)
                               (equal? project-type 'leiningen))
                           (make-clojure-adapter)]
                          [else (make-generic-adapter)])]
               [ctx (make-helix-context)]
               [comment-prefix (adapter-comment-prefix adapter)]
               [cmd (adapter-jack-in-cmd adapter filtered-project-info port)])
          (if (not cmd)
              (helix.echo (string-append "nREPL: Jack-in not supported for "
                                         (adapter-language-name adapter)))
              ;; Ensure buffer exists first for logging
              (nrepl:ensure-buffer
               state
               ctx
               (lambda (state-with-buffer)
                 (set-state! state-with-buffer)
                 ;; Log jack-in start with project details
                 (let* ([project-type (project-info-project-type project-info)]
                        [project-file (project-info-project-file project-info)]
                        [aliases (project-info-aliases project-info)]
                        [state-1 (nrepl:append-to-buffer
                                  state-with-buffer
                                  (string-append comment-prefix
                                                 " nREPL: Starting server on port "
                                                 (number->string port)
                                                 "\n"
                                                 comment-prefix
                                                 " Workspace root: "
                                                 workspace-root
                                                 "\n"
                                                 comment-prefix
                                                 " Project type: "
                                                 (symbol->string project-type)
                                                 "\n"
                                                 comment-prefix
                                                 " Project file: "
                                                 project-file
                                                 "\n"
                                                 comment-prefix
                                                 " Aliases: "
                                                 (if aliases
                                                     (let ([alias-names (map alias-info-name
                                                                             aliases)])
                                                       (string-join alias-names ", "))
                                                     "none")
                                                 "\n"
                                                 comment-prefix
                                                 " Command: "
                                                 cmd
                                                 "\n")
                                  ctx)])
                   (set-state! state-1)
                   ;; Spawn server
                   (let* ([process-info (spawn-nrepl-server cmd workspace-root port)])
                     (if (not process-info)
                         ;; Failed to spawn
                         (begin
                           (set-state! (nrepl:append-to-buffer
                                        state-1
                                        (string-append comment-prefix
                                                       " nREPL: Failed to spawn server process\n")
                                        ctx))
                           (helix.echo "nREPL: Failed to start server (see *nrepl* buffer)"))
                         ;; Process spawned successfully
                         (begin
                           ;; Write .nrepl-port
                           (write-nrepl-port workspace-root port)
                           (set-state! (nrepl:append-to-buffer
                                        state-1
                                        (string-append comment-prefix
                                                       " nREPL: Waiting for server to start...\n")
                                        ctx))
                           ;; Poll for readiness (30 second timeout) - non-blocking
                           (let ([max-attempts (* 30 2)] ; Poll every 0.5 seconds
                                 [connected-flag (box #f)]) ; Track if we've connected
                             (define (poll-server attempts)
                               (if (unbox connected-flag)
                                   ;; Already connected, stop polling
                                   void
                                   (if (> attempts max-attempts)
                                       ;; Timeout - kill server and show output
                                       (let* ([output (get-process-output
                                                       (spawned-process-process-handle process-info))]
                                              [output-text
                                               (if output
                                                   (string-append
                                                    comment-prefix
                                                    " Server output:\n"
                                                    (let* ([lines (split-many output "\n")]
                                                           [prefixed
                                                            (map (lambda (line)
                                                                   (string-append comment-prefix
                                                                                  " "
                                                                                  line))
                                                                 lines)])
                                                      (string-join prefixed "\n")))
                                                   (string-append comment-prefix
                                                                  " (no output captured)"))])
                                         (kill-server process-info)
                                         (delete-nrepl-port workspace-root)
                                         (set-state!
                                          (nrepl:append-to-buffer
                                           (get-state)
                                           (string-append
                                            comment-prefix
                                            " nREPL: Server failed to start within 30 seconds\n"
                                            output-text
                                            "\n")
                                           ctx))
                                         (helix.echo
                                          "nREPL: Server failed to start (see *nrepl* buffer)"))
                                       ;; Try connecting
                                       (begin
                                         (let ([connected? (try-connect-to-port port)])
                                           (if connected?
                                               ;; Server ready - connect
                                               (begin
                                                 (set-box! connected-flag
                                                           #t) ; Stop all future polling
                                                 (let* ([address (string-append "localhost:"
                                                                                (number->string
                                                                                 port))]
                                                        [state-2
                                                         (nrepl:append-to-buffer
                                                          (get-state)
                                                          (string-append
                                                           comment-prefix
                                                           " nREPL: Server ready, connecting to "
                                                           address
                                                           "\n")
                                                          ctx)])
                                                   (set-state! state-2)
                                                   (nrepl:connect
                                                    state-2
                                                    address
                                                    ;; On success
                                                    (lambda (new-state-without-process)
                                                      ;; Update state to include spawned-process
                                                      (let ([new-state (nrepl-state
                                                                        (nrepl-state-conn-id
                                                                         new-state-without-process)
                                                                        (nrepl-state-session
                                                                         new-state-without-process)
                                                                        (nrepl-state-address
                                                                         new-state-without-process)
                                                                        (nrepl-state-namespace
                                                                         new-state-without-process)
                                                                        (nrepl-state-buffer-id
                                                                         new-state-without-process)
                                                                        (nrepl-state-adapter
                                                                         new-state-without-process)
                                                                        (nrepl-state-timeout-ms
                                                                         new-state-without-process)
                                                                        (nrepl-state-orientation
                                                                         new-state-without-process)
                                                                        (nrepl-state-debug
                                                                         new-state-without-process)
                                                                        process-info)])
                                                        (set-state! new-state)
                                                        ;; Log success to buffer
                                                        (let* ([lang-name (adapter-language-name
                                                                           adapter)]
                                                               [final-state
                                                                (nrepl:append-to-buffer
                                                                 new-state
                                                                 (string-append
                                                                  comment-prefix
                                                                  " nREPL ("
                                                                  lang-name
                                                                  "): Started server and connected to "
                                                                  address
                                                                  "\n\n")
                                                                 ctx)])
                                                          (set-state! final-state)
                                                          (helix.echo (string-append
                                                                       "nREPL ("
                                                                       lang-name
                                                                       "): Connected")))))
                                                    ;; On error
                                                    (lambda (err-msg)
                                                      (kill-server process-info)
                                                      (delete-nrepl-port workspace-root)
                                                      (set-state!
                                                       (nrepl:append-to-buffer
                                                        (get-state)
                                                        (string-append comment-prefix
                                                                       " nREPL: Connection failed - "
                                                                       err-msg
                                                                       "\n")
                                                        ctx))
                                                      (helix.echo
                                                       "nREPL: Connection failed (see *nrepl* buffer)")))))) ; close let* and begin
                                           ;; Not ready yet, schedule next poll
                                           (enqueue-thread-local-callback-with-delay
                                            500
                                            (lambda () (poll-server (+ attempts 1)))))))))
                             ;; Start polling - wait 2 seconds for JVM/Clojure to start
                             (enqueue-thread-local-callback-with-delay 2000
                                                                       (lambda () (poll-server 0)))))))))))))))

;;@doc
;; Start nREPL server for current project and connect
(define (nrepl-jack-in)
  (if (connected?)
      (helix.echo "nREPL: Already connected. Disconnect first with :nrepl-disconnect")
      (let* ([detected-workspace (helix-find-workspace)]
             [project-info (detect-project)])
        (if (not project-info)
            (helix.echo
             "nREPL: No nREPL project found (looking for deps.edn, bb.edn, or project.clj)")
            ;; Check if project has aliases
            (let ([aliases (project-info-aliases project-info)]
                  [workspace-root (project-info-project-root project-info)])
              (if (and aliases (not (null? aliases)))
                  ;; Has aliases - show picker
                  (let* ([saved-selection (load-alias-selection workspace-root)]
                         ;; Use saved selection if exists, otherwise default to safe aliases
                         [initial-selection (if saved-selection
                                                saved-selection
                                                (map alias-info-name
                                                     (filter (lambda (ai)
                                                               (not (alias-info-has-main-opts? ai)))
                                                             aliases)))]
                         [callback (lambda (selected-names)
                                     ;; Save selection before continuing
                                     (save-alias-selection workspace-root selected-names)
                                     (continue-jack-in-with-aliases project-info selected-names))])
                    (show-alias-picker aliases initial-selection callback))
                  ;; No aliases - proceed directly
                  (continue-jack-in-with-aliases project-info #f)))))))
