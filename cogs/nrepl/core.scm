;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; core.scm - Language-Agnostic nREPL Client
;;;
;;; Core nREPL client functionality independent of target language.
;;; Handles connection management, evaluation, buffer management, and state,
;;; delegating language-specific formatting to adapter instances.

(require "adapter-interface.scm")
(require "adapter-utils.scm")
(require (only-in "string-utils.scm" parse-ffi-sexp))
(require "helix/misc.scm")

;; Shared REPL machinery from repl-ui.hx: scratch-buffer management, rope
;; coordinate conversion, and the per-session eval counter.
(require "repl-ui.hx/buffer.scm")
(require "repl-ui.hx/coords.scm")
(require "repl-ui.hx/counter.scm")

;; Load the steel-nrepl dylib
(#%require-dylib "libsteel_nrepl"
  (prefix-in ffi.
    (only-in connect
      clone-session
      eval
      eval-with-timeout
      load-file
      try-get-result
      close
      stats
      completions
      lookup
      interrupt
      stdin
      describe
      ls-sessions
      attach-session
      session-id
      close-session-by-id)))

(provide nrepl-state
  nrepl-state?
  nrepl-state-conn-id
  nrepl-state-session
  nrepl-state-session-wire-id
  nrepl-state-address
  nrepl-state-namespace
  nrepl-state-buffer-id
  nrepl-state-adapter
  nrepl-state-timeout-ms
  nrepl-state-orientation
  nrepl-state-debug
  nrepl-state-spawned-process
  nrepl-state-current-eval-request-id
  nrepl-state-auto-load-on-save
  nrepl-state-server-capabilities
  make-nrepl-state
  nrepl-state-with
  nrepl:connect
  nrepl:disconnect
  nrepl:eval-code
  nrepl:load-file
  nrepl:set-timeout
  nrepl:set-orientation
  nrepl:toggle-debug
  nrepl:toggle-auto-load-on-save
  nrepl:set-current-eval-request-id
  nrepl:interrupt
  nrepl:send-stdin
  nrepl:stats
  nrepl:describe
  nrepl:ls-sessions
  nrepl:attach-session
  nrepl:clone-and-attach
  nrepl:kill-session
  nrepl:server-supports?
  nrepl:ensure-buffer
  nrepl:append-to-buffer
  nrepl:create-buffer
  char-offset->line-col
  nrepl:log-debug
  nrepl:log-error)

;;;; State Management ;;;;

