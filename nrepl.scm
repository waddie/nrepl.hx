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

;; Load the steel-nrepl dylib
(#%require-dylib "libsteel_nrepl"
                 (prefix-in ffi. (only-in connect clone-session eval eval-with-timeout close)))

;; Export typed commands
(provide nrepl-connect
         nrepl-disconnect
         nrepl-eval-prompt
         nrepl-eval-selection
         nrepl-eval-buffer
         nrepl-eval-multiple-selections)

;;;; State Management ;;;;

;; Connection state structure
(struct nrepl-state
        (conn-id ; Connection ID (or #f if not connected)
         session ; Session handle (or #f)
         address ; Server address (e.g. "localhost:7888")
         namespace ; Current namespace (from last eval)
         buffer-id)) ; DocumentId of the *nrepl* buffer

;; Global state - using a box for mutability
(define *nrepl-state* (box (nrepl-state #f #f #f "user" #f)))

;; State accessors
(define (get-state)
  (unbox *nrepl-state*))
(define (set-state! new-state)
  (set-box! *nrepl-state* new-state))

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

;;;; Result Processing ;;;;

;;@doc
;; Parse the result string returned from FFI into a hashmap
;; The string is a hash construction call like: (hash 'value "..." 'output (list) ...)
(define (parse-eval-result result-str)
  (eval (read (open-input-string result-str))))

;;@doc
;; Check if a string contains only whitespace
(define (whitespace-only? str)
  (string=? (trim str) ""))

;;;; Error Handling ;;;;

;;@doc
;; Extract the first meaningful line from an error message
(define (take-first-line err-str)
  (let ([lines (split-many err-str "\n")])
    (if (null? lines)
        err-str
        (trim (car lines)))))

;;@doc
;; Simplify Java exception names to user-friendly terms
(define (simplify-exception-name ex-name)
  (cond
    [(string-contains? ex-name "ArityException") "Arity error"]
    [(string-contains? ex-name "ClassCast") "Type error"]
    [(string-contains? ex-name "NullPointer") "Null reference"]
    [(string-contains? ex-name "IllegalArgument") "Invalid argument"]
    [(string-contains? ex-name "RuntimeException") "Runtime error"]
    [(string-contains? ex-name "CompilerException") "Compilation error"]
    [else "Error"]))

;;@doc
;; Extract location info from Clojure error format (file:line:col)
(define (extract-location err-str)
  ;; Look for patterns like "user.clj:15:23" or "at (file.clj:10)"
  ;; Return "line X:Y" or empty string if not found
  (cond
    [(string-contains? err-str ".clj:")
     (let* ([parts (split-many err-str ":")]
            ;; Filter to get numeric parts (line and column numbers)
            [numeric-parts
             (filter (lambda (s) (let ([num (string->number (trim s))]) (and num (> num 0)))) parts)])
       (if (>= (length numeric-parts) 2)
           (string-append "line " (car numeric-parts) ":" (cadr numeric-parts))
           (if (>= (length numeric-parts) 1)
               (string-append "line " (car numeric-parts))
               "")))]
    [else ""]))

;;@doc
;; Extract meaningful description from error message
(define (extract-error-description err-str)
  (cond
    ;; "Unable to resolve symbol: foo"
    [(string-contains? err-str "Unable to resolve")
     (let ([parts (split-many err-str ":")])
       (if (> (length parts) 1)
           (trim (string-join (cdr parts) ":"))
           err-str))]
    ;; "Wrong number of args"
    [(string-contains? err-str "Wrong number") (take-first-line err-str)]
    ;; Default: first line
    [else (take-first-line err-str)]))

;;@doc
;; Transform verbose error messages into concise, single-line format
;; Examples:
;;   "RuntimeException: Unable to resolve symbol: foo"
;;     -> "Runtime error - Unable to resolve symbol: foo"
;;   "Syntax error at (user.clj:15:23)"
;;     -> "Syntax error at line 15:23"
(define (prettify-error-message err-str)
  (cond
    ;; Pattern 1: Exception with colon separator
    [(string-contains? err-str "Exception:")
     (let* ([parts (split-many err-str ":")]
            [exception-type (simplify-exception-name (car parts))]
            [location (extract-location err-str)]
            [description (extract-error-description err-str)]
            [location-part (if (string=? location "")
                               ""
                               (string-append " at " location))])
       (string-append exception-type location-part " - " description))]

    ;; Pattern 2: nREPL transport/connection errors
    [(string-contains? err-str "Connection")
     (cond
       [(string-contains? err-str "refused") "Connection refused - Is nREPL server running?"]
       [(string-contains? err-str "timeout") "Connection timeout - Check address and firewall"]
       [(string-contains? err-str "reset") "Connection lost - Server closed the connection"]
       [else (take-first-line err-str)])]

    ;; Pattern 3: Evaluation timeout
    [(string-contains? err-str "timed out")
     "Evaluation timed out - Expression took too long to execute"]

    ;; Fallback: just take first line and trim
    [else (take-first-line err-str)]))

;;@doc
;; Display a prettified error in the REPL buffer and echo to user
(define (handle-and-display-error err code)
  (let* ([err-msg (error-object-message err)]
         [simplified (prettify-error-message err-msg)]
         [formatted (string-append "=> " code "\n✗ " simplified "\n\n")])
    ;; Append to REPL buffer
    (when (nrepl-state-buffer-id (get-state))
      (append-to-repl-buffer formatted))
    ;; Echo simplified message
    (helix.echo simplified)))

;;@doc
;; Format the evaluation result for display in the REPL buffer
;; Returns a string with output, value, and errors formatted nicely
(define (format-eval-result code result)
  (let ([value (hash-get result 'value)]
        [output (hash-get result 'output)]
        [error (hash-get result 'error)]
        [ns (hash-get result 'ns)])

    ;; Update namespace if present
    (when ns
      (update-namespace! ns))

    ;; Build the output string
    (let ([parts '()]
          [prompt (if (and ns (not (eq? ns #f)))
                      (string-append ns "=> ")
                      "=> ")])
      ;; Add the code that was evaluated with namespace prompt
      (set! parts (cons (string-append prompt code "\n") parts))

      ;; Add any stdout output (skip whitespace-only)
      (when (and output (not (null? output)))
        (for-each (lambda (out)
                    (when (not (whitespace-only? out))
                      (set! parts (cons out parts))))
                  output))

      ;; Add any stderr/error output (skip whitespace-only)
      (when (and error (not (eq? error #f)) (not (whitespace-only? error)))
        (set! parts (cons (string-append "ERROR: " error "\n") parts)))

      ;; Add the result value (skip whitespace-only)
      (when (and value (not (eq? value #f)) (not (whitespace-only? value)))
        (set! parts (cons (string-append value "\n") parts)))

      ;; Add trailing newline to separate responses
      (set! parts (cons "\n" parts))

      ;; Combine all parts in reverse order (since we cons'd them)
      (apply string-append (reverse parts)))))

;;;; Connection Commands ;;;;

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
;; Disconnect from the nREPL server.
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
;; Evaluate code from a prompt.
(define (nrepl-eval-prompt)
  (if (not (connected?))
      (helix.echo "nREPL: Not connected. Use :nrepl-connect first")
      (push-component! (prompt "eval:"
                               (lambda (code)
                                 (let ([session (nrepl-state-session (get-state))]
                                       [trimmed-code (trim code)])
                                   ;; Ensure buffer exists
                                   (when (not (nrepl-state-buffer-id (get-state)))
                                     (create-repl-buffer!))

                                   ;; Evaluate code - result is a hashmap string
                                   (let* ([result-str (ffi.eval session trimmed-code)]
                                          [result (parse-eval-result result-str)]
                                          [formatted (format-eval-result trimmed-code result)])
                                     ;; Append formatted output to buffer
                                     (append-to-repl-buffer formatted)
                                     ;; Echo just the value for quick feedback
                                     (let ([value (hash-get result 'value)])
                                       (when value
                                         (helix.echo value))))))))))

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
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate code - result is a hashmap string
              (let* ([result-str (ffi.eval session trimmed-code)]
                     [result (parse-eval-result result-str)]
                     [formatted (format-eval-result trimmed-code result)])
                ;; Append formatted output to buffer
                (append-to-repl-buffer formatted)
                ;; Echo just the value for quick feedback
                (let ([value (hash-get result 'value)])
                  (when value
                    (helix.echo value)))))))))

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
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate code - result is a hashmap string
              (let* ([result-str (ffi.eval session trimmed-code)]
                     [result (parse-eval-result result-str)]
                     [formatted (format-eval-result trimmed-code result)])
                ;; Append formatted output to buffer
                (append-to-repl-buffer formatted)
                ;; Echo just the value for quick feedback
                (let ([value (hash-get result 'value)])
                  (when value
                    (helix.echo value)))))))))

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
            (let ([session (nrepl-state-session (get-state))])
              ;; Ensure buffer exists
              (when (not (nrepl-state-buffer-id (get-state)))
                (create-repl-buffer!))

              ;; Evaluate each selection
              (for-each (lambda (range)
                          (let* ([from (helix.static.range->from range)]
                                 [to (helix.static.range->to range)]
                                 [code (text.rope->string (text.rope->slice rope from to))]
                                 [trimmed-code (trim code)])
                            (when (not (string=? trimmed-code ""))
                              ;; Evaluate code - result is a hashmap string
                              (let* ([result-str (ffi.eval session trimmed-code)]
                                     [result (parse-eval-result result-str)]
                                     [formatted (format-eval-result trimmed-code result)])
                                ;; Append formatted output to buffer
                                (append-to-repl-buffer formatted)))))
                        ranges)

              ;; Echo count of evaluations
              (helix.echo (string-append "nREPL: Evaluated "
                                         (number->string (length ranges))
                                         " selection(s)")))))))

;;@doc
;; Internal: Append text to the REPL buffer
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
            ;; Scroll to show the cursor (newly inserted text)
            (helix.static.align_view_bottom)
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
      ;; Set language to match the current buffer
      (when language
        (helix.set-language language))
      ;; Store the buffer ID for future use
      (let ([buffer-id (editor->doc-id (editor-focus))])
        (update-buffer-id! buffer-id)
        ;; Add initial content to preserve the buffer
        (helix.static.insert_string ";; nREPL buffer\n")))))
