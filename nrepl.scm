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
;;;   :nrepl-describe                        - Display server capabilities (ops/versions)
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
(require "cogs/nrepl/guile.scm")
(require "cogs/nrepl/generic.scm")

;; Load lookup picker component
(require "cogs/nrepl/lookup-picker.scm")

;; Load alias picker component
(require "cogs/nrepl/alias-picker.scm")
(require "cogs/nrepl/alias-selection.scm")

;; Load project file picker component
(require "cogs/nrepl/project-file-picker.scm")

;; Load Scheme server picker (jack-in for Guile and other Schemes)
(require "cogs/nrepl/scheme-servers.scm")
(require "cogs/nrepl/scheme-server-picker.scm")

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
  nrepl-toggle-auto-load
  nrepl-stats
  nrepl-eval-prompt
  nrepl-eval-selection
  nrepl-eval-buffer
  nrepl-eval-multiple-selections
  nrepl-load-file
  nrepl-interrupt
  nrepl-stdin
  nrepl-lookup
  nrepl-describe)

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
        (helix.echo (string-append "=> " (list-ref lines 1)))))))

;;@doc
;; Record the in-flight eval request id in global state so :nrepl-interrupt can
;; target the running evaluation.
(define (eval-on-submit req-id)
  (set-state! (nrepl:set-current-eval-request-id (get-state) req-id)))

;;@doc
;; Handle a server `need-input` request: prompt the user for a line and feed it
;; back via send-input!, which sends stdin and resumes polling.
(define (eval-on-need-input send-input!)
  (push-component! (prompt "nREPL stdin:" (lambda (input) (send-input! (or input ""))))))

;;;; Language Detection & Adapter Loading ;;;;

;;@doc
;; Get the current buffer's language identifier
(define (get-current-language)
  (let* ([focus (editor-focus)]
         [doc-id (editor->doc-id focus)]
         [lang (editor-document->language doc-id)])
    lang))