;; Connection state structure with language adapter
(struct nrepl-state
  (conn-id ; Connection ID (or #f if not connected)
    session ; Session handle (or #f)
    session-wire-id ; The session's on-the-wire id string (or #f)
    address ; Server address (e.g. "localhost:7888")
    namespace ; Current namespace (from last eval)
    buffer-id ; DocumentId of the *nrepl* buffer
    adapter ; Language adapter instance
    timeout-ms ; Eval timeout in milliseconds (default: 60000)
    orientation ; Buffer split orientation: 'vsplit or 'hsplit (default: 'vsplit)
    debug ; Debug mode flag (default: #f)
    spawned-process ; spawned-process struct or #f (for jack-in)
    current-eval-request-id ; request id of the in-flight eval, or #f (for interrupt)
    auto-load-on-save ; auto-run load-file on save when connected (default: #f)
    server-capabilities) ; parsed describe hash (ops/versions/aux), or #f if unknown
  #:transparent)

;;@doc
;; Create a new nREPL state with the given adapter
;; Default timeout is 60 seconds (60000ms), orientation is vsplit, debug off, no spawned process,
;; no in-flight eval, auto-load-on-save off
(define (make-nrepl-state adapter)
  (nrepl-state #f #f #f #f "user" #f adapter 60000 'vsplit #f #f #f #f #f))

;;@doc
;; Functional update: return a copy of `state` with the named fields replaced.
;; `overrides` alternates field symbols and values, e.g.
;;   (nrepl-state-with state 'buffer-id #f 'adapter new-adapter)
;; Field symbols match the struct field names. Unnamed fields are copied
;; unchanged; overriding a field to #f works (presence of the key decides).
(define (nrepl-state-with state . overrides)
  (define (over field current)
    (let loop ([kvs overrides])
      (cond
        [(null? kvs) current]
        [(eq? (car kvs) field) (cadr kvs)]
        [else (loop (cddr kvs))])))
  (nrepl-state
    (over 'conn-id (nrepl-state-conn-id state))
    (over 'session (nrepl-state-session state))
    (over 'session-wire-id (nrepl-state-session-wire-id state))
    (over 'address (nrepl-state-address state))
    (over 'namespace (nrepl-state-namespace state))
    (over 'buffer-id (nrepl-state-buffer-id state))
    (over 'adapter (nrepl-state-adapter state))
    (over 'timeout-ms (nrepl-state-timeout-ms state))
    (over 'orientation (nrepl-state-orientation state))
    (over 'debug (nrepl-state-debug state))
    (over 'spawned-process (nrepl-state-spawned-process state))
    (over 'current-eval-request-id (nrepl-state-current-eval-request-id state))
    (over 'auto-load-on-save (nrepl-state-auto-load-on-save state))
    (over 'server-capabilities (nrepl-state-server-capabilities state))))

;;;; Evaluation Counter ;;;;

;; Per-session evaluation counters, mirroring the `repl:N:>` numbering of an
;; interactive REPL. The nREPL protocol carries no per-eval sequence number
;; (the wire request id increments for every op, not just evals), so we track
;; them client-side: a map from wire session id to counter box. Entries
;; persist across session switches so each session keeps its own numbering;
;; the whole map is cleared on connect/disconnect.
(define *eval-counters* (box (hash)))

;; Fetch (or create) the counter box for a wire session id. Sessions whose
;; wire id is unknown share the "default" counter.
(define (counter-for wire-id)
  (let ([key (if wire-id wire-id "default")]
        [counters (unbox *eval-counters*)])
    (if (hash-contains? counters key)
      (hash-get counters key)
      (let ([counter (make-eval-counter)])
        (set-box! *eval-counters* (hash-insert counters key counter))
        counter))))

;;@doc
;; Advance the state's session's evaluation counter and return the new value
;; (first eval is 1). Called once per submitted evaluation so the prompt can
;; render `repl:N:>`.
(define (nrepl:next-eval-number state)
  (eval-counter-next! (counter-for (nrepl-state-session-wire-id state))))

;;@doc
;; Drop every session's counter (next eval in any session is numbered 1).
;; Called on connect and disconnect so numbering restarts per connection.
(define (nrepl:reset-eval-counter)
  (set-box! *eval-counters* (hash)))

;;@doc
;; Drop one session's counter (after the session is killed on the server).
(define (nrepl:drop-eval-counter wire-id)
  (set-box! *eval-counters*
    (hash-remove (unbox *eval-counters*) (if wire-id wire-id "default"))))

;;;; Diagnostics ;;;;

;;@doc
;; Emit a debug diagnostic to Helix's log when the state's debug flag is on.
;;
;; Surfaces via Helix's own logging (`hx -v`, `:log-open`). This is distinct
;; from the *nrepl* buffer output and from the Rust-side NREPL_DEBUG wire trace.
;;
;; Parameters:
;;   state - Current nREPL state (debug flag is read from it)
;;   msg   - Message string to log
(define (nrepl:log-debug state msg)
  (when (and state (nrepl-state-debug state))
    (log::debug! (string-append "[nrepl] " msg))))

;;@doc
;; Emit an error diagnostic to Helix's log unconditionally.
;;
;; Use on failure branches that otherwise only render to the *nrepl* buffer or
;; the status line, so problems are recoverable from the Helix log.
;;
;; Parameters:
;;   msg - Message string to log
(define (nrepl:log-error msg)
  (log::error! (string-append "[nrepl] " msg)))

;;;; Result Processing ;;;;

;;@doc
;; Parse the result string returned from FFI into a hashmap
;; The string is a hash construction call like: (hash 'value "..." 'output (list) ...)
;; Walked as data (never evaluated), so a hostile server cannot execute code here.
(define (parse-eval-result result-str)
  (parse-ffi-sexp result-str))

;; char-offset->line-col now lives in repl-ui.hx/coords.scm; it is required
;; above and re-exported from this module's provide list for existing callers.

;;@doc
;; Format error for display with prompt and commented details
;;
;; Takes an error message and formats it for the REPL buffer with:
;; - Prettified single-line error summary
;; - Full prompt with code
;; - Multi-line commented error details
;;
;; Returns: (list prettified-str formatted-str)
;;   prettified-str - Single line for echo/status
;;   formatted-str  - Full formatted output for buffer
;;
;; eval-number is the REPL prompt number for this evaluation (or #f when none),
;; so the error's echoed prompt matches the one shown at submit time.
(define (format-error-for-display adapter state code err-msg eval-number)
  (let* ([prettified (adapter-prettify-error adapter err-msg)]
         [prompt (adapter-format-prompt adapter (nrepl-state-namespace state) code eval-number)]
         [comment-prefix (adapter-comment-prefix adapter)]
         [commented (let* ([lines (split-many err-msg "\n")]
                           [commented-lines
                             (map (lambda (line) (string-append comment-prefix " " line)) lines)])
                     (string-join commented-lines "\n"))]
         [formatted (string-append prompt "✗ " prettified "\n" commented "\n\n")])
    (list prettified formatted)))

;;;; Core Client Functions ;;;;

;;@doc
;; Connect to an nREPL server
;;
;; Parameters:
;;   state    - Current nREPL state
;;   address  - Server address (host:port)
;;   on-success - Callback: (new-state) -> void
;;   on-error   - Callback: (error-message) -> void
(define (nrepl:connect state address on-success on-error)
  (nrepl:log-debug state (string-append "connect: dialing " address))
  (with-handler (lambda (err)
                 (let* ([adapter (nrepl-state-adapter state)]
                        [err-msg (error-object-message err)]
                        [prettified (adapter-prettify-error adapter err-msg)])
                   (nrepl:log-error (string-append "connect to " address " failed: " err-msg))
                   (on-error prettified)))
    ;; Connect to server
    (let ([conn-id (ffi.connect address)])
      ;; Create session
      (let ([session (ffi.clone-session conn-id)])
        (nrepl:log-debug state
          (string-append "connect: established conn to " address))
        ;; Capability discovery - never let a describe failure abort the connect.
        (let ([capabilities
                (with-handler (lambda (err)
                               (nrepl:log-debug state
                                 (string-append "describe failed (continuing without capabilities): "
                                   (error-object-message err)))
                               #f)
                  (nrepl:describe conn-id #f))])
          ;; The wire id keys the per-session eval counters and lets the
          ;; session picker mark the attached session; losing it only costs
          ;; those niceties, so never let it abort the connect.
          (let* ([wire-id (with-handler (lambda (err) #f) (ffi.session-id session))]
                 [new-state (nrepl-state-with state
                             'conn-id
                             conn-id
                             'session
                             session
                             'session-wire-id
                             wire-id
                             'address
                             address
                             'server-capabilities
                             capabilities)])
            ;; New session: restart REPL prompt numbering from 1.
            (nrepl:reset-eval-counter)
            (on-success new-state)))))))

;;@doc
;; Disconnect from the nREPL server
;;
;; Parameters:
;;   state      - Current nREPL state
;;   on-success - Callback: (new-state) -> void
;;   on-error   - Callback: (error-message) -> void
(define (nrepl:disconnect state on-success on-error)
  (if (not (nrepl-state-conn-id state))
    (on-error "Not connected")
    (with-handler
      (lambda (err)
        (let* ([adapter (nrepl-state-adapter state)]
               [err-msg (error-object-message err)]
               [prettified (adapter-prettify-error adapter err-msg)])
          (nrepl:log-error (string-append "disconnect failed: " err-msg))
          (on-error prettified)))
      (let ([conn-id (nrepl-state-conn-id state)])
        (nrepl:log-debug state
          (string-append "disconnect: closing conn " (number->string conn-id)))
        ;; Close connection
        (ffi.close conn-id)

        ;; Session ended: restart REPL prompt numbering for the next connect.
        (nrepl:reset-eval-counter)

        ;; Reset state (keep adapter, buffer-id, timeout, orientation, and debug; clear spawned-process)
        (let ([new-state (nrepl-state-with state
                          'conn-id
                          #f
                          'session
                          #f
                          'session-wire-id
                          #f
                          'address
                          #f
                          'namespace
                          "user"
                          'spawned-process
                          #f
                          'current-eval-request-id
                          #f
                          'server-capabilities
                          #f)])
          (on-success new-state))))))

;;@doc
;; Evaluate code and format result using adapter
;;
;; Parameters:
;;   state      - Current nREPL state
;;   code       - Code to evaluate (string)
;;   file-path  - Optional file path (or #f)
;;   line-num   - Optional line number (or #f), 1-indexed
;;   col-num    - Optional column number (or #f), 1-indexed
;;   on-submit  - Callback: (req-id) -> void, fired once the eval is submitted
;;                (used to record the in-flight request id for :nrepl-interrupt)
;;   on-output  - Callback: (formatted-string) -> void, appends text to the
;;                buffer mid-eval. Used to echo the `=> code` prompt at submit
;;                and to render partial stdout before a `need-input` prompt.
;;   on-need-input - Callback: (send-input!) -> void, fired when the server
;;                reports `need-input`. Call (send-input! line-string) to feed a
;;                line of stdin and resume polling, or (send-input! #f) to cancel.
;;   on-success - Callback: (new-state formatted-result) -> void
;;                Where formatted-result is string ready for buffer
;;   on-error   - Callback: (error-message formatted-error) -> void
;;                Where formatted-error is string ready for buffer
(define (nrepl:eval-code state
         code
         file-path
         line-num
         col-num
         on-submit
         on-output
         on-need-input
         on-success
         on-error)
  (if (not (nrepl-state-session state))
    (on-error "Not connected" "")
    ;; Claim this evaluation's REPL prompt number up front (mirrors the CLI's
    ;; `repl:N:>`). Consumed even if submission fails, so the number shown in an
    ;; error matches what the user would have seen for this input.
    (let ([eval-number (nrepl:next-eval-number state)])
      (with-handler
        (lambda (err)
          (let* ([result (format-error-for-display (nrepl-state-adapter state)
                          state
                          code
                          (error-object-message err)
                          eval-number)]
                 [prettified (car result)]
                 [formatted (cadr result)])
            (nrepl:log-error (string-append "eval submit failed: " (error-object-message err)))
            (on-error prettified formatted)))
        ;; Submit eval request (non-blocking, returns request ID immediately)
        (let* ([session (nrepl-state-session state)]
               [conn-id (nrepl-state-conn-id state)]
               [timeout-ms (nrepl-state-timeout-ms state)]
               [req-id (ffi.eval-with-timeout session code timeout-ms file-path line-num col-num)])
          (nrepl:log-debug state
            (string-append "eval: submitted req "
              (number->string req-id)
              " file="
              (if file-path file-path "#f")
              " line="
              (if line-num (number->string line-num) "#f")
              " col="
              (if col-num (number->string col-num) "#f")))
          ;; Record the in-flight request id (e.g. so :nrepl-interrupt can target it)
          (on-submit req-id)
          ;; Echo the `=> code` prompt up front so output streamed before a
          ;; need-input pause renders after it (the prompt is suppressed in the
          ;; Done formatter below, see the `#f` argument to adapter-format-result).
          (on-output (adapter-format-prompt (nrepl-state-adapter state)
                      (nrepl-state-namespace state)
                      code
                      eval-number))
          ;; Poll for result using enqueue-thread-local-callback-with-delay (yields to event loop)
          (define (poll-for-result)
            (with-handler
              ;; Catch errors from ffi.try-get-result (e.g., timeout errors)
              (lambda (err)
                (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                state
                                code
                                (error-object-message err)
                                eval-number)]
                       [prettified (car result)]
                       [formatted (cadr result)])
                  (nrepl:log-error (string-append "eval req "
                                    (number->string req-id)
                                    " failed: "
                                    (error-object-message err)))
                  (on-error prettified formatted)))
              (let ([maybe-result (ffi.try-get-result conn-id req-id)])
                (if maybe-result
                  ;; Result ready - process it
                  (with-handler
                    (lambda (err)
                      (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                      state
                                      code
                                      (error-object-message err)
                                      eval-number)]
                             [prettified (car result)]
                             [formatted (cadr result)])
                        (nrepl:log-error (string-append "eval req "
                                          (number->string req-id)
                                          " result processing failed: "
                                          (error-object-message err)))
                        (on-error prettified formatted)))
                    (let ([result (parse-eval-result maybe-result)])
                      (if (and (hash? result) (hash-contains? result 'need-input))
                        ;; Server is blocked on (read-line) etc. Hand control to
                        ;; the caller's prompt; send-input! feeds stdin and resumes.
                        (begin
                          (nrepl:log-debug state
                            (string-append "eval req "
                              (number->string req-id)
                              " needs input"))
                          ;; Render output produced before the pause (e.g. a
                          ;; prompt string) to the buffer *before* showing the
                          ;; stdin prompt, so the prompt text is visible above the
                          ;; input box. Drained server-side, so Done won't repeat it.
                          (let ([partial (format-output-list
                                          (if (hash-contains? result 'output)
                                            (hash-get result 'output)
                                            '()))])
                            (when (not (whitespace-only? partial))
                              (on-output partial)))
                          (on-need-input
                            (lambda (input)
                              (when input
                                (nrepl:send-stdin state input))
                              (enqueue-thread-local-callback-with-delay 10 poll-for-result))))
                        ;; Normal result - format and finish
                        (let* ([_ (nrepl:log-debug state
                                   (string-append "eval req "
                                     (number->string req-id)
                                     " result ready"))]
                               [adapter (nrepl-state-adapter state)]
                               ;; Prompt already echoed at submit via on-output, so
                               ;; suppress it here (#f) to avoid a duplicate.
                               [formatted (adapter-format-result adapter code result #f)]
                               [ns (hash-get result 'ns)]
                               ;; Update namespace if present
                               [new-state (if ns
                                           (nrepl-state-with state 'namespace ns)
                                           state)])
                          (on-success new-state formatted)))))
                  ;; Result not ready yet - poll again after 10ms
                  (enqueue-thread-local-callback-with-delay 10 poll-for-result)))))
          (poll-for-result))))))

;;@doc
;; Load a file and format result using adapter
;;
;; Parameters:
;;   state      - Current nREPL state
;;   file-contents - File contents to load (string)
;;   file-path  - Path to file (for error messages)
;;   file-name  - Filename (for error messages)
;;   on-success - Callback: (new-state formatted-result) -> void
;;                Where formatted-result is string ready for buffer
;;   on-error   - Callback: (error-message formatted-error) -> void
;;                Where formatted-error is string ready for buffer
(define (nrepl:load-file state file-contents file-path file-name on-success on-error)
  (if (not (nrepl-state-session state))
    (on-error "Not connected" "")
    ;; A load-file counts as one numbered evaluation, like a REPL input.
    (let ([eval-number (nrepl:next-eval-number state)])
      (with-handler
        (lambda (err)
          (let* ([result (format-error-for-display (nrepl-state-adapter state)
                          state
                          file-contents
                          (error-object-message err)
                          eval-number)]
                 [prettified (car result)]
                 [formatted (cadr result)])
            (nrepl:log-error (string-append "load-file submit failed: " (error-object-message err)))
            (on-error prettified formatted)))
        ;; Submit load-file request (non-blocking, returns request ID immediately)
        (let* ([session (nrepl-state-session state)]
               [conn-id (nrepl-state-conn-id state)]
               [req-id (ffi.load-file session file-contents file-path file-name)])
          (nrepl:log-debug state
            (string-append "load-file: submitted req "
              (number->string req-id)
              " path="
              (if file-path file-path "#f")))
          ;; Poll for result using enqueue-thread-local-callback-with-delay (yields to event loop)
          (define (poll-for-result)
            (with-handler
              ;; Catch errors from ffi.try-get-result (e.g., timeout errors)
              (lambda (err)
                (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                state
                                file-contents
                                (error-object-message err)
                                eval-number)]
                       [prettified (car result)]
                       [formatted (cadr result)])
                  (nrepl:log-error (string-append "load-file req "
                                    (number->string req-id)
                                    " failed: "
                                    (error-object-message err)))
                  (on-error prettified formatted)))
              (let ([maybe-result (ffi.try-get-result conn-id req-id)])
                (if maybe-result
                  ;; Result ready - process it
                  (with-handler
                    (lambda (err)
                      (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                      state
                                      file-contents
                                      (error-object-message err)
                                      eval-number)]
                             [prettified (car result)]
                             [formatted (cadr result)])
                        (nrepl:log-error (string-append "load-file req "
                                          (number->string req-id)
                                          " result processing failed: "
                                          (error-object-message err)))
                        (on-error prettified formatted)))
                    (let* ([_ (nrepl:log-debug state
                               (string-append "load-file req "
                                 (number->string req-id)
                                 " result ready"))]
                           [result (parse-eval-result maybe-result)]
                           [adapter (nrepl-state-adapter state)]
                           [formatted (adapter-format-result adapter file-contents result #t eval-number)]
                           [ns (hash-get result 'ns)]
                           ;; Update namespace if present
                           [new-state (if ns
                                       (nrepl-state-with state 'namespace ns)
                                       state)])
                      (on-success new-state formatted)))
                  ;; Result not ready yet - poll again after 10ms
                  (enqueue-thread-local-callback-with-delay 10 poll-for-result)))))
          (poll-for-result))))))

;;@doc
;; Set the evaluation timeout
;;
;; Parameters:
;;   state      - Current nREPL state
;;   timeout-ms - Timeout in milliseconds (e.g., 120000 for 2 minutes)
;;
;; Returns: new state with updated timeout
(define (nrepl:set-timeout state timeout-ms)
  (nrepl-state-with state 'timeout-ms timeout-ms))

;;@doc
;; Set the buffer split orientation
;;
;; Parameters:
;;   state       - Current nREPL state
;;   orientation - Either 'vsplit or 'hsplit
;;
;; Returns: new state with updated orientation
(define (nrepl:set-orientation state orientation)
  (nrepl-state-with state 'orientation orientation))

;;@doc
;; Get registry statistics for debugging
;;
;; Returns a hash with connection and session counts:
;;   'connections - Number of active connections
;;   'sessions - Number of active sessions
(define (nrepl:stats)
  (ffi.stats))

;;@doc
;; Query the server's capabilities via the nREPL `describe` operation.
;;
;; Parameters:
;;   conn-id - Connection ID
;;   verbose - When #t, the server includes full op documentation
;;
;; Returns a parsed hash with:
;;   'ops      - list of supported operation name strings
;;   'versions - hash of implementation -> (hash of sub-key -> value)
;;   'aux      - hash of auxiliary metadata
;;
;; Throws if the connection is invalid or the server does not support describe.
(define (nrepl:describe conn-id verbose)
  (parse-eval-result (ffi.describe conn-id verbose)))

;;@doc
;; Predicate: does the connected server advertise support for `op-name`?
;;
;; Returns #t when capabilities are unknown (#f) so behaviour stays optimistic
;; against servers that don't answer `describe` - matching the pre-negotiation
;; behaviour of firing the op and letting it fail. Returns #t/#f based on the
;; advertised ops list otherwise.
;;
;; Parameters:
;;   state   - Current nREPL state
;;   op-name - Operation name string (e.g. "lookup", "completions")
(define (nrepl:server-supports? state op-name)
  (let ([caps (nrepl-state-server-capabilities state)])
    (if (not caps)
      #t
      (let ([ops (hash-get caps 'ops)])
        (if (member op-name ops) #t #f)))))

;;;; Sessions ;;;;

;;@doc
;; List the sessions active on the server, as a list of wire session id
;; strings. Requires the server to support the "ls-sessions" op (gate with
;; nrepl:server-supports?); raises on servers that don't.
(define (nrepl:ls-sessions state)
  (parse-eval-result (ffi.ls-sessions (nrepl-state-conn-id state))))

;; Shared state update for attaching to a session: the previous session stays
;; alive on the server. Namespace resets to the default because it is
;; per-session server state we don't track remotely; the next eval re-derives
;; it from the response's ns field. Clearing current-eval-request-id means an
;; in-flight eval on the old session still renders when it completes, but is
;; no longer the target of :nrepl-interrupt.
(define (state-with-session state session wire-id)
  (nrepl-state-with state
    'session
    session
    'session-wire-id
    wire-id
    'namespace
    "user"
    'current-eval-request-id
    #f))

;;@doc
;; Attach to an existing server session by wire id and return the new state.
;; Purely client-side (the session already exists on the server); the wire id
;; must come from nrepl:ls-sessions.
(define (nrepl:attach-session state wire-id)
  (state-with-session state
    (ffi.attach-session (nrepl-state-conn-id state) wire-id)
    wire-id))

;;@doc
;; Clone a fresh session on the server, attach to it, and return the new
;; state. The previous session stays alive.
(define (nrepl:clone-and-attach state)
  (let* ([session (ffi.clone-session (nrepl-state-conn-id state))]
         [wire-id (with-handler (lambda (err) #f) (ffi.session-id session))])
    (state-with-session state session wire-id)))

;;@doc
;; Close a session on the server by wire id and drop its eval counter. Do not
;; call with the currently attached session's id; switch first.
(define (nrepl:kill-session state wire-id)
  (ffi.close-session-by-id (nrepl-state-conn-id state) wire-id)
  (nrepl:drop-eval-counter wire-id))

;;;; Buffer Management ;;;;

;; The scratch-buffer mechanics live in repl-ui.hx/buffer.scm; these wrappers
;; adapt between nREPL state and the shared repl-buffer handle. The buffer name
;; ("*nrepl*"), seed line and split orientation come from state, so behaviour is
;; unchanged for callers.
(define (state->repl-buffer state)
  (let ([comment-prefix (adapter-comment-prefix (nrepl-state-adapter state))])
    (repl-buffer (nrepl-state-buffer-id state)
      "*nrepl*"
      (nrepl-state-orientation state)
      (string-append comment-prefix " nREPL buffer\n")
      ;; #f: copy the source document's language (unchanged nREPL behaviour)
      #f)))

;; Fold a (possibly updated) repl-buffer id back into nREPL state.
(define (state-with-buffer state rb)
  (nrepl-state-with state 'buffer-id (repl-buffer-id rb)))

;;@doc
;; Ensure the *nrepl* buffer exists and is visible, creating it if necessary.
;; on-success is called with the (possibly updated) state.
(define (nrepl:ensure-buffer state helix-context on-success)
  (repl-buffer:ensure
    (state->repl-buffer state)
    helix-context
    (lambda (rb) (on-success (state-with-buffer state rb)))))

;;@doc
;; Create the *nrepl* buffer in a split (orientation determined by state).
;; on-success is called with the updated state.
(define (nrepl:create-buffer state helix-context on-success)
  (repl-buffer:create
    (state->repl-buffer state)
    helix-context
    (lambda (rb) (on-success (state-with-buffer state rb)))))

;;@doc
;; Append text to the *nrepl* buffer, returning the (possibly updated) state
;; (buffer-id cleared if the buffer was closed or is no longer visible).
(define (nrepl:append-to-buffer state text helix-context)
  (state-with-buffer state
    (repl-buffer:append (state->repl-buffer state) text helix-context)))

;;@doc
;; Toggle debug mode
;;
;; Parameters:
;;   state - Current nREPL state
;;
;; Returns: new state with debug flag toggled
(define (nrepl:toggle-debug state)
  (nrepl-state-with state 'debug (not (nrepl-state-debug state))))

;;@doc
;; Return a copy of state with the in-flight eval request id set (or cleared
;; with #f). Used so :nrepl-interrupt can target the active evaluation.
(define (nrepl:set-current-eval-request-id state req-id)
  (nrepl-state-with state 'current-eval-request-id req-id))

;;@doc
;; Toggle auto-load-on-save mode.
;;
;; Returns: new state with the auto-load-on-save flag flipped
(define (nrepl:toggle-auto-load-on-save state)
  (nrepl-state-with state
    'auto-load-on-save
    (not (nrepl-state-auto-load-on-save state))))

;;@doc
;; Interrupt the in-flight evaluation tracked in state, if any.
;;
;; Parameters:
;;   state      - Current nREPL state
;;   on-none    - Thunk called when there is nothing to interrupt
;;   on-success - Thunk called when the interrupt was sent successfully
;;   on-error   - Callback: (error-message) -> void
(define (nrepl:interrupt state on-none on-success on-error)
  (let ([session (nrepl-state-session state)]
        [req-id (nrepl-state-current-eval-request-id state)])
    (if (or (not session) (not req-id))
      (on-none)
      (with-handler (lambda (err)
                     (let ([msg (error-object-message err)])
                       (nrepl:log-error (string-append "interrupt failed: " msg))
                       (on-error msg)))
        (nrepl:log-debug state
          (string-append "interrupt: req "
            (number->string req-id)))
        (ffi.interrupt session req-id)
        (on-success)))))

;;@doc
;; Send a line of stdin to the session (a trailing newline is appended so
;; (read-line) unblocks).
(define (nrepl:send-stdin state input)
  (let ([session (nrepl-state-session state)])
    (when session
      (ffi.stdin session (string-append input "\n")))))
