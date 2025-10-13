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
(#%require-dylib "libsteel_nrepl"
                 (prefix-in ffi. (only-in connect clone-session eval eval-with-timeout try-get-result close)))

(provide nrepl-state
         nrepl-state?
         nrepl-state-conn-id
         nrepl-state-session
         nrepl-state-address
         nrepl-state-namespace
         nrepl-state-buffer-id
         nrepl-state-adapter
         make-nrepl-state
         nrepl:connect
         nrepl:disconnect
         nrepl:eval-code
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
         adapter) ; Language adapter instance
  #:transparent)

;;@doc
;; Create a new nREPL state with the given adapter
(define (make-nrepl-state adapter)
  (nrepl-state #f #f #f "user" #f adapter))

;;;; Result Processing ;;;;

;;@doc
;; Parse the result string returned from FFI into a hashmap
;; The string is a hash construction call like: (hash 'value "..." 'output (list) ...)
(define (parse-eval-result result-str)
  (eval (read (open-input-string result-str))))

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
                                                  (nrepl-state-adapter state))])
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

                      ;; Reset state (keep adapter and buffer-id)
                      (let ([new-state (nrepl-state #f
                                                    #f
                                                    #f
                                                    "user"
                                                    (nrepl-state-buffer-id state)
                                                    (nrepl-state-adapter state))])
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
         (let* ([adapter (nrepl-state-adapter state)]
                [err-msg (error-object-message err)]
                [prettified (adapter-prettify-error adapter err-msg)]
                [prompt (adapter-format-prompt adapter (nrepl-state-namespace state) code)]
                [commented (let* ([lines (split-many err-msg "\n")]
                                  [comment-prefix (adapter-comment-prefix adapter)]
                                  [commented-lines (map (lambda (line)
                                                          (string-append comment-prefix " " line))
                                                        lines)])
                             (string-join commented-lines "\n"))]
                [formatted (string-append prompt "✗ " prettified "\n" commented "\n\n")])
           (on-error prettified formatted)))
       ;; Submit eval request (non-blocking, returns request ID immediately)
       (let* ([session (nrepl-state-session state)]
              [conn-id (nrepl-state-conn-id state)]
              [req-id (ffi.eval session code)])
         ;; Poll for result using enqueue-thread-local-callback-with-delay (yields to event loop)
         (define (poll-for-result)
           (with-handler
            ;; Catch errors from ffi.try-get-result (e.g., timeout errors)
            (lambda (err)
              (let* ([adapter (nrepl-state-adapter state)]
                     [err-msg (error-object-message err)]
                     [prettified (adapter-prettify-error adapter err-msg)]
                     [prompt (adapter-format-prompt adapter (nrepl-state-namespace state) code)]
                     [commented (let* ([lines (split-many err-msg "\n")]
                                       [comment-prefix (adapter-comment-prefix adapter)]
                                       [commented-lines (map (lambda (line)
                                                               (string-append comment-prefix " " line))
                                                             lines)])
                                  (string-join commented-lines "\n"))]
                     [formatted (string-append prompt "✗ " prettified "\n" commented "\n\n")])
                (on-error prettified formatted)))
            (let ([maybe-result (ffi.try-get-result conn-id req-id)])
              (if maybe-result
                  ;; Result ready - process it
                  (with-handler
                   (lambda (err)
                     (let* ([adapter (nrepl-state-adapter state)]
                            [err-msg (error-object-message err)]
                            [prettified (adapter-prettify-error adapter err-msg)]
                            [prompt (adapter-format-prompt adapter (nrepl-state-namespace state) code)]
                            [commented (let* ([lines (split-many err-msg "\n")]
                                              [comment-prefix (adapter-comment-prefix adapter)]
                                              [commented-lines (map (lambda (line)
                                                                      (string-append comment-prefix " " line))
                                                                    lines)])
                                         (string-join commented-lines "\n"))]
                            [formatted (string-append prompt "✗ " prettified "\n" commented "\n\n")])
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
                                                      (nrepl-state-adapter state))
                                         state)])
                     (on-success new-state formatted)))
                  ;; Result not ready yet - poll again after 10ms
                  (enqueue-thread-local-callback-with-delay 10 poll-for-result)))))
         (poll-for-result)))))

