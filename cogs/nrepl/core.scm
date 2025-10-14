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

(require "cogs/nrepl/adapter-interface.scm")
(require "helix/misc.scm")

;; Load the steel-nrepl dylib
(#%require-dylib
 "libsteel_nrepl"
 (prefix-in ffi. (only-in connect clone-session eval eval-with-timeout try-get-result close stats)))

(provide nrepl-state
         nrepl-state?
         nrepl-state-conn-id
         nrepl-state-session
         nrepl-state-address
         nrepl-state-namespace
         nrepl-state-buffer-id
         nrepl-state-adapter
         nrepl-state-timeout-ms
         nrepl-state-orientation
         make-nrepl-state
         nrepl:connect
         nrepl:disconnect
         nrepl:eval-code
         nrepl:set-timeout
         nrepl:set-orientation
         nrepl:stats
         nrepl:ensure-buffer
         nrepl:append-to-buffer
         nrepl:create-buffer)

;;;; State Management ;;;;

;; Connection state structure with language adapter
(struct nrepl-state
        (conn-id ; Connection ID (or #f if not connected)
         session ; Session handle (or #f)
         address ; Server address (e.g. "localhost:7888")
         namespace ; Current namespace (from last eval)
         buffer-id ; DocumentId of the *nrepl* buffer
         adapter ; Language adapter instance
         timeout-ms ; Eval timeout in milliseconds (default: 60000)
         orientation) ; Buffer split orientation: 'vsplit or 'hsplit (default: 'vsplit)
  #:transparent)

;;@doc
;; Create a new nREPL state with the given adapter
;; Default timeout is 60 seconds (60000ms), orientation is vsplit
(define (make-nrepl-state adapter)
  (nrepl-state #f #f #f "user" #f adapter 60000 'vsplit))

;;;; Result Processing ;;;;

;;@doc
;; Parse the result string returned from FFI into a hashmap
;; The string is a hash construction call like: (hash 'value "..." 'output (list) ...)
(define (parse-eval-result result-str)
  (eval (read (open-input-string result-str))))

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
(define (format-error-for-display adapter state code err-msg)
  (let* ([prettified (adapter-prettify-error adapter err-msg)]
         [prompt (adapter-format-prompt adapter (nrepl-state-namespace state) code)]
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
  (with-handler (lambda (err)
                  (let* ([adapter (nrepl-state-adapter state)]
                         [err-msg (error-object-message err)]
                         [prettified (adapter-prettify-error adapter err-msg)])
                    (on-error prettified)))
                ;; Connect to server
                (let ([conn-id (ffi.connect address)])
                  ;; Create session
                  (let ([session (ffi.clone-session conn-id)])
                    (let ([new-state (nrepl-state conn-id
                                                  session
                                                  address
                                                  (nrepl-state-namespace state)
                                                  (nrepl-state-buffer-id state)
                                                  (nrepl-state-adapter state)
                                                  (nrepl-state-timeout-ms state)
                                                  (nrepl-state-orientation state))])
                      (on-success new-state))))))

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
      (with-handler (lambda (err)
                      (let* ([adapter (nrepl-state-adapter state)]
                             [err-msg (error-object-message err)]
                             [prettified (adapter-prettify-error adapter err-msg)])
                        (on-error prettified)))
                    (let ([conn-id (nrepl-state-conn-id state)])
                      ;; Close connection
                      (ffi.close conn-id)

                      ;; Reset state (keep adapter, buffer-id, timeout, and orientation)
                      (let ([new-state (nrepl-state #f
                                                    #f
                                                    #f
                                                    "user"
                                                    (nrepl-state-buffer-id state)
                                                    (nrepl-state-adapter state)
                                                    (nrepl-state-timeout-ms state)
                                                    (nrepl-state-orientation state))])
                        (on-success new-state))))))

;;@doc
;; Evaluate code and format result using adapter
;;
;; Parameters:
;;   state      - Current nREPL state
;;   code       - Code to evaluate (string)
;;   on-success - Callback: (new-state formatted-result) -> void
;;                Where formatted-result is string ready for buffer
;;   on-error   - Callback: (error-message formatted-error) -> void
;;                Where formatted-error is string ready for buffer
(define (nrepl:eval-code state code on-success on-error)
  (if (not (nrepl-state-session state))
      (on-error "Not connected" "")
      (with-handler
       (lambda (err)
         (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                                  state
                                                  code
                                                  (error-object-message err))]
                [prettified (car result)]
                [formatted (cadr result)])
           (on-error prettified formatted)))
       ;; Submit eval request (non-blocking, returns request ID immediately)
       (let* ([session (nrepl-state-session state)]
              [conn-id (nrepl-state-conn-id state)]
              [timeout-ms (nrepl-state-timeout-ms state)]
              [req-id (ffi.eval-with-timeout session code timeout-ms)])
         ;; Poll for result using enqueue-thread-local-callback-with-delay (yields to event loop)
         (define (poll-for-result)
           (with-handler
            ;; Catch errors from ffi.try-get-result (e.g., timeout errors)
            (lambda (err)
              (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                                       state
                                                       code
                                                       (error-object-message err))]
                     [prettified (car result)]
                     [formatted (cadr result)])
                (on-error prettified formatted)))
            (let ([maybe-result (ffi.try-get-result conn-id req-id)])
              (if maybe-result
                  ;; Result ready - process it
                  (with-handler
                   (lambda (err)
                     (let* ([result (format-error-for-display (nrepl-state-adapter state)
                                                              state
                                                              code
                                                              (error-object-message err))]
                            [prettified (car result)]
                            [formatted (cadr result)])
                       (on-error prettified formatted)))
                   (let* ([result (parse-eval-result maybe-result)]
                          [adapter (nrepl-state-adapter state)]
                          [formatted (adapter-format-result adapter code result)]
                          [ns (hash-get result 'ns)]
                          ;; Update namespace if present
                          [new-state (if ns
                                         (nrepl-state (nrepl-state-conn-id state)
                                                      (nrepl-state-session state)
                                                      (nrepl-state-address state)
                                                      ns
                                                      (nrepl-state-buffer-id state)
                                                      (nrepl-state-adapter state)
                                                      (nrepl-state-timeout-ms state)
                                                      (nrepl-state-orientation state))
                                         state)])
                     (on-success new-state formatted)))
                  ;; Result not ready yet - poll again after 10ms
                  (enqueue-thread-local-callback-with-delay 10 poll-for-result)))))
         (poll-for-result)))))

;;@doc
;; Set the evaluation timeout
;;
;; Parameters:
;;   state      - Current nREPL state
;;   timeout-ms - Timeout in milliseconds (e.g., 120000 for 2 minutes)
;;
;; Returns: new state with updated timeout
(define (nrepl:set-timeout state timeout-ms)
  (nrepl-state (nrepl-state-conn-id state)
               (nrepl-state-session state)
               (nrepl-state-address state)
               (nrepl-state-namespace state)
               (nrepl-state-buffer-id state)
               (nrepl-state-adapter state)
               timeout-ms
               (nrepl-state-orientation state)))

;;@doc
;; Set the buffer split orientation
;;
;; Parameters:
;;   state       - Current nREPL state
;;   orientation - Either 'vsplit or 'hsplit
;;
;; Returns: new state with updated orientation
(define (nrepl:set-orientation state orientation)
  (nrepl-state (nrepl-state-conn-id state)
               (nrepl-state-session state)
               (nrepl-state-address state)
               (nrepl-state-namespace state)
               (nrepl-state-buffer-id state)
               (nrepl-state-adapter state)
               (nrepl-state-timeout-ms state)
               orientation))

;;@doc
;; Get registry statistics for debugging
;;
;; Returns a hash with connection and session counts:
;;   'connections - Number of active connections
;;   'sessions - Number of active sessions
(define (nrepl:stats)
  (ffi.stats))

;;;; Buffer Management ;;;;

;;@doc
;; Ensure the *nrepl* buffer exists and is visible, creating it if necessary
;;
;; Parameters:
;;   state           - Current nREPL state
;;   helix-context   - Hash with Helix API functions:
;;                     'editor-focus
;;                     'editor->doc-id
;;                     'editor-document->language
;;                     'editor-doc-exists?
;;                     'editor-doc-in-view?
;;                     'helix.new
;;                     'helix.vsplit
;;                     'helix.hsplit
;;                     'set-scratch-buffer-name!
;;                     'helix.set-language
;;                     'helix.static.insert_string
;;   on-success      - Callback: (new-state) -> void
(define (nrepl:ensure-buffer state helix-context on-success)
  (let ([buffer-id (nrepl-state-buffer-id state)])
    (if (and buffer-id
             ((hash-get helix-context 'editor-doc-exists?) buffer-id)
             ((hash-get helix-context 'editor-doc-in-view?) buffer-id))
        ;; Buffer ID exists, buffer is valid, and buffer is visible
        (on-success state)
        ;; No buffer, buffer was closed, or buffer not visible - clear ID and create new buffer
        (let ([new-state (if buffer-id
                             ;; Had a buffer-id but buffer is gone or not visible - clear it
                             (nrepl-state (nrepl-state-conn-id state)
                                          (nrepl-state-session state)
                                          (nrepl-state-address state)
                                          (nrepl-state-namespace state)
                                          #f ;; Clear buffer-id
                                          (nrepl-state-adapter state)
                                          (nrepl-state-timeout-ms state)
                                          (nrepl-state-orientation state))
                             ;; No buffer-id to begin with
                             state)])
          (nrepl:create-buffer new-state helix-context on-success)))))

;;@doc
;; Create the *nrepl* buffer in a split (orientation determined by state)
;;
;; Parameters:
;;   state           - Current nREPL state
;;   helix-context   - Hash with Helix API functions (see nrepl:ensure-buffer)
;;   on-success      - Callback: (new-state) -> void
(define (nrepl:create-buffer state helix-context on-success)
  ;; Get the language from the current buffer
  (let ([original-focus ((hash-get helix-context 'editor-focus))]
        [editor->doc-id (hash-get helix-context 'editor->doc-id)])
    (let ([original-doc-id (editor->doc-id original-focus)]
          [editor-document->language (hash-get helix-context 'editor-document->language)])
      (let ([language (editor-document->language original-doc-id)]
            [orientation (nrepl-state-orientation state)])
        ;; Create split based on orientation setting
        (if (eq? orientation 'hsplit)
            ((hash-get helix-context 'helix.hsplit))
            ((hash-get helix-context 'helix.vsplit)))
        ;; Create new scratch buffer (will be created in the split)
        ((hash-get helix-context 'helix.new))
        ;; Set the buffer name
        ((hash-get helix-context 'set-scratch-buffer-name!) "*nrepl*")
        ;; Set language to match the current buffer
        (when language
          ((hash-get helix-context 'helix.set-language) language))
        ;; Store the buffer ID for future use
        (let* ([buffer-id (editor->doc-id ((hash-get helix-context 'editor-focus)))]
               [comment-prefix (adapter-comment-prefix (nrepl-state-adapter state))])
          ;; Add initial content to preserve the buffer
          ((hash-get helix-context 'helix.static.insert_string) (string-append comment-prefix
                                                                               " nREPL buffer\n"))
          ;; Return focus to original view
          ((hash-get helix-context 'editor-set-focus!) original-focus)
          (let ([new-state (nrepl-state (nrepl-state-conn-id state)
                                        (nrepl-state-session state)
                                        (nrepl-state-address state)
                                        (nrepl-state-namespace state)
                                        buffer-id
                                        (nrepl-state-adapter state)
                                        (nrepl-state-timeout-ms state)
                                        (nrepl-state-orientation state))])
            (on-success new-state)))))))

;;@doc
;; Append text to the REPL buffer
;;
;; Checks if buffer is still valid and clears buffer-id from state if not.
;; Returns the (possibly updated) state.
;;
;; Parameters:
;;   state           - Current nREPL state
;;   text            - Text to append
;;   helix-context   - Hash with Helix API functions:
;;                     'editor-focus
;;                     'editor-mode
;;                     'editor->doc-id
;;                     'editor-doc-in-view?
;;                     'editor-doc-exists?
;;                     'editor-set-focus!
;;                     'editor-set-mode!
;;                     'helix.static.select_all
;;                     'helix.static.collapse_selection
;;                     'helix.static.insert_string
;;                     'helix.static.align_view_bottom
;;
;; Returns: state (with buffer-id cleared if buffer was invalid or not visible)
(define (nrepl:append-to-buffer state text helix-context)
  (let ([buffer-id (nrepl-state-buffer-id state)])
    (if (not buffer-id)
        ;; No buffer ID - return state unchanged
        state
        ;; Check if buffer still exists
        (if (not ((hash-get helix-context 'editor-doc-exists?) buffer-id))
            ;; Buffer was closed - clear buffer-id from state
            (nrepl-state (nrepl-state-conn-id state)
                         (nrepl-state-session state)
                         (nrepl-state-address state)
                         (nrepl-state-namespace state)
                         #f ;; Clear buffer-id
                         (nrepl-state-adapter state)
                         (nrepl-state-timeout-ms state)
                         (nrepl-state-orientation state))
            ;; Buffer exists - check if it's visible
            (let ([maybe-view-id ((hash-get helix-context 'editor-doc-in-view?) buffer-id)])
              (if maybe-view-id
                  ;; Buffer is visible - append to it
                  ;; If buffer operations fail for some reason
                  (with-handler (lambda (err)
                                  ;; Clear buffer-id from state and return updated state
                                  (nrepl-state (nrepl-state-conn-id state)
                                               (nrepl-state-session state)
                                               (nrepl-state-address state)
                                               (nrepl-state-namespace state)
                                               #f ;; Clear buffer-id
                                               (nrepl-state-adapter state)
                                               (nrepl-state-timeout-ms state)
                                               (nrepl-state-orientation state)))
                                ;; Try to append to buffer
                                (let ([original-focus ((hash-get helix-context 'editor-focus))]
                                      [original-mode ((hash-get helix-context 'editor-mode))])
                                  (begin
                                    ;; Switch focus to view containing buffer
                                    ((hash-get helix-context 'editor-set-focus!) maybe-view-id)
                                    ;; Go to end of file by selecting all then collapsing to end
                                    ((hash-get helix-context 'helix.static.select_all))
                                    ((hash-get helix-context 'helix.static.collapse_selection))
                                    ;; Insert the text
                                    ((hash-get helix-context 'helix.static.insert_string) text)
                                    ;; Scroll to show the cursor (newly inserted text)
                                    ((hash-get helix-context 'helix.static.align_view_bottom))
                                    ;; Return to original buffer and mode
                                    ((hash-get helix-context 'editor-set-focus!) original-focus)
                                    ((hash-get helix-context 'editor-set-mode!) original-mode)
                                    ;; Return state unchanged (buffer was valid)
                                    state)))
                  ;; Buffer not visible - clear buffer-id so it will be recreated
                  ;; with correct orientation on next append
                  (nrepl-state (nrepl-state-conn-id state)
                               (nrepl-state-session state)
                               (nrepl-state-address state)
                               (nrepl-state-namespace state)
                               #f ;; Clear buffer-id
                               (nrepl-state-adapter state)
                               (nrepl-state-timeout-ms state)
                               (nrepl-state-orientation state))))))))
