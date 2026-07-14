;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; lookup-picker.scm - Symbol Lookup Picker Component
;;;
;;; Interactive symbol picker for nREPL lookup: a fuzzy-filtered list of
;;; candidates in a symbol/namespace/type column layout, with a scrolling
;;; documentation preview. Enter inserts the unqualified symbol; Alt-Enter
;;; inserts it namespace-qualified.
;;;
;;; Candidates are fetched from the server's `completions` op as the filter
;;; text changes (debounced), not once up front: servers like babashka return
;;; nothing for the empty prefix, so a single empty-prefix fetch only works on
;;; cider-nrepl. Both the completions fetch and the doc preview use the
;;; non-blocking submit/poll FFI pair so the editor never stalls on a slow
;;; server.
;;;
;;; The list, filter, columns, preview pane and key handling come from
;;; ui-utils.hx's make-picker. This module supplies the fetch-on-type items,
;;; the async memoised doc preview, and the insert actions.

(require-builtin helix/components)
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm") ; enqueue-thread-local-callback-with-delay, fuzzy-match

;; Load the steel-nrepl dylib for async completions and lookup
(#%require-dylib "libsteel_nrepl"
  (prefix-in ffi.
    (only-in submit-completions
      try-get-completions
      submit-lookup
      try-get-lookup)))

(require "format-docs.scm")
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker! picker-refilter!))
(require (only-in "ui-utils.hx/picker-model.scm" picker-column make-string-filter))
(require (only-in "string-utils.scm" parse-ffi-sexp))
(require (only-in "completion-model.scm" candidates->symbols+metadata))

(provide show-lookup-picker)

;;;; Constants ;;;;

(define PREVIEW-SCROLL-WINDOW 20) ; visible height used for the preview scroll clamp
(define MIN-COLUMN-DISPLAY-WIDTH 40) ; below this the ns/type columns collapse
(define NS-COLUMN-WIDTH 20)
(define TYPE-COLUMN-WIDTH 10)
(define COLUMN-SPACING 4)

(define DEBOUNCE-MS 150) ; wait for typing to pause before querying the server
(define POLL-MS 10) ; cadence for polling a submitted request
(define MAX-POLLS 3000) ; stop polling after ~30s (the worker op timeout)

;;;; Fetching candidates (debounced, per filter change) ;;;;

