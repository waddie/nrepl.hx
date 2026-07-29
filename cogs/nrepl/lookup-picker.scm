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
;;; The filter takes Helix's `%name pattern` column query: bare text matches
;;; and ranks the symbol, `%n clojure.string` narrows to a namespace, `%t
;;; macro` to a type.
;;;
;;; Candidates are fetched from the server's `completions` op as the filter
;;; text changes (debounced), not once up front: servers like babashka return
;;; nothing for the empty prefix, so a single empty-prefix fetch only works on
;;; cider-nrepl. Only the symbol pattern goes to the server; the namespace and
;;; type patterns narrow what came back. Both the completions fetch and the doc
;;; preview use the non-blocking submit/poll FFI pair so the editor never stalls
;;; on a slow server.
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
(require (only-in "ui-utils.hx/picker-model.scm"
          picker-column
          column-label
          make-column-filter))
(require (only-in "string-utils.scm" parse-ffi-sexp))
(require (only-in "completion-model.scm"
          candidates->symbols+metadata
          query->completion-prefix
          poll-delay-for))

(provide show-lookup-picker)

;;;; Constants ;;;;

(define PREVIEW-SCROLL-WINDOW 20) ; visible height used for the preview scroll clamp
(define MIN-COLUMN-DISPLAY-WIDTH 40) ; below this the ns/type columns collapse
(define NS-COLUMN-WIDTH 20)
(define TYPE-COLUMN-WIDTH 10)
(define COLUMN-SPACING 4)
(define PRIMARY-COLUMN 0) ; Symbol: what bare filter text matches and ranks by

(define DEBOUNCE-MS 150) ; wait for typing to pause before querying the server
(define POLL-TIMEOUT-MS 30000) ; total polling budget (the worker op timeout)

;;;; Async polling ;;;;

