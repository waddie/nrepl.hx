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
;;;   :nrepl-sessions                        - Pick a server session to attach to (Ctrl-k kills)
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

;; Key predicates for custom picker keybindings (the jack-in picker toggle)
(require (only-in "ui-utils.hx/keys.scm" ctrl-char?))

;; Load language-agnostic core client
(require "cogs/nrepl/core.scm")

;; FFI result parsing (data-walked, never eval'd)
(require (only-in "cogs/nrepl/string-utils.scm" parse-ffi-sexp))

;; Load adapter interface for accessors
(require "cogs/nrepl/adapter-interface.scm")

;; Shared REPL machinery from repl-ui.hx: the injected Helix-API context hash
;; and selection/buffer text extraction.
(require "repl-ui.hx/helix-context.scm")
(require "repl-ui.hx/selection.scm")

;; Load language adapters
(require "cogs/nrepl/clojure.scm")
(require "cogs/nrepl/python.scm")
(require "cogs/nrepl/guile.scm")
(require "cogs/nrepl/steel.scm")
(require "cogs/nrepl/janet.scm")
(require "cogs/nrepl/elixir.scm")
(require "cogs/nrepl/erlang.scm")
(require "cogs/nrepl/generic.scm")

;; Load lookup picker component
(require "cogs/nrepl/lookup-picker.scm")

;; Session picker (attach to / kill server sessions)
(require "cogs/nrepl/session-picker.scm")

;; Load alias picker component
(require "cogs/nrepl/alias-picker.scm")
(require "cogs/nrepl/alias-selection.scm")

;; Load project file picker component
(require "cogs/nrepl/project-file-picker.scm")

;; Load server-recipe picker (jack-in fallback when no project manifest exists)
(require "cogs/nrepl/server-recipe.scm")
(require "cogs/nrepl/server-picker.scm")
(require "cogs/nrepl/scheme-servers.scm")
(require "cogs/nrepl/clojure-servers.scm")
(require "cogs/nrepl/elixir-servers.scm")
(require "cogs/nrepl/janet-servers.scm")
(require "cogs/nrepl/erlang-servers.scm")

;; Load jack-in modules
(require "cogs/nrepl/project-detection.scm")
(require "cogs/nrepl/port-management.scm")
(require "cogs/nrepl/process-manager.scm")
(require "cogs/nrepl/jack-in-config.scm")

;; Distance-sort project files and label the winner (:nrepl-copy-jack-in-command)
(require (only-in "cogs/nrepl/file-utils.scm" sort-files-by-distance))
(require (only-in "cogs/nrepl/project-file-types.scm" get-file-type-label))

;; Export typed commands
(provide nrepl-connect
  nrepl-disconnect
  nrepl-jack-in
  nrepl-jack-out
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
  nrepl-describe
  nrepl-sessions
  nrepl-copy-jack-in-command
  nrepl-shadow-select
  nrepl-cljs-node
  nrepl-cljs-browser
  nrepl-cljs-quit)

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
;; Does the server's `describe` capabilities identify it as nrepl-steel?
;;
;; nrepl-steel advertises a `nrepl-steel` implementation in its `versions` map
;; (alongside `steel`). This is the reliable Steel fingerprint: file extension
;; can't distinguish Steel from other Schemes (Helix labels them all `scheme`),
;; and its ops are all generic, but the server names itself in `versions`.
;; `capabilities` is the parsed describe hash (or #f when unknown).
(define (capabilities-steel? capabilities)
  (and capabilities
    (hash-contains? capabilities 'versions)
    (let ([versions (hash-get capabilities 'versions)])
      (and (hash? versions)
        (hash-contains? versions "nrepl-steel")))))

;;@doc
;; Does the server's `describe` capabilities identify it as a Janet server?
;;
;; The janet nREPL server advertises a `janet` implementation in its `versions`
;; map (alongside `nrepl`). Janet is already distinguishable by editor language
;; (.janet/.jdn), but this fingerprint lets `:nrepl-connect` to a running Janet
;; server pick the right adapter from any buffer. `capabilities` is the parsed
;; describe hash (or #f when unknown).
(define (capabilities-janet? capabilities)
  (and capabilities
    (hash-contains? capabilities 'versions)
    (let ([versions (hash-get capabilities 'versions)])
      (and (hash? versions)
        (hash-contains? versions "janet")))))

;;@doc
;; Does the server's `describe` capabilities identify it as repartee (Elixir)?
;;
;; repartee advertises an `elixir` implementation in its `versions` map
;; (alongside `erlang`, `dialtone` and `nrepl`). Elixir is already
;; distinguishable by editor language (.ex/.exs), but this fingerprint lets
;; `:nrepl-connect` to a running repartee pick the right adapter from any
;; buffer. `capabilities` is the parsed describe hash (or #f when unknown).
(define (capabilities-elixir? capabilities)
  (and capabilities
    (hash-contains? capabilities 'versions)
    (let ([versions (hash-get capabilities 'versions)])
      (and (hash? versions)
        (hash-contains? versions "elixir")))))

;;@doc
;; Does the server's `describe` capabilities identify it as dialtone (Erlang)?
;;
;; dialtone's core puts a `dialtone` key in every `versions` map, and its
;; Erlang backend adds `erlang`. repartee (Elixir) is built on the same core,
;; so it advertises `dialtone` and `erlang` too - the absence of `elixir` is
;; what makes this the Erlang server, and it keeps the predicate correct
;; regardless of check order. `capabilities` is the parsed describe hash (or
;; #f when unknown).
(define (capabilities-erlang? capabilities)
  (and capabilities
    (hash-contains? capabilities 'versions)
    (let ([versions (hash-get capabilities 'versions)])
      (and (hash? versions)
        (or (hash-contains? versions "dialtone")
          (hash-contains? versions "erlang"))
        (not (hash-contains? versions "elixir"))))))

;;@doc
;; The adapter implied by a server's `describe` capabilities, or #f when no
;; fingerprint matches. Schemes are indistinguishable by editor language, so the
;; server's self-description is the only way to pick the right Scheme adapter;
;; Janet names itself too, so a running Janet server is recognised from any
;; buffer.
(define (capability-adapter capabilities)
  (cond
    [(capabilities-steel? capabilities) (make-steel-adapter)]
    [(capabilities-guile? capabilities) (make-guile-adapter)]
    [(capabilities-janet? capabilities) (make-janet-adapter)]
    ;; Elixir before Erlang: repartee advertises `erlang` too (the erlang
    ;; predicate excludes `elixir` anyway; the order is belt and braces).
    [(capabilities-elixir? capabilities) (make-elixir-adapter)]
    [(capabilities-erlang? capabilities) (make-erlang-adapter)]
    [else #f]))

;;@doc
;; Select the language adapter for the current buffer.
;;
;; The server fingerprint takes precedence over the editor language: a server
;; that names itself (e.g. `ares.guile.*` ops, or a `nrepl-steel` version) gets
;; the matching adapter regardless of how Helix labelled the buffer (it labels
;; every Scheme `scheme`). Falls back to the editor language when no decisive
;; capability is present.
(define (select-adapter lang capabilities)
  (let ([fingerprint-adapter (capability-adapter capabilities)])
    (cond
      ;; Server fingerprint wins (covers connect-to-running-server, incl. Docker)
      [fingerprint-adapter fingerprint-adapter]

      ;; Clojure variants
      [(equal? lang "clojure") (make-clojure-adapter)]

      ;; Python
      [(equal? lang "python") (make-python-adapter)]

      ;; Janet
      [(equal? lang "janet") (make-janet-adapter)]

      ;; BEAM languages
      [(equal? lang "elixir") (make-elixir-adapter)]
      [(equal? lang "erlang") (make-erlang-adapter)]

      ;; Fallback to generic adapter
      [else (make-generic-adapter)])))

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
          (let ([updated-state (nrepl-state-with state 'adapter new-adapter)])
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
;; server identifies as a known Scheme implementation (guile-ares-rs or
;; nrepl-steel), switch to its adapter regardless of the editor language (Helix
;; can't tell the Schemes apart). Otherwise leave the editor-language adapter
;; chosen pre-connect untouched.
(define (apply-capability-adapter state)
  (let ([fingerprint-adapter
          (capability-adapter (nrepl-state-server-capabilities state))])
    (if fingerprint-adapter
      (nrepl-state-with state 'adapter fingerprint-adapter)
      state)))

;;;; Helix Context ;;;;

;; make-helix-context now lives in repl-ui.hx/helix-context.scm (required above).

;;;; Helix Commands ;;;;

;;@doc
;; Connect to nREPL server at host:port. With no argument, auto-connects via
;; a live .nrepl-port in the workspace, else prompts (default: localhost:7888)
(define (nrepl-connect . args)
  (if (connected?)
    (helix.echo "nREPL: Already connected. Use :nrepl-disconnect first")
    (let ([address (if (null? args) #f (car args))])
      (if (and address (not (string=? address "")))
        (do-connect address)
        ;; No address: prefer a live .nrepl-port in the workspace, else prompt.
        (let* ([workspace-root (helix-find-workspace)]
               [file-port (and workspace-root (read-nrepl-port workspace-root))])
          (if (and file-port (try-connect-to-port file-port))
            (do-connect (string-append "localhost:" (number->string file-port)))
            (push-component! (prompt "nREPL address (default: localhost:7888):"
                              (lambda (addr)
                                (let ([address (if (or (not addr) (string=? (trim addr) ""))
                                                "localhost:7888"
                                                addr)])
                                  (do-connect address)))))))))))

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
                (log-session-banner (nrepl-state-session-wire-id state-with-buffer) #f #t)
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
;; Kill the jack-in-spawned server and disconnect, no prompt. Errors when the
;; server was not started by jack-in (use :nrepl-disconnect for those).
(define (nrepl-jack-out)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected")
    (let* ([state (get-state)]
           [spawned (nrepl-state-spawned-process state)])
      (if (not spawned)
        (helix.echo "nREPL: Server was not started by jack-in; use :nrepl-disconnect")
        (begin
          (kill-server spawned)
          (delete-nrepl-port (spawned-process-workspace-root spawned))
          (let ([result (do-disconnect)])
            (when (string? result)
              (helix.echo (string-append result " (server killed)")))))))))

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
                 [new-state (nrepl:set-timeout
                             ;; No state yet - create minimal state with generic adapter
                             (or state (make-nrepl-state (make-generic-adapter)))
                             timeout-ms)])
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
          (let ([new-state (nrepl:set-orientation
                            ;; No state yet - create minimal state with generic adapter
                            (or state (make-nrepl-state (make-generic-adapter)))
                            orientation)])
            (set-state! new-state)
            (helix.echo (string-append "nREPL: Orientation set to "
                         (symbol->string orientation))))
          (helix.echo "nREPL: Invalid orientation. Use 'vsplit' or 'hsplit'"))))))

;;@doc
;; Display registry statistics for debugging
(define (nrepl-stats)
  (let* ([stats-str (nrepl:stats)]
         [stats (parse-ffi-sexp stats-str)])
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
                       " - "
                       (number->string (length ops))
                       " ops (see *nrepl* buffer)")))))))

;; Log a session change to the *nrepl* buffer, e.g.
;;   ;; nREPL: session 8f2c... (new, was 1a2b...)
(define (log-session-banner new-id prev-id new?)
  (let* ([state (get-state)]
         [ctx (make-helix-context)]
         [comment-prefix (adapter-comment-prefix (nrepl-state-adapter state))]
         [show (lambda (id) (or id "unknown"))]
         [suffix (cond
                  [(and new? prev-id) (string-append " (new, was " (show prev-id) ")")]
                  [new? " (new)"]
                  [else (string-append " (was " (show prev-id) ")")])])
    (set-state!
      (nrepl:append-to-buffer
        state
        (string-append comment-prefix " nREPL: session " (show new-id) suffix "\n\n")
        ctx))))

;;@doc
;; Pick a server session to attach to
(define (nrepl-sessions)
  (cond
    [(not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")]
    [(not (nrepl:server-supports? (get-state) "ls-sessions"))
      (helix.echo "nREPL: Server does not support ls-sessions")]
    [else
      (with-handler
        (lambda (err)
          (helix.echo (string-append "nREPL: ls-sessions failed: "
                       (error-object-message err))))
        (let* ([state (get-state)]
               [sessions (nrepl:ls-sessions state)]
               [current (nrepl-state-session-wire-id state)])
          (show-session-picker
            sessions
            current
            ;; on-attach
            (lambda (wire-id)
              (with-handler
                (lambda (err)
                  (helix.echo (string-append "nREPL: attach failed: "
                               (error-object-message err))))
                (set-state! (nrepl:attach-session (get-state) wire-id))
                (log-session-banner wire-id current #f)
                (helix.echo (string-append "nREPL: attached to session " wire-id))))
            ;; on-new
            (lambda ()
              (with-handler
                (lambda (err)
                  (helix.echo (string-append "nREPL: clone failed: "
                               (error-object-message err))))
                (set-state! (nrepl:clone-and-attach (get-state)))
                (let ([new-id (nrepl-state-session-wire-id (get-state))])
                  (log-session-banner new-id current #t)
                  (helix.echo (string-append "nREPL: attached to new session "
                               (or new-id "unknown"))))))
            ;; on-kill: the picker closes itself; reopen with a fresh list on
            ;; the next event-loop turn so the killed session disappears.
            (lambda (wire-id)
              (with-handler
                (lambda (err)
                  (helix.echo (string-append "nREPL: kill failed: "
                               (error-object-message err))))
                (nrepl:kill-session (get-state) wire-id)
                (helix.echo (string-append "nREPL: killed session " wire-id))
                (enqueue-thread-local-callback-with-delay 10 nrepl-sessions))))))]))

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
                  ;; On output: stream prompt echo + partial output before stdin
                  (lambda (formatted)
                    (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
                  eval-on-need-input
                  ;; On success. Clear the in-flight eval id (the eval is over,
                  ;; :nrepl-interrupt has nothing to target) and append via the
                  ;; live state so updates made since submit aren't clobbered.
                  (lambda (new-state formatted)
                    (set-state! (nrepl:set-current-eval-request-id new-state #f))
                    (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                    ;; Result is in the *nrepl* buffer; just note completion
                    (helix.echo "nREPL: Done"))
                  ;; On error
                  (lambda (err-msg formatted)
                    (set-state! (nrepl:set-current-eval-request-id (get-state) #f))
                    (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                    (helix.echo err-msg)))))))))))

;;@doc
;; Submit `code` to the connected session and append the formatted result to
;; the *nrepl* buffer. Programmatic twin of :nrepl-eval-prompt, used by
;; after-jack-in code and the ClojureScript commands.
(define (eval-in-repl! code)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected")
    (let ([state (get-state)]
          [ctx (make-helix-context)])
      (nrepl:ensure-buffer state ctx
        (lambda (state-with-buffer)
          (set-state! state-with-buffer)
          (nrepl:eval-code state-with-buffer code #f #f #f
            eval-on-submit
            (lambda (formatted)
              (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
            eval-on-need-input
            (lambda (new-state formatted)
              (set-state! (nrepl:set-current-eval-request-id new-state #f))
              (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
            (lambda (err-msg formatted)
              (set-state! (nrepl:set-current-eval-request-id (get-state) #f))
              (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
              (helix.echo err-msg))))))))

;;@doc
;; Evaluate the current selection (primary cursor)
(define (nrepl-eval-selection)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (let ([sel (selection:primary)])
      (if (not sel)
        (helix.echo "nREPL: No text selected")
        (let ([state (get-state)]
              [ctx (make-helix-context)]
              [trimmed-code (hash-get sel 'code)]
              [file-path (hash-get sel 'file-path)]
              [line-num (hash-get sel 'line)]
              [col-num (hash-get sel 'col)])
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
                ;; On output: stream prompt echo + partial output before stdin
                (lambda (formatted)
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
                eval-on-need-input
                ;; On success. Clear the in-flight eval id (the eval is over,
                ;; :nrepl-interrupt has nothing to target) and append via the
                ;; live state so updates made since submit aren't clobbered.
                (lambda (new-state formatted)
                  (set-state! (nrepl:set-current-eval-request-id new-state #f))
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                  ;; Result is in the *nrepl* buffer; just note completion
                  (helix.echo "nREPL: Done"))
                ;; On error
                (lambda (err-msg formatted)
                  (set-state! (nrepl:set-current-eval-request-id (get-state) #f))
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                  (helix.echo err-msg))))))))))

;;@doc
;; Evaluate the entire buffer
(define (nrepl-eval-buffer)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (let ([buf (selection:buffer)])
      (if (not buf)
        (helix.echo "nREPL: Buffer is empty")
        (let ([state (get-state)]
              [ctx (make-helix-context)]
              [trimmed-code (hash-get buf 'code)]
              [file-path (hash-get buf 'file-path)])
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
                ;; On output: stream prompt echo + partial output before stdin
                (lambda (formatted)
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
                eval-on-need-input
                ;; On success. Clear the in-flight eval id (the eval is over,
                ;; :nrepl-interrupt has nothing to target) and append via the
                ;; live state so updates made since submit aren't clobbered.
                (lambda (new-state formatted)
                  (set-state! (nrepl:set-current-eval-request-id new-state #f))
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                  ;; Result is in the *nrepl* buffer; just note completion
                  (helix.echo "nREPL: Done"))
                ;; On error
                (lambda (err-msg formatted)
                  (set-state! (nrepl:set-current-eval-request-id (get-state) #f))
                  (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
                  (helix.echo err-msg))))))))))

;;@doc
;; Evaluate all selections in sequence
(define (nrepl-eval-multiple-selections)
  (if (not (connected?))
    (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
    (let ([selections (selection:ranges)])
      (if (null? selections)
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
              (let loop ([remaining selections]
                         [current-state state-with-buffer]
                         [count 0])
                (if (null? remaining)
                  ;; Done - echo count
                  (helix.echo (string-append "nREPL: Evaluated "
                               (number->string count)
                               (if (= count 1) " selection" " selections")))
                  ;; Evaluate next selection
                  (let* ([item (car remaining)]
                         [trimmed-code (hash-get item 'code)]
                         [file-path (hash-get item 'file-path)]
                         [line-num (hash-get item 'line)]
                         [col-num (hash-get item 'col)])
                    (if (string=? trimmed-code "")
                      ;; Skip empty selection
                      (loop (cdr remaining) current-state count)
                      ;; Evaluate with file location metadata
                      (nrepl:eval-code
                        current-state
                        trimmed-code
                        file-path
                        line-num
                        col-num
                        eval-on-submit
                        ;; On output: stream prompt echo + partial output before stdin
                        (lambda (formatted)
                          (set-state! (nrepl:append-to-buffer (get-state) formatted ctx)))
                        eval-on-need-input
                        ;; On success. Clear the in-flight eval id and persist
                        ;; the appended state before looping, so the global
                        ;; state tracks the loop.
                        (lambda (new-state formatted)
                          (set-state! (nrepl:set-current-eval-request-id new-state #f))
                          (let ([updated-state
                                  (nrepl:append-to-buffer (get-state) formatted ctx)])
                            (set-state! updated-state)
                            (loop (cdr remaining) updated-state (+ count 1))))
                        ;; On error
                        (lambda (err-msg formatted)
                          (set-state! (nrepl:set-current-eval-request-id (get-state) #f))
                          (let ([updated-state
                                  (nrepl:append-to-buffer (get-state) formatted ctx)])
                            (set-state! updated-state)
                            (loop (cdr remaining)
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
              ;; Result is in the *nrepl* buffer; just note completion
              (helix.echo "nREPL: Done"))
            ;; On error
            (lambda (err-msg formatted)
              (set-state! (nrepl:append-to-buffer (get-state) formatted ctx))
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
;; Tear down a failed jack-in attempt: capture whatever the server wrote to its
;; log, report it in the *nrepl* buffer, kill the server, and remove the stale
;; .nrepl-port file. `reason` is a short human-readable cause (used both in the
;; buffer and the error log). Shared by both the Clojure and Scheme jack-in
;; poll loops, for both the fail-fast (server exited) and timeout cases.
(define (jack-in-fail! process-info comment-prefix ctx reason)
  ;; Read the log BEFORE killing - kill-server removes the temp log file.
  (let ([output (get-process-output process-info)]
        [workspace-root (spawned-process-workspace-root process-info)]
        [port (spawned-process-port process-info)])
    (kill-server process-info)
    (delete-nrepl-port workspace-root)
    (nrepl:log-error
      (string-append "jack-in: " reason " on port " (number->string port)))
    (set-state!
      (nrepl:append-to-buffer
        (get-state)
        (string-append
          comment-prefix
          " nREPL: "
          reason
          "\n"
          (if output
            (string-append
              comment-prefix
              " Server output:\n"
              (string-join
                (map (lambda (line) (string-append comment-prefix " " line))
                  (split-many output "\n"))
                "\n")
              "\n")
            (string-append comment-prefix " (no output captured)\n")))
        ctx))
    (helix.echo "nREPL: Server failed to start (see *nrepl* buffer)")))

;;@doc
;; The language adapter for a manifest-detected project type. Keep this cond
;; in sync with PROJECT_FILE_TYPES (detection) in project-file-types.scm;
;; command building for selection-carrying types (shadow builds, lein
;; profiles) lives in resolve-copy-command and the continue-* handlers.
(define (adapter-for-project-type project-type)
  (cond
    [(or (equal? project-type 'clojure-cli)
        (equal? project-type 'babashka)
        (equal? project-type 'leiningen)
        (equal? project-type 'shadow-cljs))
      (make-clojure-adapter)]
    [(equal? project-type 'elixir-mix) (make-elixir-adapter)]
    [(member project-type '(python-poetry python-setuptools python-pipenv python-pip))
      (make-python-adapter)]
    [else (make-generic-adapter)]))

;;@doc
;; A free port for a new jack-in, or #f after echoing the standard message.
(define (claim-jack-in-port)
  (let ([port (find-free-port 7888 7988)])
    (if port
      port
      (begin
        (helix.echo "nREPL: No free ports in range 7888-7988")
        #f))))

;;@doc
;; The standard project-details comment block logged before the Command line.
(define (project-details-block comment-prefix type-label project-file
         selection-label
         selection)
  (string-append
    comment-prefix
    " Project type: "
    type-label
    "\n"
    comment-prefix
    " Project file: "
    project-file
    "\n"
    comment-prefix
    " "
    selection-label
    ": "
    selection
    "\n"))

;;@doc
;; Helper: Continue jack-in with selected aliases. Builds the project-specific
;; command, then hands off to the shared `begin-jack-in` spawn/poll/connect
;; flow. A Clojure server carries no fingerprint, so the adapter chosen here
;; survives `apply-capability-adapter` after connect; repartee does carry one
;; (`elixir` in versions), which harmlessly re-selects the same adapter.
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
         [port (claim-jack-in-port)])
    (when port
      (let* ( ;; Determine adapter based on PROJECT TYPE, not current buffer
             [project-type (project-info-project-type filtered-project-info)]
             [adapter (adapter-for-project-type project-type)]
             [comment-prefix (adapter-comment-prefix adapter)]
             [cmd (adapter-jack-in-cmd adapter filtered-project-info port)])
        (if (not cmd)
          (helix.echo (string-append "nREPL: Jack-in not supported for "
                       (adapter-language-name adapter)))
          (begin-jack-in
            "server"
            cmd
            workspace-root
            port
            adapter
            (project-details-block comment-prefix
              (symbol->string project-type)
              (project-info-project-file filtered-project-info)
              "Aliases"
              (if filtered-aliases
                (string-join (alias-info-list->names filtered-aliases) ", ")
                "none"))))))))

;;@doc
;; Continue Leiningen jack-in with selected profiles: build the profile-aware
;; command and hand off to the shared begin-jack-in flow.
(define (continue-lein-jack-in project-info profile-names)
  (let* ([workspace-root (project-info-project-root project-info)]
         [port (claim-jack-in-port)])
    (when port
      (let* ([adapter (make-clojure-adapter)]
             [comment-prefix (adapter-comment-prefix adapter)]
             [cmd (build-leiningen-command port profile-names)])
        (begin-jack-in "server" cmd workspace-root port adapter
          (project-details-block comment-prefix "leiningen"
            (project-info-project-file project-info)
            "Profiles"
            (if (null? profile-names) "none" (string-join profile-names ", "))))))))

;;@doc
;; Continue shadow-cljs jack-in with the selected builds. The command embeds a
;; cd to the project root (npx shadow-cljs must run where shadow-cljs.edn is);
;; readiness comes from shadow's own .shadow-cljs/nrepl.port file. After
;; connect, promote the session to the first watched build via nrepl-select.
(define (continue-shadow-jack-in project-info selected-builds)
  (let* ([project-root (project-info-project-root project-info)]
         [log-key-port (find-free-port 7888 7988)]
         [port-file (string-append project-root "/.shadow-cljs/nrepl.port")]
         [adapter (make-clojure-adapter)]
         [comment-prefix (adapter-comment-prefix adapter)]
         [cmd (string-append "cd " (shell-single-quote project-root) " && "
               (build-shadow-command selected-builds))])
    (if (not log-key-port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (begin-jack-in-via-port-file "shadow-cljs" cmd project-root log-key-port
        port-file
        adapter
        (if (null? selected-builds)
          #f
          (lambda ()
            (eval-in-repl!
              (string-append "(shadow.cljs.devtools.api/nrepl-select :"
                (car selected-builds)
                ")"))
            (helix.echo
              "nREPL: cljs session selected; open the app to attach a JS runtime")))
        (string-append
          comment-prefix
          " Builds: "
          (if (null? selected-builds) "none (server only)"
            (string-join selected-builds ", "))
          "\n")))))

;;@doc
;; Switch the REPL to another shadow-cljs build: :nrepl-shadow-select <build>
(define (nrepl-shadow-select build)
  (eval-in-repl! (string-append "(shadow.cljs.devtools.api/nrepl-select :" build ")")))

;;@doc
;; Promote the session to a piggieback ClojureScript REPL on Node.js.
;; Requires jack-in with (nrepl-enable-piggieback) in .helix/nrepl-jack-in.scm.
(define (nrepl-cljs-node)
  (eval-in-repl!
    "(do (require 'cljs.repl.node) (cider.piggieback/cljs-repl (cljs.repl.node/repl-env)))"))

;;@doc
;; Promote the session to a piggieback ClojureScript REPL in a browser.
(define (nrepl-cljs-browser)
  (eval-in-repl!
    "(do (require 'cljs.repl.browser) (cider.piggieback/cljs-repl (cljs.repl.browser/repl-env)))"))

;;@doc
;; Quit the ClojureScript REPL, returning the session to Clojure.
(define (nrepl-cljs-quit)
  (eval-in-repl! ":cljs/quit"))

;;;; Scheme Jack-In ;;;;

;; Helix language identifiers we treat as "Scheme" for jack-in purposes. Helix
;; maps .scm/.ss/.sld to a single `scheme` language, so we can't tell Guile from
;; other Schemes here - that's exactly why jack-in presents a picker.
(define scheme-language-ids '("scheme"))

;;@doc
;; Is the current buffer a Scheme buffer?
(define (scheme-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang scheme-language-ids) #t)))

;;@doc
;; Log and echo a failed server spawn. Shared by both spawn paths.
(define (jack-in-spawn-failed! comment-prefix ctx)
  (set-state! (nrepl:append-to-buffer (get-state)
               (string-append comment-prefix " nREPL: Failed to spawn server process\n")
               ctx))
  (helix.echo "nREPL: Failed to start server (see *nrepl* buffer)"))

;;@doc
;; Connect to a ready server and finish jack-in: swap in the capability
;; adapter, attach the spawned process, log, echo, run the configured
;; after-jack-in code, then the optional on-connected hook. Shared by the
;; fixed-port and port-file spawn paths; process-info must carry the real
;; port so kill-server targets the actual listener.
(define (jack-in-connect-and-finish process-info comment-prefix workspace-root port ctx
         on-connected)
  (let ([address (string-append "localhost:" (number->string port))])
    (set-state! (nrepl:append-to-buffer (get-state)
                 (string-append comment-prefix
                   " nREPL: Server ready, connecting to "
                   address
                   "\n")
                 ctx))
    (nrepl:connect (get-state) address
      (lambda (connected-state)
        (let* ([final-state (nrepl-state-with
                             (apply-capability-adapter connected-state)
                             'spawned-process
                             process-info)]
               [lang-name (adapter-language-name (nrepl-state-adapter final-state))])
          (set-state! final-state)
          (set-state! (nrepl:append-to-buffer (get-state)
                       (string-append comment-prefix " nREPL (" lang-name
                         "): Started server and connected to "
                         address
                         "\n\n")
                       ctx))
          (helix.echo (string-append "nREPL (" lang-name "): Connected"))
          (for-each eval-in-repl! (after-jack-in-code))
          (if on-connected (on-connected) void)))
      (lambda (err-msg)
        (kill-server process-info)
        (delete-nrepl-port workspace-root)
        (nrepl:log-error
          (string-append "jack-in: connection to " address " failed - " err-msg))
        (set-state! (nrepl:append-to-buffer (get-state)
                     (string-append comment-prefix " nREPL: Connection failed - "
                       err-msg
                       "\n")
                     ctx))
        (helix.echo "nREPL: Connection failed (see *nrepl* buffer)")))))

;;@doc
;; Spawn an nREPL server with `cmd`, wait for it to listen on `port`, then
;; connect, attaching the spawned process to state. Assumes the *nrepl* buffer
;; exists and state is current.
(define (jack-in-spawn-and-connect cmd workspace-root port adapter ctx)
  (let* ([comment-prefix (adapter-comment-prefix adapter)]
         [process-info (spawn-nrepl-server cmd workspace-root port)])
    (if (not process-info)
      (jack-in-spawn-failed! comment-prefix ctx)
      (begin
        (write-nrepl-port workspace-root port)
        (set-state! (nrepl:append-to-buffer (get-state)
                     (string-append comment-prefix " nREPL: Waiting for server to start...\n")
                     ctx))
        (let ([max-attempts (* 30 2)] ; Poll every 0.5s for 30s
              [connected-flag (box #f)])
          (define (poll-server attempts)
            (if (unbox connected-flag)
              void
              (if (> attempts max-attempts)
                (jack-in-fail! process-info comment-prefix ctx
                  "Server failed to start within 30 seconds")
                ;; Fail fast if the server command already exited (e.g. not
                ;; found on PATH); bind once, the check reads a file.
                (let ([exit-code (server-exit-code process-info)])
                  (if exit-code
                    (jack-in-fail! process-info comment-prefix ctx
                      (string-append "Server exited (code " exit-code
                        ") before binding port"))
                    (if (try-connect-to-port port)
                      (begin
                        (set-box! connected-flag #t)
                        (jack-in-connect-and-finish process-info comment-prefix
                          workspace-root
                          port
                          ctx
                          #f))
                      (begin
                        (nrepl:log-debug (get-state)
                          (string-append "jack-in: port " (number->string port)
                            " not ready, attempt "
                            (number->string attempts)))
                        (enqueue-thread-local-callback-with-delay 500
                          (lambda () (poll-server (+ attempts 1)))))))))))
          (enqueue-thread-local-callback-with-delay 2000
            (lambda () (poll-server 0))))))))

;;@doc
;; Spawn an nREPL server that picks its own port (e.g. shadow-cljs) and
;; announces it via a port file. Polls for the file, reads the real port,
;; verifies the listener, then connects. on-connected (or #f) runs after a
;; successful connect with the final state set.
(define (jack-in-spawn-and-connect-via-port-file cmd workspace-root log-key-port
         port-file-path
         adapter
         ctx
         on-connected)
  (let* ([comment-prefix (adapter-comment-prefix adapter)]
         [process-info (spawn-nrepl-server cmd workspace-root log-key-port)])
    (if (not process-info)
      (jack-in-spawn-failed! comment-prefix ctx)
      (begin
        (set-state! (nrepl:append-to-buffer (get-state)
                     (string-append comment-prefix
                       " nREPL: Waiting for server to write "
                       port-file-path
                       "...\n")
                     ctx))
        (let ([max-attempts 240] ; 240 x 500ms = 120s; first cljs compile is slow
              [connected-flag (box #f)])
          (define (connect-via real-port)
            (set-box! connected-flag #t)
            ;; Re-key the process record with the REAL port so kill-server
            ;; targets the actual listener. Log path stays as spawned.
            (let ([real-process (make-spawned-process
                                 (spawned-process-process-handle process-info)
                                 cmd
                                 real-port
                                 workspace-root
                                 (spawned-process-log-path process-info))])
              (write-nrepl-port workspace-root real-port)
              (jack-in-connect-and-finish real-process comment-prefix workspace-root
                real-port
                ctx
                on-connected)))
          (define (poll-server attempts)
            (if (unbox connected-flag)
              void
              (if (> attempts max-attempts)
                (jack-in-fail! process-info comment-prefix ctx
                  "Server failed to start within 120 seconds")
                (let ([exit-code (server-exit-code process-info)])
                  (if exit-code
                    (jack-in-fail! process-info comment-prefix ctx
                      (string-append "Server exited (code " exit-code
                        ") before writing its port file"))
                    (let ([real-port (read-port-file port-file-path)])
                      (if (and real-port (try-connect-to-port real-port))
                        (connect-via real-port)
                        (enqueue-thread-local-callback-with-delay 500
                          (lambda () (poll-server (+ attempts 1)))))))))))
          (enqueue-thread-local-callback-with-delay 2000
            (lambda () (poll-server 0))))))))

;;@doc
;; Ensure the *nrepl* buffer exists, log the launch (server label, workspace,
;; resolved command), then spawn the server and connect. Shared by every
;; jack-in path (Scheme, Clojure, Janet); `adapter` supplies the comment
;; prefix for the log lines and is the provisional adapter handed to
;; `jack-in-spawn-and-connect` (a server fingerprint may override it after
;; connect). An optional trailing argument is a pre-formatted block of extra
;; comment lines (e.g. project details) logged before the Command line.
(define (begin-jack-in label cmd workspace-root port adapter . opts)
  (let* ([extra-info (if (null? opts) "" (car opts))]
         [cmd (string-append (jack-in-env-prefix) cmd)]
         [comment-prefix (adapter-comment-prefix adapter)]
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
              label
              " on port "
              (number->string port)
              "\n"
              comment-prefix
              " Workspace root: "
              workspace-root
              "\n"
              extra-info
              comment-prefix
              " Command: "
              cmd
              "\n")
            ctx))
        (jack-in-spawn-and-connect cmd workspace-root port adapter ctx)))))

;;@doc
;; Port-file counterpart of begin-jack-in: prepend the configured env prefix,
;; ensure the *nrepl* buffer, log the launch, then spawn and connect via the
;; server's announced port file. Putting the env prefix first keeps any
;; `cd ... &&` guard in cmd intact. An optional trailing argument is a
;; pre-formatted block of extra comment lines logged before the Command line.
(define (begin-jack-in-via-port-file label cmd workspace-root log-key-port
         port-file-path
         adapter
         on-connected
         .
         opts)
  (let* ([extra-info (if (null? opts) "" (car opts))]
         [cmd (string-append (jack-in-env-prefix) cmd)]
         [comment-prefix (adapter-comment-prefix adapter)]
         [ctx (make-helix-context)]
         [state (ensure-state)])
    (nrepl:ensure-buffer state ctx
      (lambda (state-with-buffer)
        (set-state! state-with-buffer)
        (set-state! (nrepl:append-to-buffer (get-state)
                     (string-append
                       comment-prefix
                       " nREPL: Starting "
                       label
                       "\n"
                       comment-prefix
                       " Workspace root: "
                       workspace-root
                       "\n"
                       extra-info
                       comment-prefix
                       " Command: "
                       cmd
                       "\n")
                     ctx))
        (jack-in-spawn-and-connect-via-port-file cmd workspace-root log-key-port
          port-file-path
          adapter
          ctx
          on-connected)))))

;;@doc
;; Begin Scheme jack-in: allocate a port and show the server picker. The picker
;; preview shows the exact command; on selection we spawn and connect.
;; toggle-keys is the Ctrl-t project-picker toggle handler, or #f.
(define (start-scheme-jack-in workspace-root toggle-keys)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-server-picker
        "Select Scheme nREPL server"
        scheme-servers
        workspace-root
        port
        (lambda (recipe)
          (continue-scheme-jack-in recipe workspace-root port))
        toggle-keys))))

;;@doc
;; Continue Scheme jack-in once a server method is chosen: log, spawn, connect.
;; The registry spans several Schemes (guile-ares-rs, nrepl-steel), so this only
;; picks a provisional adapter for the pre-connect log lines - all share the ";;"
;; comment prefix. `apply-capability-adapter` swaps in the correct adapter once
;; the server's `describe` fingerprint is known after connect.
(define (continue-scheme-jack-in recipe workspace-root port)
  (begin-jack-in
    (server-recipe-label recipe)
    (server-recipe-command recipe workspace-root port)
    workspace-root
    port
    (make-guile-adapter)))

;;;; Clojure Jack-In Fallback ;;;;

;; Helix language identifiers we treat as "Clojure" for the no-manifest jack-in
;; fallback.
(define clojure-language-ids '("clojure"))

;;@doc
;; Is the current buffer a Clojure buffer?
(define (clojure-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang clojure-language-ids) #t)))

;;@doc
;; Begin Clojure jack-in with no project manifest: allocate a port and show the
;; server picker of known Clojure launch methods. The normal manifest-driven path
;; (deps.edn/bb.edn/project.clj + alias picker) is unchanged; this also runs
;; via the Ctrl-t toggle from the project picker. toggle-keys is the toggle
;; handler, or #f.
(define (start-clojure-jack-in workspace-root toggle-keys)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-server-picker
        "Select Clojure nREPL server"
        clojure-servers
        workspace-root
        port
        (lambda (recipe)
          (continue-clojure-jack-in recipe workspace-root port))
        toggle-keys))))

;;@doc
;; Continue Clojure jack-in once a launch method is chosen: log, spawn, connect.
;; A Clojure server carries no Scheme/Janet fingerprint, so the Clojure adapter
;; chosen here survives `apply-capability-adapter` after connect.
(define (continue-clojure-jack-in recipe workspace-root port)
  (begin-jack-in
    (server-recipe-label recipe)
    (server-recipe-command recipe workspace-root port)
    workspace-root
    port
    (make-clojure-adapter)))

;;;; Elixir Jack-In Fallback ;;;;

;; Helix language identifiers we treat as "Elixir" for the no-manifest jack-in
;; fallback.
(define elixir-language-ids '("elixir"))

;;@doc
;; Is the current buffer an Elixir buffer?
(define (elixir-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang elixir-language-ids) #t)))

;;@doc
;; Begin Elixir jack-in with no project manifest: allocate a port and show the
;; server picker of known repartee launch methods. The normal manifest-driven
;; path (mix.exs) is unaffected; this also runs via the Ctrl-t toggle from the
;; project picker. toggle-keys is the toggle handler, or #f.
(define (start-elixir-jack-in workspace-root toggle-keys)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-server-picker
        "Select Elixir nREPL server"
        elixir-servers
        workspace-root
        port
        (lambda (recipe)
          (continue-elixir-jack-in recipe workspace-root port))
        toggle-keys))))

;;@doc
;; Continue Elixir jack-in once a launch method is chosen: log, spawn, connect.
;; repartee fingerprints itself (`elixir` in versions), so
;; `apply-capability-adapter` harmlessly re-selects this same adapter after
;; connect.
(define (continue-elixir-jack-in recipe workspace-root port)
  (begin-jack-in
    (server-recipe-label recipe)
    (server-recipe-command recipe workspace-root port)
    workspace-root
    port
    (make-elixir-adapter)))

;;;; Erlang Jack-In ;;;;

;; Helix language identifiers we treat as "Erlang" for jack-in purposes.
(define erlang-language-ids '("erlang"))

;;@doc
;; Is the current buffer an Erlang buffer?
(define (erlang-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang erlang-language-ids) #t)))

;;@doc
;; Begin Erlang jack-in: allocate a port and show the server picker (a single
;; recipe, dialtone, but the picker previews the command and hosts the Ctrl-t
;; project-picker toggle). toggle-keys is the toggle handler, or #f.
(define (start-erlang-jack-in workspace-root toggle-keys)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-server-picker
        "Select Erlang nREPL server"
        erlang-servers
        workspace-root
        port
        (lambda (recipe)
          (continue-erlang-jack-in recipe workspace-root port))
        toggle-keys))))

;;@doc
;; Continue Erlang jack-in once a launch method is chosen: log, spawn, connect.
;; The connected state keeps the Erlang adapter (the buffer language already
;; selects it, and dialtone's own fingerprint re-selects the same adapter
;; after connect).
(define (continue-erlang-jack-in recipe workspace-root port)
  (begin-jack-in
    (server-recipe-label recipe)
    (server-recipe-command recipe workspace-root port)
    workspace-root
    port
    (make-erlang-adapter)))

;;;; Janet Jack-In ;;;;

;; Helix language identifiers we treat as "Janet" for jack-in purposes.
(define janet-language-ids '("janet"))

;;@doc
;; Is the current buffer a Janet buffer?
(define (janet-buffer?)
  (let ([lang (get-current-language)])
    (and lang (member lang janet-language-ids) #t)))

;;@doc
;; Begin Janet jack-in: allocate a port and show the server picker (a single
;; recipe, janet-nrepl, but the picker previews the command and hosts the
;; Ctrl-t project-picker toggle). toggle-keys is the toggle handler, or #f.
(define (start-janet-jack-in workspace-root toggle-keys)
  (let ([port (find-free-port 7888 7988)])
    (if (not port)
      (helix.echo "nREPL: No free ports in range 7888-7988")
      (show-server-picker
        "Select Janet nREPL server"
        janet-servers
        workspace-root
        port
        (lambda (recipe)
          (continue-janet-jack-in recipe workspace-root port))
        toggle-keys))))

;;@doc
;; Continue Janet jack-in once a launch method is chosen: log, spawn, connect.
;; The connected state keeps the Janet adapter (the buffer language already
;; selects it, and no other fingerprint overrides it).
(define (continue-janet-jack-in recipe workspace-root port)
  (begin-jack-in
    (server-recipe-label recipe)
    (server-recipe-command recipe workspace-root port)
    workspace-root
    port
    (make-janet-adapter)))

;;@doc
;; The server-picker starter for the current buffer's language, or #f when the
;; language has no server recipe registry.
(define (jack-in-server-starter)
  (cond
    [(scheme-buffer?) start-scheme-jack-in]
    [(janet-buffer?) start-janet-jack-in]
    [(clojure-buffer?) start-clojure-jack-in]
    [(elixir-buffer?) start-elixir-jack-in]
    [(erlang-buffer?) start-erlang-jack-in]
    [else #f]))

;;@doc
;; Open the jack-in pickers with Ctrl-t toggling between the project-file
;; picker and the buffer language's server picker. The workspace root, the
;; scanned project files and the server-picker starter are captured once, so
;; toggling is cheap; each server-picker open re-allocates a free port. The
;; toggle handlers close the current picker and reopen the other on the next
;; event-loop turn (the session-picker kill idiom).
(define (jack-in-with-pickers workspace-root project-files starter initial)
  (define (project-toggle state-box event)
    (if (ctrl-char? event #\t)
      (if starter
        (begin
          (enqueue-thread-local-callback-with-delay 10 open-server-picker)
          event-result/close)
        (begin
          (set-status! "nREPL: No server recipes for this buffer's language")
          event-result/consume))
      #f))
  (define (server-toggle state-box event)
    (if (ctrl-char? event #\t)
      (begin
        (enqueue-thread-local-callback-with-delay 10 open-project-picker)
        event-result/close)
      #f))
  (define (open-project-picker)
    (show-project-file-picker workspace-root
      project-files
      continue-jack-in-with-file
      project-toggle))
  (define (open-server-picker)
    (starter workspace-root server-toggle))
  (if (eq? initial 'server) (open-server-picker) (open-project-picker)))

;;@doc
;; Start nREPL server for current project and connect
(define (nrepl-jack-in)
  (if (connected?)
    (helix.echo "nREPL: Already connected. Disconnect first with :nrepl-disconnect")
    (let ([workspace-root (helix-find-workspace)])
      (if (not workspace-root)
        (helix.echo "nREPL: No workspace found")
        (begin
          (load-project-config workspace-root)
          (when (not (null? (config-load-errors)))
            (helix.echo (string-append "nREPL: error in .helix/nrepl-jack-in.scm: "
                         (car (config-load-errors)))))
          (let ([project-files (find-project-files-recursive workspace-root)]
                [starter (jack-in-server-starter)])
            (cond
              ;; No project files and no server registry for this buffer's
              ;; language: nothing to offer.
              [(and (null? project-files) (not starter))
                (helix.echo "nREPL: No project files found in workspace")]

              ;; No project files: open the server picker (Ctrl-t reaches the
              ;; empty project picker). A picker is shown even if no method is
              ;; viable on this machine; a non-viable one fails at spawn.
              [(null? project-files)
                (jack-in-with-pickers workspace-root project-files starter 'server)]

              ;; Project files exist (even just one): open the project picker
              ;; (Ctrl-t reaches the server picker for a project-independent
              ;; server).
              [else
                (jack-in-with-pickers workspace-root project-files starter 'project)])))))))

;;@doc
;; Wrap plain name strings as alias-info structs for the alias picker.
;; Built with a cons/reverse loop: mapping a struct constructor over a list
;; that later crosses a native-thread join corrupts the heap.
(define (profile-names->alias-infos names)
  (let loop ([ns names] [acc '()])
    (if (null? ns)
      (reverse acc)
      (loop (cdr ns) (cons (make-alias-info (car ns) #f #f) acc)))))

;;@doc
;; Shared multi-select flow for profile-like selections (shadow builds, lein
;; profiles): load the persisted selection, show the picker, persist the new
;; selection, continue.
(define (show-selection-picker-then names workspace-root filename default-initial
         continue-fn)
  (let* ([saved (load-selection-file workspace-root filename)]
         [initial (if saved saved default-initial)])
    (show-alias-picker (profile-names->alias-infos names) initial
      (lambda (selected)
        (save-selection-file workspace-root filename selected)
        (continue-fn selected)))))

(define (continue-jack-in-with-file filepath)
  "Continue jack-in process with selected project file.
   Detects project info from file, handles aliases if present, spawns server."
  (let* ([project-info (detect-project-from-file filepath)])
    (if (not project-info)
      (helix.echo "nREPL: Could not detect project type from file")
      ;; Check if project has aliases
      (let ([aliases (project-info-aliases project-info)]
            [workspace-root (project-info-project-root project-info)]
            [project-type (project-info-project-type project-info)])
        (cond
          ;; shadow-cljs: multi-select build picker, empty selection valid
          ;; (server only, no watched build)
          [(equal? project-type 'shadow-cljs)
            (let ([builds (parse-shadow-builds filepath)])
              (if (null? builds)
                (continue-shadow-jack-in project-info '())
                (show-selection-picker-then builds workspace-root
                  "nrepl-shadow-builds.edn"
                  builds
                  (lambda (selected)
                    (continue-shadow-jack-in project-info selected)))))]
          ;; Leiningen: profile picker when project.clj declares profiles,
          ;; empty selection valid
          [(equal? project-type 'leiningen)
            (let ([profiles (parse-lein-profiles filepath)])
              (if (null? profiles)
                (continue-jack-in-with-aliases project-info #f)
                (show-selection-picker-then profiles workspace-root
                  "nrepl-lein-profiles.edn"
                  '()
                  (lambda (selected)
                    (continue-lein-jack-in project-info selected)))))]
          ;; deps.edn aliases: show picker
          [(and aliases (not (null? aliases)))
            (let* ([saved-selection (load-alias-selection workspace-root)]
                   ;; Use saved selection if exists, otherwise default to safe aliases
                   [initial-selection
                     (if saved-selection
                       saved-selection
                       (alias-info-list->names
                         (filter (lambda (ai) (not (alias-info-has-main-opts? ai))) aliases)))]
                   [callback (lambda (selected-names)
                              ;; Save selection before continuing
                              (save-alias-selection workspace-root selected-names)
                              (continue-jack-in-with-aliases project-info selected-names))])
              (show-alias-picker aliases initial-selection callback))]
          ;; No aliases - proceed directly
          [else (continue-jack-in-with-aliases project-info #f)])))))

;;@doc
;; The command :nrepl-jack-in would run for this project, or #f. Mirrors the
;; jack-in dispatch without pickers: shadow builds and lein profiles come from
;; the persisted selection files, falling back to the same defaults the
;; pickers start from (all builds; no profiles).
(define (resolve-copy-command project-info port)
  (let ([project-type (project-info-project-type project-info)]
        [workspace-root (project-info-project-root project-info)])
    (cond
      [(equal? project-type 'shadow-cljs)
        (let* ([saved (load-selection-file workspace-root "nrepl-shadow-builds.edn")]
               [builds (if saved
                        saved
                        (parse-shadow-builds (project-info-project-file project-info)))])
          (string-append "cd " (shell-single-quote workspace-root) " && "
            (build-shadow-command builds)))]
      [(equal? project-type 'leiningen)
        (let ([saved (load-selection-file workspace-root "nrepl-lein-profiles.edn")])
          (build-leiningen-command port (if saved saved '())))]
      [else
        (let ([adapter (adapter-for-project-type project-type)])
          (adapter-jack-in-cmd adapter project-info port))])))

;;@doc
;; Resolve the jack-in command for the workspace's nearest manifest and copy it
;; to the system clipboard, for running the server in a terminal.
(define (nrepl-copy-jack-in-command)
  (let ([workspace-root (helix-find-workspace)])
    (if (not workspace-root)
      (helix.echo "nREPL: No workspace found")
      (begin
        (load-project-config workspace-root)
        (let* ([files (sort-files-by-distance
                       (find-project-files-recursive workspace-root)
                       workspace-root)])
          (if (null? files)
            (helix.echo "nREPL: No project files found in workspace")
            (let* ([project-info (detect-project-from-file (car files))]
                   [port (find-free-port 7888 7988)]
                   [cmd (and project-info port (resolve-copy-command project-info port))])
              (if (not cmd)
                (helix.echo "nREPL: Jack-in not supported for this project type")
                (begin
                  (helix.set-register "+" (string-append (jack-in-env-prefix) cmd))
                  (helix.echo (string-append "nREPL: Copied jack-in command for "
                               (get-file-type-label (car files)))))))))))))

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
      [(string=? name "Elixir") (string=? lang "elixir")]
      [(string=? name "Erlang") (string=? lang "erlang")]
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