;;@doc
;; Does the server's `describe` capabilities identify it as guile-ares-rs?
;;
;; guile-ares-rs advertises `ares.guile.*` ops (e.g. ares.guile.evaluation/eval).
;; This is the reliable Guile fingerprint: file extension can't distinguish
;; Guile from other Schemes, but the server names itself. `capabilities` is the
;; parsed describe hash (or #f when unknown).
(define (capabilities-guile? capabilities)
  (and capabilities
    (hash-contains? capabilities 'ops)
    (let ([ops (hash-get capabilities 'ops)])
      (and (list? ops)
        (not (null? (filter (lambda (op)
                             (and (string? op)
                               (string-contains? op "ares.guile.")))
                     ops)))))))

;;@doc
;; Select the language adapter for the current buffer.
;;
;; The server fingerprint takes precedence over the editor language: a server
;; that advertises `ares.guile.*` gets the Guile adapter regardless of how Helix
;; labelled the buffer (it labels every Scheme `scheme`). Falls back to the
;; editor language when no decisive capability is present.
(define (select-adapter lang capabilities)
  (cond
    ;; Server fingerprint wins (covers connect-to-running-server, incl. Docker)
    [(capabilities-guile? capabilities) (make-guile-adapter)]

    ;; Clojure variants
    [(equal? lang "clojure") (make-clojure-adapter)]

    ;; Python
    [(equal? lang "python") (make-python-adapter)]

    ;; Fallback to generic adapter
    [else (make-generic-adapter)]))

;;@doc
;; Load appropriate language adapter based on language ID (no capabilities).
;; Retained for callers that have no connection/capabilities context.
(define (load-language-adapter lang)
  (select-adapter lang #f))

;;@doc
;; Initialize or get state with appropriate adapter
;; If state exists but adapter doesn't match current language, update it
(define (ensure-state)
  (let ([state (get-state)])
    (if state
      ;; State exists - update adapter if language (or server fingerprint) changed
      (let* ([lang (get-current-language)]
             [current-adapter (nrepl-state-adapter state)]
             [new-adapter (select-adapter lang (nrepl-state-server-capabilities state))])
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
                                (nrepl-state-spawned-process state)
                                (nrepl-state-current-eval-request-id state)
                                (nrepl-state-auto-load-on-save state)
                                (nrepl-state-server-capabilities state))])
            (set-state! updated-state)
            updated-state)))
      ;; No state - create new
      (let* ([lang (get-current-language)]
             [adapter (load-language-adapter lang)]
             [new-state (make-nrepl-state adapter)])
        (set-state! new-state)
        new-state))))

;;@doc
;; Apply a server-fingerprint adapter override to `state`.
;;
;; Run right after connect, once `describe` capabilities are known. If the
;; server identifies as guile-ares-rs, switch to the Guile adapter regardless of
;; the editor language (Helix can't tell Guile from other Schemes). Otherwise
;; leave the editor-language adapter chosen pre-connect untouched.
(define (apply-capability-adapter state)
  (if (capabilities-guile? (nrepl-state-server-capabilities state))
    (nrepl-state (nrepl-state-conn-id state)
      (nrepl-state-session state)
      (nrepl-state-address state)
      (nrepl-state-namespace state)
      (nrepl-state-buffer-id state)
      (make-guile-adapter)
      (nrepl-state-timeout-ms state)
      (nrepl-state-orientation state)
      (nrepl-state-debug state)
      (nrepl-state-spawned-process state)
      (nrepl-state-current-eval-request-id state)
      (nrepl-state-auto-load-on-save state)
      (nrepl-state-server-capabilities state))
    state))

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
          (lambda (buffered-state)
            ;; Apply server-fingerprint adapter override (e.g. Guile) now that
            ;; describe capabilities are known.
            (let ([state-with-buffer (apply-capability-adapter buffered-state)])
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
                (helix.echo (string-append "nREPL (" lang-name "): Connected to " address)))))))
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
                               #f
                               #f
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
                              #f
                              #f
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
;; Return a human version string for `impl` from a describe `versions` hash,
;; or #f when absent.
(define (describe-impl-version versions impl)
  (and versions
    (hash-contains? versions impl)
    (let ([info (hash-get versions impl)])
      (if (hash-contains? info "version-string")
        (hash-get info "version-string")
        #f))))

;;@doc
;; Join a list of strings with `sep` between elements.
(define (describe-join strings sep)
  (cond
    [(null? strings) ""]
    [(null? (cdr strings)) (car strings)]
    [else (string-append (car strings) sep (describe-join (cdr strings) sep))]))

;;@doc
;; Format a describe result (ops/versions/aux) as a comment block for the
;; *nrepl* buffer.
(define (describe-format-block comment-prefix ops versions aux)
  (let ([line (lambda (s) (string-append comment-prefix " " s "\n"))])
    (string-append
      (line "nREPL describe")
      (line "  versions:")
      (apply string-append
        (map (lambda (impl)
              (line (string-append "    " impl ": "
                     (let ([v (describe-impl-version versions impl)])
                       (if v v "(unknown)")))))
          (if versions (hash-keys->list versions) '())))
      (line (string-append "  ops (" (number->string (length ops)) "):"))
      (line (string-append "    " (describe-join ops ", ")))
      (if (and aux (not (null? (hash-keys->list aux))))
        (string-append
          (line "  aux:")
          (apply string-append
            (map (lambda (k)
                  (line (string-append "    " k ": " (hash-get aux k))))
              (hash-keys->list aux))))
        ""))))

;;@doc
;; Display the connected nREPL server's capabilities (the `describe` operation).
;; Echoes a one-line summary and writes the full ops/versions/aux block to the
;; *nrepl* buffer.
(define (nrepl-describe)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (let* ([state (get-state)]
           [conn-id (nrepl-state-conn-id state)]
           [ctx (make-helix-context)]
           [adapter (nrepl-state-adapter state)]
           [comment-prefix (adapter-comment-prefix adapter)]
           [caps (with-handler (lambda (err) #f) (nrepl:describe conn-id #f))])
      (if (not caps)
        (helix.echo "nREPL: Server did not respond to describe")
        (let* ([ops (hash-get caps 'ops)]
               [versions (hash-get caps 'versions)]
               [aux (hash-get caps 'aux)]
               [block (describe-format-block comment-prefix ops versions aux)]
               [new-state (nrepl:append-to-buffer state block ctx)]
               [nrepl-ver (describe-impl-version versions "nrepl")])
          (set-state! new-state)
          (helix.echo (string-append "nREPL: "
                       (if nrepl-ver (string-append "nREPL " nrepl-ver) "connected")
                       " — "
                       (number->string (length ops))
                       " ops (see *nrepl* buffer)")))))))

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
                ;; Evaluate code (no file location - interactive prompt)
                (nrepl:eval-code
                  state-with-buffer
                  trimmed-code
                  #f
                  #f
                  #f ; No file, line, or column for interactive prompt
                  eval-on-submit
                  eval-on-need-input
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
        (let* ([state (get-state)]
               [ctx (make-helix-context)]
               ;; Extract file location metadata
               [focus (editor-focus)]
               [doc-id (editor->doc-id focus)]
               [file-path (editor-document->path doc-id)]
               ;; Get cursor position for line/col calculation
               [selection-obj (helix.static.current-selection-object)]
               [ranges (helix.static.selection->ranges selection-obj)]
               [primary-range (car ranges)]
               [cursor-pos (helix.static.range->from primary-range)]
               [rope (editor->text doc-id)]
               [line-col (char-offset->line-col rope cursor-pos)]
               [line-num (car line-col)]
               [col-num (cdr line-col)])
          ;; Ensure buffer exists
          (nrepl:ensure-buffer
            state
            ctx
            (lambda (state-with-buffer)
              (set-state! state-with-buffer)
              ;; Show immediate feedback
              (helix.echo "nREPL: Evaluating...")
              ;; Evaluate code with file location metadata
              (nrepl:eval-code
                state-with-buffer
                trimmed-code
                file-path
                line-num
                col-num
                eval-on-submit
                eval-on-need-input
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
                          "")]
           ;; Extract file path for buffer
           [file-path (editor-document->path focus-doc-id)])
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
              ;; Evaluate code (buffer starts at line 1, col 1)
              (nrepl:eval-code
                state-with-buffer
                trimmed-code
                file-path
                1
                1
                eval-on-submit
                eval-on-need-input
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
           [rope (editor->text focus-doc-id)]
           ;; Extract file path once for all selections
           [file-path (editor-document->path focus-doc-id)])
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
                  (helix.echo (string-append "nREPL: Evaluated "
                               (number->string count)
                               (if (= count 1) " selection" " selections")))
                  ;; Evaluate next range
                  (let* ([range (car remaining-ranges)]
                         [from (helix.static.range->from range)]
                         [to (helix.static.range->to range)]
                         [code (text.rope->string (text.rope->slice rope from to))]
                         [trimmed-code (trim code)]
                         ;; Calculate line/col for this selection
                         [line-col (char-offset->line-col rope from)]
                         [line-num (car line-col)]
                         [col-num (cdr line-col)])
                    (if (string=? trimmed-code "")
                      ;; Skip empty selection
                      (loop (cdr remaining-ranges) current-state count)
                      ;; Evaluate with file location metadata
                      (nrepl:eval-code
                        current-state
                        trimmed-code
                        file-path
                        line-num
                        col-num
                        eval-on-submit
                        eval-on-need-input
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
;; Interrupt the currently running evaluation
(define (nrepl-interrupt)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (nrepl:interrupt
      (get-state)
      (lambda () (helix.echo "nREPL: Nothing to interrupt"))
      (lambda () (helix.echo "nREPL: Interrupt requested"))
      (lambda (msg) (helix.echo (string-append "nREPL: Interrupt failed - " msg))))))

;;@doc
;; Send a line of stdin to the current session (to feed a waiting (read-line))
(define (nrepl-stdin . args)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (if (and (not (null? args)) (car args) (not (string=? (car args) "")))
      ;; Input provided as argument
      (begin
        (nrepl:send-stdin (get-state) (car args))
        (helix.echo "nREPL: Sent stdin"))
      ;; Prompt for input
      (push-component!
        (prompt "nREPL stdin:"
          (lambda (input)
            (nrepl:send-stdin (get-state) (or input ""))
            (helix.echo "nREPL: Sent stdin")))))))

;;@doc
;; Toggle auto-load-on-save: when on, saving a source buffer for the active
;; language re-loads it into the connected nREPL.
(define (nrepl-toggle-auto-load)
  (let ([state (get-state)])
    (if state
      (let ([new-state (nrepl:toggle-auto-load-on-save state)])
        (set-state! new-state)
        (helix.echo (string-append "nREPL: Auto-load-on-save "
                     (if (nrepl-state-auto-load-on-save new-state)
                       "enabled"
                       "disabled"))))
      (helix.echo "nREPL: Not initialized yet"))))

;;@doc
;; Look up symbol information with interactive picker
(define (nrepl-lookup)
  (cond
    [(not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")]
    ;; The picker is populated via `completions`; without it there is nothing to
    ;; show, so fail with a clear message rather than an empty picker.
    [(not (nrepl:server-supports? (get-state) "completions"))
      (helix.echo "nREPL: Server does not support completions; lookup picker unavailable")]
    [else
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
        (show-lookup-picker session debug-fn))]))

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
                                (nrepl:log-error
                                  (string-append
                                    "jack-in: server failed to start within 30s on port "
                                    (number->string port)))
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
                                                              process-info
                                                              (nrepl-state-current-eval-request-id
                                                                new-state-without-process)
                                                              (nrepl-state-auto-load-on-save
                                                                new-state-without-process)
                                                              (nrepl-state-server-capabilities
                                                                new-state-without-process))])
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
                                            (nrepl:log-error
                                              (string-append
                                                "jack-in: connection to "
                                                address
                                                " failed - "
                                                err-msg))
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
                                  (begin
                                    (nrepl:log-debug
                                      (get-state)
                                      (string-append "jack-in: port "
                                        (number->string port)
                                        " not ready, attempt "
                                        (number->string attempts)))
                                    (enqueue-thread-local-callback-with-delay
                                      500
                                      (lambda () (poll-server (+ attempts 1))))))))))
                        ;; Start polling - wait 2 seconds for JVM/Clojure to start
                        (enqueue-thread-local-callback-with-delay 2000
                          (lambda () (poll-server 0)))))))))))))))