;; Generic submit/poll driver: poll try-get until it yields a result, the
;; time budget runs out, or it raises. Delay backs off via poll-delay-for.
;; on-result/on-timeout run once; on-error receives the raised error.
(define (poll-request try-get on-result on-timeout on-error elapsed)
  (with-handler
    (lambda (err) (on-error err) #f)
    (let ([maybe (try-get)])
      (cond
        [maybe (on-result maybe)]
        [(>= elapsed POLL-TIMEOUT-MS) (on-timeout)]
        [else
          (let ([delay (poll-delay-for elapsed)])
            (enqueue-thread-local-callback-with-delay delay
              (lambda ()
                (poll-request try-get on-result on-timeout on-error (+ elapsed delay))))
            #t)]))))

;;;; Insert actions ;;;;

(define (insert-symbol symbol)
  (when symbol (helix.static.insert_string symbol)))

(define (alt-enter? event)
  (and (key-event-enter? event)
    (equal? (key-event-modifier event) key-modifier-alt)))

;;;; Public API ;;;;

;;@doc
;; Show the lookup picker, fetching candidates from the server as the filter
;; text changes. `debug-fn` receives progress/error strings.
(define (show-lookup-picker session debug-fn)
  (let ([symbols (box (list))]
        [metadata (box (hash))]
        [gen (box 0)] ; fetch generation, bumped per filter change
        [picker-state (box #f)] ; holds show-picker!'s state box, set once shown
        [preview-cache (box (hash))]
        [last-prefix (box #f)]) ; symbol pattern last fetched (#f: none yet)

    ;; A metadata field for `symbol`, or "" when absent or #f (babashka sends
    ;; no type, for instance).
    (define (meta-field symbol key)
      (let ([m (unbox metadata)])
        (if (hash-contains? m symbol)
          (let ([v (hash-ref (hash-ref m symbol) key)])
            (if v v ""))
          "")))

    ;; Bound once: the columns are both the layout and the filter's vocabulary,
    ;; and their accessors close over meta-field.
    (define columns
      (list
        (picker-column "Symbol" 'flex (lambda (s) s))
        (picker-column "Namespace" NS-COLUMN-WIDTH (lambda (s) (meta-field s '#:ns)))
        (picker-column "Type" TYPE-COLUMN-WIDTH (lambda (s) (meta-field s '#:type)))))
    (define column-names (map column-label columns))
    (define primary-name (list-ref column-names PRIMARY-COLUMN))
    (define column-filter (make-column-filter fuzzy-match columns PRIMARY-COLUMN))

    ;; Apply a completions result if generation `g` is still current (the
    ;; user has not typed since), then re-run the picker's filter.
    (define (apply-completions maybe g)
      (if (= g (unbox gen))
        (let ([parsed (candidates->symbols+metadata (parse-ffi-sexp maybe))])
          (set-box! symbols (car parsed))
          (set-box! metadata (cdr parsed))
          (debug-fn (string-append "completions arrived: "
                     (to-string (length (unbox symbols)))
                     " candidates"))
          (let ([sb (unbox picker-state)])
            (if sb
              (begin (picker-refilter! (unbox sb)) #t)
              #t)))
        #t)) ; stale generation: drop the result silently

    (define (start-completions-fetch text g)
      (with-handler
        (lambda (err)
          (debug-fn (string-append "completions submit error: " (to-string err)))
          ;; Forget the prefix so retyping it retries rather than being
          ;; skipped as already fetched.
          (set-box! last-prefix #f)
          #f)
        (let ([req-id (ffi.submit-completions session text #f #f)])
          (debug-fn (string-append "completions fetch \"" text
                     "\" (request "
                     (to-string req-id)
                     ")"))
          (poll-request
            (lambda () (ffi.try-get-completions session req-id))
            (lambda (maybe) (apply-completions maybe g))
            (lambda ()
              (debug-fn "completions poll timed out")
              (set-box! last-prefix #f)
              #t)
            (lambda (err)
              (debug-fn (string-append "completions poll ended: " (to-string err))))
            0))))

    ;; The #:on-filter-change handler: fetch on the symbol pattern alone,
    ;; debounced by generation. A keystroke that only moves the namespace or
    ;; type pattern leaves the generation alone rather than fetching an
    ;; unchanged prefix: bumping it would strand an in-flight fetch that is
    ;; never reissued, emptying the list.
    (define (on-filter-change text)
      (let ([prefix (query->completion-prefix text column-names primary-name)])
        (if (equal? prefix (unbox last-prefix))
          void
          (let ([g (+ 1 (unbox gen))])
            (set-box! gen g)
            (set-box! last-prefix prefix)
            (enqueue-thread-local-callback-with-delay DEBOUNCE-MS
              (lambda ()
                (if (= g (unbox gen))
                  (start-completions-fetch prefix g)
                  #f)))))))

    ;; Kick off an async doc lookup for `symbol`, marked 'pending in the cache.
    (define (start-lookup-fetch symbol)
      (with-handler
        (lambda (err)
          (debug-fn (string-append "lookup submit error: " (to-string err)))
          (set-box! preview-cache (hash-remove (unbox preview-cache) symbol))
          #f)
        (let ([req-id (ffi.submit-lookup session symbol #f #f)])
          (poll-request
            (lambda () (ffi.try-get-lookup session req-id))
            (lambda (maybe)
              (let ([parsed (parse-ffi-sexp maybe)])
                ;; Cache an empty hash on parse failure: same render as a
                ;; symbol the server has no info for.
                (set-box! preview-cache
                  (hash-insert (unbox preview-cache) symbol (if parsed parsed (hash)))))
              #t)
            (lambda ()
              ;; Negative-cache the timeout: stops the preview re-submitting
              ;; a lookup that never answers.
              (set-box! preview-cache (hash-insert (unbox preview-cache) symbol (hash)))
              #t)
            (lambda (err)
              ;; Errors (superseded request, closed connection) drop the
              ;; marker so revisiting the symbol retries.
              (debug-fn (string-append "lookup poll ended: " (to-string err)))
              (set-box! preview-cache (hash-remove (unbox preview-cache) symbol)))
            0))))

    ;; Preview provider: formatted doc lines, or #f while the lookup is in
    ;; flight (make-picker then shows the missing message). Memoised per
    ;; symbol; formatting takes the width each render.
    (define (symbol-preview symbol width)
      (let ([c (unbox preview-cache)])
        (if (hash-contains? c symbol)
          (let ([info (hash-ref c symbol)])
            (if (equal? info 'pending)
              #f
              (format-symbol-documentation info width)))
          (begin
            (set-box! preview-cache (hash-insert c symbol 'pending))
            (start-lookup-fetch symbol)
            #f))))

    ;; Alt-Enter action: insert namespace-qualified when a namespace is known.
    (define (insert-qualified symbol)
      (when symbol
        (let ([ns (meta-field symbol '#:ns)])
          (helix.static.insert_string
            (if (and (string? ns) (not (string=? ns "")))
              (string-append ns "/" symbol)
              symbol)))))

    ;; Filter over the symbols box, not the (empty) spec items: typing narrows
    ;; the current candidates immediately, and the debounced server fetch
    ;; replaces them shortly after. That box is why the column filter is built
    ;; here rather than asked for with #:filter-columns?, which a supplied
    ;; #:filter-fn overrides and so would read as config that does nothing.
    (define (filter-fn _items text)
      (column-filter (unbox symbols) text))

    (let ([sb (show-picker!
               (make-picker #:name "lookup-picker"
                 #:items
                 (list)
                 #:item-label
                 (lambda (s) s)
                 #:columns
                 columns
                 #:min-display-width
                 MIN-COLUMN-DISPLAY-WIDTH
                 #:column-spacing
                 COLUMN-SPACING
                 #:filter?
                 #t
                 #:filter-fn
                 filter-fn
                 #:on-filter-change
                 on-filter-change
                 #:preview
                 symbol-preview
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
                 #:instructions
                 "%n / %t: filter a column   Alt-Enter: qualified   Esc: cancel"
                 #:on-accept
                 insert-symbol
                 #:accept-actions
                 (list (cons alt-enter? insert-qualified))
                 #:close-mode
                 'pop
                 #:allow-empty?
                 #t
                 ;; The prompt belongs to the unfiltered state only: once a
                 ;; prefix is typed, "type to search" is advice already taken,
                 ;; and the empty body means that prefix matched nothing.
                 #:empty-message
                 "No matching symbols (type to search)"
                 #:no-match-message
                 "No matching symbols"))])
      (set-box! picker-state sb)
      ;; Initial fetch with the empty prefix: cider-family servers return the
      ;; full symbol list; minimal servers return nothing and the picker
      ;; populates on the first keystroke instead. Kept unconditional: there
      ;; is no reliable capability signal (babashka advertises completions),
      ;; and with backoff the cost is one round-trip per open.
      (set-box! gen 1)
      (set-box! last-prefix "")
      (start-completions-fetch "" 1))
    ;; Return void (not the box) so nothing is echoed.
    (if #f #f)))