;; Poll for a submitted completions result. Applies the result only when
;; generation `g` is still current (the user has not typed since). Errors
;; (superseded request, closed connection) end the loop via the handler.
(define (poll-completions session req-id g candidates gen state-box-box debug-fn polls)
  (with-handler
    (lambda (err)
      (debug-fn (string-append "completions poll ended: " (to-string err)))
      #f)
    (let ([maybe (ffi.try-get-completions session req-id)])
      (cond
        [maybe
          (if (= g (unbox gen))
            (begin
              (set-box! candidates (candidates->symbols+metadata (parse-ffi-sexp maybe)))
              (debug-fn (string-append
                         "completions arrived: "
                         (to-string (length (car (unbox candidates))))
                         " candidates"))
              ;; Re-run the picker's filter so the new candidates render.
              (let ([sb (unbox state-box-box)])
                (if sb
                  (begin (picker-refilter! (unbox sb)) #t)
                  #t)))
            #t)] ; stale generation: drop the result silently
        [(>= polls MAX-POLLS)
          (debug-fn "completions poll timed out")
          #t]
        [else
          (enqueue-thread-local-callback-with-delay POLL-MS
            (lambda ()
              (poll-completions session req-id g candidates gen state-box-box debug-fn
                (+ polls 1))))
          #t]))))

;; Submit a completions request for `text` and start polling it.
(define (start-completions-fetch session text g candidates gen state-box-box debug-fn)
  (with-handler
    (lambda (err)
      (debug-fn (string-append "completions submit error: " (to-string err)))
      #f)
    (let ([req-id (ffi.submit-completions session text #f #f)])
      (debug-fn (string-append "completions fetch \"" text "\" (request " (to-string req-id) ")"))
      (poll-completions session req-id g candidates gen state-box-box debug-fn 0))))

;; The #:on-filter-change handler: debounce by generation. Each text change
;; bumps `gen`; the delayed thunk only fires the fetch if no newer change
;; arrived during the debounce window.
(define (make-completion-fetcher session candidates gen state-box-box debug-fn)
  (lambda (text)
    (let ([g (+ 1 (unbox gen))])
      (set-box! gen g)
      (enqueue-thread-local-callback-with-delay DEBOUNCE-MS
        (lambda ()
          (if (= g (unbox gen))
            (start-completions-fetch session text g candidates gen state-box-box debug-fn)
            #f))))))

;;;; Metadata columns ;;;;

;; A metadata field for `symbol` from the candidates box, or "" when absent
;; or #f (babashka sends no type, for instance).
(define (meta-field candidates symbol key)
  (let ([metadata (cdr (unbox candidates))])
    (if (hash-contains? metadata symbol)
      (let ([v (hash-ref (hash-ref metadata symbol) key)])
        (if v v ""))
      "")))

(define (symbol-columns candidates)
  (list
    (picker-column "Symbol" 'flex (lambda (s) s))
    (picker-column "Namespace" NS-COLUMN-WIDTH (lambda (s) (meta-field candidates s '#:ns)))
    (picker-column "Type" TYPE-COLUMN-WIDTH (lambda (s) (meta-field candidates s '#:type)))))

;;;; Documentation preview (async, memoised) ;;;;

;; Poll for a submitted lookup result and cache it. On any error (superseded
;; request, closed connection) the pending marker is dropped so revisiting the
;; symbol retries.
(define (poll-lookup session symbol req-id cache debug-fn polls)
  (with-handler
    (lambda (err)
      (debug-fn (string-append "lookup poll ended: " (to-string err)))
      (set-box! cache (hash-remove (unbox cache) symbol))
      #f)
    (let ([maybe (ffi.try-get-lookup session req-id)])
      (cond
        [maybe
          (let ([parsed (parse-ffi-sexp maybe)])
            ;; Cache an empty hash on parse failure: same render as a symbol
            ;; the server has no info for.
            (set-box! cache (hash-insert (unbox cache) symbol (if parsed parsed (hash)))))
          #t]
        [(>= polls MAX-POLLS)
          (set-box! cache (hash-remove (unbox cache) symbol))
          #t]
        [else
          (enqueue-thread-local-callback-with-delay POLL-MS
            (lambda () (poll-lookup session symbol req-id cache debug-fn (+ polls 1))))
          #t]))))

;; Kick off an async lookup for `symbol`, marking it 'pending in the cache.
(define (start-lookup-fetch session symbol cache debug-fn)
  (with-handler
    (lambda (err)
      (debug-fn (string-append "lookup submit error: " (to-string err)))
      (set-box! cache (hash-remove (unbox cache) symbol))
      #f)
    (let ([req-id (ffi.submit-lookup session symbol #f #f)])
      (poll-lookup session symbol req-id cache debug-fn 0))))

;; Preview provider: formatted doc lines for a symbol, or #f while the lookup
;; is in flight (make-picker then shows the missing message). Lookups are
;; memoised per symbol; the info is width-independent and formatting takes the
;; width each render. Only the currently-selected symbol's request survives
;; rapid cursor movement (the FFI is single-flight per connection), and a
;; superseded symbol re-requests when revisited.
(define (make-symbol-preview session debug-fn)
  (let ([cache (box (hash))])
    (lambda (symbol width)
      (let ([c (unbox cache)])
        (if (hash-contains? c symbol)
          (let ([info (hash-ref c symbol)])
            (if (equal? info 'pending)
              #f
              (format-symbol-documentation info width)))
          (begin
            (set-box! cache (hash-insert c symbol 'pending))
            (start-lookup-fetch session symbol cache debug-fn)
            #f))))))

;;;; Insert actions ;;;;

(define (insert-symbol symbol)
  (when symbol (helix.static.insert_string symbol)))

;; Alt-Enter action: insert the symbol namespace-qualified when a namespace is
;; known, else bare.
(define (insert-qualified candidates)
  (lambda (symbol)
    (when symbol
      (let ([ns (meta-field candidates symbol '#:ns)])
        (helix.static.insert_string
          (if (and (string? ns) (not (string=? ns "")))
            (string-append ns "/" symbol)
            symbol))))))

(define (alt-enter? event)
  (and (key-event-enter? event)
    (equal? (key-event-modifier event) key-modifier-alt)))

;;;; Public API ;;;;

;;@doc
;; Show the lookup picker, fetching candidates from the server as the filter
;; text changes. `debug-fn` receives progress/error strings.
(define (show-lookup-picker session debug-fn)
  (let* ([candidates (box (cons (list) (hash)))] ; (cons symbol-list metadata-hash)
         [gen (box 0)] ; fetch generation, bumped per filter change
         [state-box-box (box #f)] ; picker state box, set once shown
         [string-filter (make-string-filter fuzzy-match)]
         ;; Filter over the candidates box, not the (empty) spec items: typing
         ;; narrows the current candidates immediately, and the debounced
         ;; server fetch replaces them shortly after.
         [filter-fn
           (lambda (_items text)
             (let ([all (car (unbox candidates))])
               (if (string=? text "")
                 all
                 (string-filter all text))))])
    (let ([sb (show-picker!
               (make-picker #:name "lookup-picker"
                 #:items
                 (list)
                 #:item-label
                 (lambda (s) s)
                 #:columns
                 (symbol-columns candidates)
                 #:min-display-width
                 MIN-COLUMN-DISPLAY-WIDTH
                 #:column-spacing
                 COLUMN-SPACING
                 #:filter?
                 #t
                 #:filter-fn
                 filter-fn
                 #:on-filter-change
                 (make-completion-fetcher session candidates gen state-box-box debug-fn)
                 #:preview
                 (make-symbol-preview session debug-fn)
                 #:preview-empty
                 "No symbol selected"
                 #:preview-missing
                 "Loading..."
                 #:preview-scroll-window
                 PREVIEW-SCROLL-WINDOW
                 #:preview-scrollbar?
                 #t
                 #:selected-style
                 'theme
                 #:on-accept
                 insert-symbol
                 #:accept-actions
                 (list (cons alt-enter? (insert-qualified candidates)))
                 #:close-mode
                 'pop
                 #:allow-empty?
                 #t
                 #:empty-message
                 "No matching symbols (type to search)"))])
      (set-box! state-box-box sb)
      ;; Initial fetch with the empty prefix: cider-family servers return the
      ;; full symbol list; minimal servers return nothing and the picker
      ;; populates on the first keystroke instead.
      (set-box! gen 1)
      (start-completions-fetch session "" 1 candidates gen state-box-box debug-fn))
    ;; Return void (not the box) so nothing is echoed.
    (if #f #f)))