;;;; Scheme Jack-In ;;;;

;; Helix language identifiers we treat as "Scheme" for jack-in purposes. Helix
;; maps .scm/.ss/.sld to a single `scheme` language, so we can't tell Guile from
;; other Schemes here — that's exactly why jack-in presents a picker.
(define scheme-language-ids '("scheme"))

;;@doc
;; Is the current buffer a Scheme buffer?
(define (scheme-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang scheme-language-ids) #t)))

;;@doc
;; Spawn an nREPL server with `cmd`, wait for it to listen on `port`, then
;; connect, attaching the spawned process to state. Assumes the *nrepl* buffer
;; exists and state is current.
;;
;; Used by the Scheme jack-in path. (The Clojure path inlines an equivalent
;; flow in `continue-jack-in-with-aliases`; the two are kept separate so the
;; proven Clojure path is untouched.)
(define (jack-in-spawn-and-connect cmd workspace-root port adapter ctx)
  (let* ([comment-prefix (adapter-comment-prefix adapter)]
         [process-info (spawn-nrepl-server cmd workspace-root port)])
    (if (not process-info)
      (begin
        (set-state! (nrepl:append-to-buffer
                     (get-state)
                     (string-append comment-prefix " nREPL: Failed to spawn server process\n")
                     ctx))
        (helix.echo "nREPL: Failed to start server (see *nrepl* buffer)"))
      (begin
        (write-nrepl-port workspace-root port)
        (set-state! (nrepl:append-to-buffer
                     (get-state)
                     (string-append comment-prefix " nREPL: Waiting for server to start...\n")
                     ctx))
        (let ([max-attempts (* 30 2)] ; Poll every 0.5s for 30s
              [connected-flag (box #f)])
          (define (poll-server attempts)
            (if (unbox connected-flag)
              void
              (if (> attempts max-attempts)
                ;; Timeout - kill server and show any captured output
                (let ([output (get-process-output
                               (spawned-process-process-handle process-info))])
                  (kill-server process-info)
                  (delete-nrepl-port workspace-root)
                  (nrepl:log-error
                    (string-append "jack-in: server failed to start within 30s on port "
                      (number->string port)))
                  (set-state!
                    (nrepl:append-to-buffer
                      (get-state)
                      (string-append
                        comment-prefix
                        " nREPL: Server failed to start within 30 seconds\n"
                        (if output
                          (string-append comment-prefix " Server output:\n" output "\n")
                          (string-append comment-prefix " (no output captured)\n")))
                      ctx))
                  (helix.echo "nREPL: Server failed to start (see *nrepl* buffer)"))
                ;; Try connecting
                (if (try-connect-to-port port)
                  (begin
                    (set-box! connected-flag #t)
                    (let* ([address (string-append "localhost:" (number->string port))]
                           [_ (set-state!
                               (nrepl:append-to-buffer
                                 (get-state)
                                 (string-append comment-prefix
                                   " nREPL: Server ready, connecting to "
                                   address
                                   "\n")
                                 ctx))])
                      (nrepl:connect
                        (get-state)
                        address
                        ;; On success - attach spawned process, confirm adapter
                        (lambda (connected-state)
                          (let* ([with-adapter (apply-capability-adapter connected-state)]
                                 [final-state (nrepl-state
                                               (nrepl-state-conn-id with-adapter)
                                               (nrepl-state-session with-adapter)
                                               (nrepl-state-address with-adapter)
                                               (nrepl-state-namespace with-adapter)
                                               (nrepl-state-buffer-id with-adapter)
                                               (nrepl-state-adapter with-adapter)
                                               (nrepl-state-timeout-ms with-adapter)
                                               (nrepl-state-orientation with-adapter)
                                               (nrepl-state-debug with-adapter)
                                               process-info
                                               (nrepl-state-current-eval-request-id with-adapter)
                                               (nrepl-state-auto-load-on-save with-adapter)
                                               (nrepl-state-server-capabilities with-adapter))]
                                 [lang-name (adapter-language-name
                                             (nrepl-state-adapter final-state))])
                            (set-state! final-state)
                            (set-state!
                              (nrepl:append-to-buffer
                                (get-state)
                                (string-append comment-prefix " nREPL (" lang-name
                                  "): Started server and connected to "
                                  address
                                  "\n\n")
                                ctx))
                            (helix.echo
                              (string-append "nREPL (" lang-name "): Connected"))))
                        ;; On error
                        (lambda (err-msg)
                          (kill-server process-info)
                          (delete-nrepl-port workspace-root)
                          (nrepl:log-error
                            (string-append "jack-in: connection to " address " failed - " err-msg))
                          (set-state!
                            (nrepl:append-to-buffer
                              (get-state)
                              (string-append comment-prefix " nREPL: Connection failed - "
                                err-msg
                                "\n")
                              ctx))
                          (helix.echo "nREPL: Connection failed (see *nrepl* buffer)")))))
                  ;; Not ready yet - schedule next poll
                  (begin
                    (nrepl:log-debug
                      (get-state)
                      (string-append "jack-in: port " (number->string port)
                        " not ready, attempt "
                        (number->string attempts)))
                    (enqueue-thread-local-callback-with-delay
                      500
                      (lambda () (poll-server (+ attempts 1)))))))))
          (enqueue-thread-local-callback-with-delay 2000
            (lambda () (poll-server 0))))))))

;;@doc
;; Begin Scheme jack-in: allocate a port and show the server picker. The picker
;; preview shows the exact command; on selection we spawn and connect.
(define (start-scheme-jack-in workspace-root)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-scheme-server-picker
        scheme-servers
        workspace-root
        port
        (lambda (server)
          (continue-scheme-jack-in server workspace-root port))))))

;;@doc
;; Continue Scheme jack-in once a server method is chosen: log, spawn, connect.
;; All current registry entries are guile-ares-rs, so we use the Guile adapter.
(define (continue-scheme-jack-in server workspace-root port)
  (let* ([adapter (make-guile-adapter)]
         [comment-prefix (adapter-comment-prefix adapter)]
         [cmd (scheme-server-command server workspace-root port)]
         [ctx (make-helix-context)]
         [state (ensure-state)])
    (nrepl:ensure-buffer
      state
      ctx
      (lambda (state-with-buffer)
        (set-state! state-with-buffer)
        (set-state!
          (nrepl:append-to-buffer
            (get-state)
            (string-append
              comment-prefix
              " nREPL: Starting "
              (scheme-server-label server)
              " on port "
              (number->string port)
              "\n"
              comment-prefix
              " Workspace root: "
              workspace-root
              "\n"
              comment-prefix
              " Command: "
              cmd
              "\n")
            ctx))
        (jack-in-spawn-and-connect cmd workspace-root port adapter ctx)))))

;;@doc
;; Start nREPL server for current project and connect
(define (nrepl-jack-in)
  (if (connected?)
    (helix.echo "nREPL: Already connected. Disconnect first with :nrepl-disconnect")
    (let* ([workspace-root (helix-find-workspace)])
      (if (not workspace-root)
        (helix.echo "nREPL: No workspace found")
        (let* ([project-files (find-project-files-recursive workspace-root)])
          (cond
            ;; No project files found - offer the Scheme server picker when in a
            ;; Scheme buffer (Scheme has no project manifest to detect), else give
            ;; up. The picker is shown even if no method is viable on this machine.
            [(null? project-files)
              (if (scheme-buffer?)
                (start-scheme-jack-in workspace-root)
                (helix.echo "nREPL: No project files found in workspace"))]

            ;; Single project file - use it directly
            [(= 1 (length project-files)) (continue-jack-in-with-file (car project-files))]

            ;; Multiple project files - show picker
            [else
              (show-project-file-picker workspace-root
                project-files
                continue-jack-in-with-file)]))))))

(define (continue-jack-in-with-file filepath)
  "Continue jack-in process with selected project file.
   Detects project info from file, handles aliases if present, spawns server."
  (let* ([project-info (detect-project-from-file filepath)])
    (if (not project-info)
      (helix.echo "nREPL: Could not detect project type from file")
      ;; Check if project has aliases
      (let ([aliases (project-info-aliases project-info)]
            [workspace-root (project-info-project-root project-info)])
        (if (and aliases (not (null? aliases)))
          ;; Has aliases - show picker
          (let* ([saved-selection (load-alias-selection workspace-root)]
                 ;; Use saved selection if exists, otherwise default to safe aliases
                 [initial-selection
                   (if saved-selection
                     saved-selection
                     (map alias-info-name
                       (filter (lambda (ai) (not (alias-info-has-main-opts? ai))) aliases)))]
                 [callback (lambda (selected-names)
                            ;; Save selection before continuing
                            (save-alias-selection workspace-root selected-names)
                            (continue-jack-in-with-aliases project-info selected-names))])
            (show-alias-picker aliases initial-selection callback))
          ;; No aliases - proceed directly
          (continue-jack-in-with-aliases project-info #f))))))

;;;; Auto-load-on-save ;;;;

;;@doc
;; Does the saved document's language match the connected adapter's language?
;; Used to avoid loading e.g. a Python file into a Clojure REPL.
(define (language-matches-adapter? lang adapter)
  (let ([name (adapter-language-name adapter)])
    (cond
      [(string=? name "Clojure")
        (and (member lang (list "clojure" "clojurescript" "edn")) #t)]
      [(string=? name "Python") (string=? lang "python")]
      ;; Generic / unknown adapters: don't auto-load (no safe language match).
      [else #f])))

;;@doc
;; document-saved hook callback. Re-loads the saved buffer into the connected
;; nREPL when auto-load-on-save is enabled and the buffer is a source file for
;; the active language. Scratch buffers (including *nrepl*) have no path and are
;; skipped automatically.
(define (auto-load-on-save-hook doc-id)
  (let ([state (get-state)])
    (when (and state
           (nrepl-state-conn-id state) ; connected
           (nrepl-state-auto-load-on-save state)) ; flag on
      (let ([path (editor-document->path doc-id)]
            [lang (editor-document->language doc-id)]
            [adapter (nrepl-state-adapter state)])
        (when (and path ; has a file path (skips scratch/*nrepl*)
               lang
               (language-matches-adapter? lang adapter))
          (let* ([ctx (make-helix-context)]
                 [contents (text.rope->string (editor->text doc-id))]
                 [file-name (let ([parts (split-many path "/")])
                             (if (null? parts)
                               path
                               (list-ref parts (- (length parts) 1))))])
            (nrepl:log-debug state (string-append "auto-load-on-save: " path))
            (nrepl:load-file state
              contents
              path
              file-name
              ;; On success
              (lambda (new-state formatted)
                (set-state! new-state)
                (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
              ;; On error
              (lambda (err-msg formatted)
                (set-state!
                  (nrepl:append-to-buffer (get-state) formatted ctx))))))))))

;; Register the document-saved hook once at plugin init. Hooks cannot be
;; unregistered, so the callback branches on connection + the auto-load-on-save
;; flag at call time (default off).
(register-hook 'document-saved auto-load-on-save-hook)