;;;; Buffer Management ;;;;

;;@doc
;; Ensure the *nrepl* buffer exists, creating it if necessary
;;
;; Parameters:
;;   state           - Current nREPL state
;;   helix-context   - Hash with Helix API functions:
;;                     'editor-focus
;;                     'editor->doc-id
;;                     'editor-document->language
;;                     'helix.new
;;                     'set-scratch-buffer-name!
;;                     'helix.set-language
;;                     'helix.static.insert_string
;;   on-success      - Callback: (new-state) -> void
(define (nrepl:ensure-buffer state helix-context on-success)
  (if (nrepl-state-buffer-id state)
      ;; Buffer already exists
      (on-success state)
      ;; Create new buffer
      (nrepl:create-buffer state helix-context on-success)))

;;@doc
;; Create the *nrepl* buffer
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
      (let ([language (editor-document->language original-doc-id)])
        ;; Create new scratch buffer
        ((hash-get helix-context 'helix.new))
        ;; Set the buffer name
        ((hash-get helix-context 'set-scratch-buffer-name!) "*nrepl*")
        ;; Set language to match the current buffer
        (when language
          ((hash-get helix-context 'helix.set-language) language))
        ;; Store the buffer ID for future use
        (let ([buffer-id (editor->doc-id ((hash-get helix-context 'editor-focus)))])
          ;; Add initial content to preserve the buffer
          ((hash-get helix-context 'helix.static.insert_string) ";; nREPL buffer\n")
          (let ([new-state (nrepl-state (nrepl-state-conn-id state)
                                        (nrepl-state-session state)
                                        (nrepl-state-address state)
                                        (nrepl-state-namespace state)
                                        buffer-id
                                        (nrepl-state-adapter state))])
            (on-success new-state)))))))

;;@doc
;; Append text to the REPL buffer
;;
;; Parameters:
;;   state           - Current nREPL state
;;   text            - Text to append
;;   helix-context   - Hash with Helix API functions:
;;                     'editor-focus
;;                     'editor-mode
;;                     'editor->doc-id
;;                     'editor-doc-in-view?
;;                     'editor-set-focus!
;;                     'editor-switch!
;;                     'editor-set-mode!
;;                     'helix.static.select_all
;;                     'helix.static.collapse_selection
;;                     'helix.static.insert_string
;;                     'helix.static.align_view_bottom
(define (nrepl:append-to-buffer state text helix-context)
  (let ([original-focus ((hash-get helix-context 'editor-focus))]
        [original-mode ((hash-get helix-context 'editor-mode))]
        [buffer-id (nrepl-state-buffer-id state)])
    (when buffer-id
      (begin
        ;; Check if buffer is already visible in a view
        (let ([maybe-view-id ((hash-get helix-context 'editor-doc-in-view?) buffer-id)])
          (if maybe-view-id
              ;; Buffer is visible - switch focus to existing view
              ((hash-get helix-context 'editor-set-focus!) maybe-view-id)
              ;; Buffer not visible - temporarily switch to it in current view
              ((hash-get helix-context 'editor-switch!) buffer-id)))
        ;; Go to end of file by selecting all then collapsing to end
        ((hash-get helix-context 'helix.static.select_all))
        ((hash-get helix-context 'helix.static.collapse_selection))
        ;; Insert the text
        ((hash-get helix-context 'helix.static.insert_string) text)
        ;; Scroll to show the cursor (newly inserted text)
        ((hash-get helix-context 'helix.static.align_view_bottom))
        ;; Return to original buffer and mode
        ((hash-get helix-context 'editor-set-focus!) original-focus)
        ((hash-get helix-context 'editor-set-mode!) original-mode)))))
