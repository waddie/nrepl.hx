;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; lookup-picker.scm - Symbol Lookup Picker Component
;;;
;;; Interactive symbol picker for nREPL lookup: a fuzzy-filtered list of the
;;; session's symbols in a symbol/namespace/type column layout, with a scrolling
;;; documentation preview. Enter inserts the unqualified symbol; Alt-Enter
;;; inserts it namespace-qualified.
;;;
;;; The list, filter, columns, preview pane and key handling come from
;;; ui-utils.hx's make-picker. This module supplies the symbol metadata columns,
;;; the memoised doc preview (over the nREPL FFI), and the insert actions.

(require-builtin helix/components)
(require (prefix-in helix.static. "helix/static.scm"))

;; Load the steel-nrepl dylib for completions and lookup
(#%require-dylib "libsteel_nrepl" (prefix-in ffi. (only-in completions lookup)))

(require "format-docs.scm")
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker!))
(require (only-in "ui-utils.hx/picker-model.scm" picker-column))
(require (only-in "string-utils.scm" eval-string))

(provide show-lookup-picker)

;;;; Constants ;;;;

(define PREVIEW-SCROLL-WINDOW 20) ; visible height used for the preview scroll clamp
(define MIN-COLUMN-DISPLAY-WIDTH 40) ; below this the ns/type columns collapse
(define NS-COLUMN-WIDTH 20)
(define TYPE-COLUMN-WIDTH 10)
(define COLUMN-SPACING 4)

;;;; Fetching the symbol list ;;;;

(define (fetch-symbol-list session debug-fn)
  "Fetch completions for empty prefix to get all symbols with metadata.
   Returns: (cons symbol-list metadata-hash)
   where symbol-list is (list string ...) and
   metadata-hash is (hash symbol-string -> hash)"
  (with-handler
    (lambda (err)
      (debug-fn (string-append "Error in fetch-symbol-list: " (to-string err)))
      (cons (list) (hash))) ; Return empty list and hash on error
    (begin
      (debug-fn (string-append "Calling ffi.completions"))
      (let* ([completions-str (ffi.completions session "" #f #f)])
        (debug-fn (string-append
                   "Completions string (length "
                   (to-string (string-length completions-str))
                   "): "
                   (substring completions-str 0 (min 100 (string-length completions-str)))))
        (let ([completions-list (eval-string completions-str)])
          (debug-fn (string-append "Parsed list type: "
                     (if (list? completions-list) "list" "not-list")
                     ", length: "
                     (if (list? completions-list)
                       (to-string (length completions-list))
                       "N/A")))
          (if (and (list? completions-list) (not (null? completions-list)))
            ;; Parse structured completion data
            (let loop ([remaining completions-list]
                       [symbols (list)]
                       [metadata (hash)])
              (if (null? remaining)
                (cons (reverse symbols) metadata)
                (let* ([item (car remaining)]
                       [candidate (if (hash? item)
                                   (hash-ref item '#:candidate)
                                   item)]) ; Fallback for old format
                  (if (hash? item)
                    ;; New structured format - extract metadata
                    (loop (cdr remaining)
                      (cons candidate symbols)
                      (hash-insert
                        metadata
                        candidate
                        (hash '#:ns (hash-ref item '#:ns) '#:type (hash-ref item '#:type))))
                    ;; Old format - just symbol string
                    (loop (cdr remaining) (cons candidate symbols) metadata)))))
            (cons (list) (hash)))))))) ; Return empty on error

;;;; Metadata columns ;;;;

;; A metadata field for `symbol`, or "" when absent or #f.
(define (meta-field metadata symbol key)
  (if (hash-contains? metadata symbol)
    (let ([v (hash-ref (hash-ref metadata symbol) key)])
      (if v v ""))
    ""))

(define (symbol-columns metadata)
  (list
    (picker-column "Symbol" 'flex (lambda (s) s))
    (picker-column "Namespace" NS-COLUMN-WIDTH (lambda (s) (meta-field metadata s '#:ns)))
    (picker-column "Type" TYPE-COLUMN-WIDTH (lambda (s) (meta-field metadata s '#:type)))))

;;;; Documentation preview ;;;;

;; Look a symbol up over the FFI, returning parsed info or #f on error.
(define (fetch-symbol-info session symbol)
  (with-handler (lambda (err) #f)
    (eval-string (ffi.lookup session symbol #f #f))))

;; Memoise lookups per symbol (the info is width-independent; formatting takes
;; the width each render). Caches #f too, since a symbol's info does not change
;; while the picker is open.
(define (cached-info cache session symbol)
  (let ([c (unbox cache)])
    (if (hash-contains? c symbol)
      (hash-ref c symbol)
      (let ([info (fetch-symbol-info session symbol)])
        (set-box! cache (hash-insert c symbol info))
        info))))

;; Preview provider: formatted doc lines for a symbol, or #f while unavailable
;; (make-picker then shows the missing message).
(define (make-symbol-preview session)
  (let ([cache (box (hash))])
    (lambda (symbol width)
      (let ([info (cached-info cache session symbol)])
        (if info
          (format-symbol-documentation info width)
          #f)))))

;;;; Insert actions ;;;;

(define (insert-symbol symbol)
  (when symbol (helix.static.insert_string symbol)))

;; Alt-Enter action: insert the symbol namespace-qualified when a namespace is
;; known, else bare.
(define (insert-qualified metadata)
  (lambda (symbol)
    (when symbol
      (let ([ns (meta-field metadata symbol '#:ns)])
        (helix.static.insert_string
          (if (and (string? ns) (not (string=? ns "")))
            (string-append ns "/" symbol)
            symbol))))))

(define (alt-enter? event)
  (and (key-event-enter? event)
    (equal? (key-event-modifier event) key-modifier-alt)))

;;;; Public API ;;;;

;;@doc
;; Fetch the session's symbols and show the lookup picker. `debug-fn` receives
;; progress/error strings during the fetch.
(define (show-lookup-picker session debug-fn)
  (let* ([result (fetch-symbol-list session debug-fn)]
         [symbols (car result)]
         [metadata (cdr result)])
    (show-picker!
      (make-picker #:name "lookup-picker"
        #:items
        symbols
        #:item-label
        (lambda (s) s)
        #:columns
        (symbol-columns metadata)
        #:min-display-width
        MIN-COLUMN-DISPLAY-WIDTH
        #:column-spacing
        COLUMN-SPACING
        #:filter?
        #t
        #:preview
        (make-symbol-preview session)
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
        (list (cons alt-enter? (insert-qualified metadata)))
        #:close-mode
        'pop
        #:empty-message
        "No symbols found. Ensure cider-nrepl middleware is loaded."))
    ;; Return void (not the box) so nothing is echoed.
    (if #f #f)))
