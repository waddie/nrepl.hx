;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; lookup-picker.scm - Symbol Lookup Picker Component
;;;
;;; Interactive symbol picker for nREPL lookup. Displays a list of symbols,
;;; allows navigation, shows preview information, and inserts selected symbol.

(require-builtin helix/components)
(require-builtin steel/ports)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm")

;; Load the steel-nrepl dylib for completions and lookup
(#%require-dylib "libsteel_nrepl" (prefix-in ffi. (only-in completions lookup)))

(require "cogs/nrepl/format-docs.scm")
(require "cogs/nrepl/ui-utils.scm")
(require "cogs/nrepl/string-utils.scm")
(require "cogs/nrepl/picker-utils.scm")

(provide show-lookup-picker)

;;;; Constants ;;;;

;; Picker-specific constants (common ones imported from picker-utils)
(define PREVIEW_SCROLL_HEIGHT 20) ; Visible height for max-scroll calculation

;; Column layout
(define MIN_COLUMN_DISPLAY_WIDTH 40) ; Minimum width to show all columns
(define COLUMN_TYPE_WIDTH 10)
(define COLUMN_NS_WIDTH 20)
(define COLUMN_SPACING 4)

;;;; Component State Structure ;;;;

;; State structure with symbol metadata (namespace, type)
(struct LookupPickerState
        (session ; NReplSession - nREPL session object
         symbols ; (list string) - ORIGINAL full symbol list (immutable)
         filtered-symbols ; (list string) - Current filtered view
         selected-index ; usize - Currently selected index into filtered-symbols
         scroll-offset ; usize - For scrolling long lists
         cache ; (hash string -> hash) - Symbol lookup cache
         preview-scroll ; usize - Scroll offset for preview pane
         filter-text ; string - User's filter input
         metadata ; (hash string -> hash) - Symbol metadata (ns, type)
         preview-width) ; usize - Current preview pane width for formatting
  #:transparent)

(define (make-lookup-picker-state session symbols metadata)
  (LookupPickerState session
                     symbols ; Original full list
                     symbols ; Initially, filtered = full list
                     0 ; selected-index starts at 0
                     0 ; scroll-offset starts at 0
                     (hash) ; empty cache
                     0 ; preview-scroll starts at 0
                     "" ; empty filter text
                     metadata ; symbol metadata
                     60)) ; default preview-width (conservative)

;;;; Fetching Symbol List ;;;;

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

(define (apply-filter state new-filter)
  "Filter symbols by substring match (case-insensitive) and return new state
   Note: For very large symbol sets (>10k), consider debouncing or incremental filtering"
  (let* ([all-symbols (LookupPickerState-symbols state)]
         [filtered (if (string=? new-filter "")
                       all-symbols
                       (filter (lambda (sym) (string-contains-ci? sym new-filter)) all-symbols))])

    (LookupPickerState (LookupPickerState-session state)
                       (LookupPickerState-symbols state) ; Keep original list
                       filtered ; Updated filtered view
                       0 ; Reset selected-index to first
                       0 ; Reset scroll-offset to top
                       (LookupPickerState-cache state) ; Preserve cache
                       0 ; Reset preview scroll
                       new-filter ; Update filter text
                       (LookupPickerState-metadata state) ; Preserve metadata
                       (LookupPickerState-preview-width state)))) ; Preserve preview width

;;;; Symbol Info Caching ;;;;

(define (get-selected-symbol state)
  "Get currently selected symbol name from filtered list"
  (let* ([filtered (LookupPickerState-filtered-symbols state)] ; Use filtered list
         [index (LookupPickerState-selected-index state)])
    (if (and (>= index 0) (< index (length filtered)))
        (list-ref filtered index)
        #f)))

(define (get-symbol-info-cached state symbol)
  "Get symbol info from cache, or fetch if not cached"
  (let ([cache (LookupPickerState-cache state)])
    (if (hash-contains? cache symbol)
        (hash-ref cache symbol)
        (fetch-symbol-info state symbol))))

(define (fetch-symbol-info state symbol)
  "Fetch symbol info from nREPL server"
  (with-handler (lambda (err) #f) ; Return #f on error
                (let* ([session (LookupPickerState-session state)]
                       [lookup-str (ffi.lookup session symbol #f #f)])
                  ;; Parse lookup result
                  (eval-string lookup-str))))

;;;; Rendering Functions ;;;;

(define (render-lookup-picker state rect buffer)
  "Render the lookup picker component with filter bar"
  (let* ([overlay-area (apply-overlay-transform rect)]
         [overlay-width (area-width overlay-area)]
         [overlay-height (area-height overlay-area)]
         [overlay-x (area-x overlay-area)]
         [overlay-y (area-y overlay-area)]
         [show-preview (> overlay-width MIN_AREA_WIDTH_FOR_PREVIEW)]

         [picker-width (if show-preview
                           (quotient overlay-width 2)
                           overlay-width)]
         [picker-area (area overlay-x overlay-y picker-width overlay-height)]
         [preview-area (if show-preview
                           (area (+ overlay-x picker-width)
                                 overlay-y
                                 (- overlay-width picker-width)
                                 overlay-height)
                           #f)])

    (buffer/clear buffer overlay-area)

    ;; Draw borders
    (let ([border-style (make-block (theme->bg *helix.cx*) (theme->bg *helix.cx*) "all" "plain")])
      (block/render buffer picker-area border-style)
      (when show-preview
        (block/render buffer preview-area border-style)))

    (let* ([picker-content-x (+ overlay-x 2)]
           [picker-content-y (+ overlay-y 1)]
           [picker-content-width (- picker-width 4)]
           [picker-content-height (- overlay-height 2)]
           [preview-content-x (if show-preview
                                  (+ overlay-x picker-width 2)
                                  0)]
           [preview-content-y (if show-preview
                                  (+ overlay-y 1)
                                  0)]
           [preview-content-width (if show-preview
                                      (- (- overlay-width picker-width) 4)
                                      0)]
           [preview-content-height (if show-preview
                                       (- overlay-height 2)
                                       0)]
           [filter-y picker-content-y]
           [separator-y (+ picker-content-y 1)]
           [header-y (+ picker-content-y 2)]
           [list-y (+ picker-content-y 3)]
           [list-height (- picker-content-height 3)]) ; Filter + separator + header

      ;; Draw filter bar (top line of picker pane)
      (draw-filter-bar buffer
                       picker-content-x
                       filter-y
                       picker-content-width
                       (LookupPickerState-filter-text state)
                       (length (LookupPickerState-filtered-symbols state))
                       (length (LookupPickerState-symbols state)))

      ;; Draw horizontal separator line under filter
      (frame-set-string! buffer
                         picker-content-x
                         separator-y
                         (make-string picker-content-width #\─)
                         (style))

      ;; Draw column header
      (draw-column-header buffer picker-content-x header-y picker-content-width)

      ;; Draw symbol list in picker content area
      (draw-symbol-list buffer picker-content-x list-y picker-content-width list-height state)

      ;; Draw preview in preview content area (if shown)
      (when show-preview
        (draw-preview buffer
                      preview-content-x
                      preview-content-y
                      preview-content-width
                      preview-content-height
                      state
                      (get-selected-symbol state))))))

(define (draw-symbol-list buffer x y width height state)
  "Draw scrollable list of symbols with columns (symbol, namespace, type)"
  (let* ([symbols (LookupPickerState-filtered-symbols state)]
         [metadata (LookupPickerState-metadata state)]
         [selected (LookupPickerState-selected-index state)]
         [scroll (LookupPickerState-scroll-offset state)]
         [visible-count (min height (length symbols))]
         [start-index scroll]
         [end-index (min (+ start-index visible-count) (length symbols))]
         ;; Column widths - adjust based on available space with bounds checking
         [type-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_TYPE_WIDTH)]
         [ns-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_NS_WIDTH)]
         [spacing (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_SPACING)]
         [symbol-width (max 10 (- width type-width ns-width spacing))])

    (let loop ([i start-index])
      (when (< i end-index)
        (let* ([symbol (list-ref symbols i)]
               [symbol-meta (if (hash-contains? metadata symbol)
                                (hash-ref metadata symbol)
                                (hash '#:ns #f '#:type #f))]
               [ns (let ([ns-val (hash-ref symbol-meta '#:ns)])
                     (if (or (not ns-val) (equal? ns-val #f)) "" ns-val))]
               [sym-type (let ([type-val (hash-ref symbol-meta '#:type)])
                           (if (or (not type-val) (equal? type-val #f)) "" type-val))]
               [row (+ y (- i scroll))]
               [is-selected (= i selected)]
               [style-obj (if is-selected
                              (theme-scope *helix.cx* "ui.menu.selected")
                              (style))]
               ;; Build column display
               [prefix (if is-selected "> " "  ")]
               [symbol-col (truncate-string symbol (- symbol-width 2))]
               [ns-col (truncate-string ns ns-width)]
               [type-col (truncate-string sym-type type-width)]
               ;; Pad columns to fixed width for alignment
               [symbol-padded
                (string-append symbol-col
                               (make-string (max 0 (- symbol-width (string-length symbol-col) 2))
                                            #\space))]
               [ns-padded (string-append ns-col
                                         (make-string (max 0 (- ns-width (string-length ns-col)))
                                                      #\space))]
               [display-text (string-append prefix symbol-padded " " ns-padded " " type-col)])

          (frame-set-string! buffer x row (truncate-string display-text width) style-obj)
          (loop (+ i 1)))))))

(define (draw-preview buffer x y width height state selected-symbol)
  "Draw preview pane with symbol info"
  (if selected-symbol
      (let ([info (get-symbol-info-cached state selected-symbol)])
        (if info
            (draw-symbol-info buffer x y width height info state)
            (frame-set-string! buffer x y "Loading..." (style))))
      (frame-set-string! buffer x y "No symbol selected" (style-fg (style) Color/Gray))))

(define (draw-symbol-info buffer x y width height info state)
  "Draw symbol information in preview pane with scrolling"
  ;; Phase 2: Full documentation with scrolling
  (let* ([formatted-lines (format-symbol-documentation info width)]
         [scroll (LookupPickerState-preview-scroll state)]
         [visible-count (min height (length formatted-lines))]
         [start-line scroll]
         [end-line (min (+ start-line visible-count) (length formatted-lines))])

    ;; Draw visible lines
    (let loop ([i start-line])
      (when (< i end-line)
        (let* ([line-data (list-ref formatted-lines i)]
               [text (car line-data)]
               [style-obj (cdr line-data)]
               [row (+ y (- i scroll))])
          (frame-set-string! buffer x row text style-obj)
          (loop (+ i 1)))))

    ;; Draw scroll indicator if needed
    (when (> (length formatted-lines) height)
      (draw-scroll-indicator buffer
                             (+ x width)
                             y
                             height
                             scroll
                             (length formatted-lines)
                             visible-count))))

(define (draw-scroll-indicator buffer x y height scroll total visible)
  "Draw scrollbar on right edge of preview pane"
  (let* ([scrollbar-height (max 1 (quotient (* height visible) total))]
         [scrollbar-pos (quotient (* scroll height) total)]
         [style-obj (style-fg (style) Color/Gray)])

    ;; Draw track
    (let loop ([i 0])
      (when (< i height)
        (frame-set-string! buffer x (+ y i) "│" style-obj)
        (loop (+ i 1))))

    ;; Draw thumb
    (let loop ([i scrollbar-pos])
      (when (< i (min height (+ scrollbar-pos scrollbar-height)))
        (frame-set-string! buffer x (+ y i) "█" (style-fg (style) Color/Blue))
        (loop (+ i 1))))))

(define (draw-column-header buffer x y width)
  "Draw fixed column header row"
  (let* ([type-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_TYPE_WIDTH)]
         [ns-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_NS_WIDTH)]
         [spacing (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_SPACING)]
         [symbol-width (max 10 (- width type-width ns-width spacing))]
         [prefix "  "]
         ;; Pad headers to match column widths
         [symbol-header (if (> symbol-width 6)
                            (string-append "Symbol"
                                           (make-string (max 0 (- symbol-width 6 2)) #\space))
                            "Symbol")]
         [ns-header (if (> ns-width 0)
                        (string-append "Namespace" (make-string (max 0 (- ns-width 9)) #\space))
                        "")]
         [type-header (if (> type-width 0) "Type" "")]
         [header-parts (filter (lambda (s) (not (string=? s "")))
                               (list symbol-header ns-header type-header))]
         [header-text (string-append prefix
                                     (apply string-append
                                            (map (lambda (part)
                                                   (if (string=? part (car (reverse header-parts)))
                                                       part
                                                       (string-append part " ")))
                                                 header-parts)))]
         [header-style (style)])

    (frame-set-string! buffer x y (truncate-string header-text width) header-style)))

;;;; Event Handling ;;;;

(define (handle-lookup-event state-box event)
  "Handle keyboard events for picker"
  (cond
    ;; Close on Escape
    [(key-event-escape? event)
     (pop-last-component-by-name! "lookup-picker")
     event-result/consume]

    ;; Close on Ctrl-c
    [(and (equal? (key-event-modifier event) key-modifier-ctrl) (equal? (key-event-char event) #\c))
     (pop-last-component-by-name! "lookup-picker")
     event-result/consume]

    ;; Backspace removes last character from filter
    [(key-event-backspace? event)
     (let* ([state (unbox state-box)]
            [filter (LookupPickerState-filter-text state)]
            [len (string-length filter)])
       (when (> len 0)
         (let ([new-filter (substring filter 0 (- len 1))])
           (set-box! state-box (apply-filter state new-filter)))))
     event-result/consume]

    ;; Scroll preview up (Shift+Up)
    [(and (key-event-up? event) (equal? (key-event-modifier event) key-modifier-shift))
     (scroll-preview state-box -1)
     event-result/consume]

    ;; Scroll preview down (Shift+Down)
    [(and (key-event-down? event) (equal? (key-event-modifier event) key-modifier-shift))
     (scroll-preview state-box 1)
     event-result/consume]

    ;; Navigate up: Up, Ctrl-p, Shift-Tab
    [(or (key-event-up? event)
         (and (equal? (key-event-modifier event) key-modifier-ctrl)
              (equal? (key-event-char event) #\p))
         (and (key-event-tab? event) (equal? (key-event-modifier event) key-modifier-shift)))
     (move-selection state-box -1)
     event-result/consume]

    ;; Navigate down: Down, Ctrl-n, Tab (without modifier)
    [(or (key-event-down? event)
         (and (equal? (key-event-modifier event) key-modifier-ctrl)
              (equal? (key-event-char event) #\n))
         (and (key-event-tab? event) (not (key-event-modifier event))))
     (move-selection state-box 1)
     event-result/consume]

    ;; Page up in symbol list: Ctrl-u
    [(and (equal? (key-event-modifier event) key-modifier-ctrl) (equal? (key-event-char event) #\u))
     (move-page state-box -1)
     event-result/consume]

    ;; Page down in symbol list: Ctrl-d
    [(and (equal? (key-event-modifier event) key-modifier-ctrl) (equal? (key-event-char event) #\d))
     (move-page state-box 1)
     event-result/consume]

    ;; Page up in preview: PageUp
    [(key-event-page-up? event)
     (scroll-preview state-box (- PREVIEW_SCROLL_DELTA))
     event-result/consume]

    ;; Page down in preview: PageDown
    [(key-event-page-down? event)
     (scroll-preview state-box PREVIEW_SCROLL_DELTA)
     event-result/consume]

    ;; Go to first: Home
    [(key-event-home? event)
     (move-to-boundary state-box 'first)
     event-result/consume]

    ;; Go to last: End
    [(key-event-end? event)
     (move-to-boundary state-box 'last)
     event-result/consume]

    ;; Insert qualified symbol on Alt+Enter
    [(and (key-event-enter? event) (equal? (key-event-modifier event) key-modifier-alt))
     (insert-selected-symbol (unbox state-box) #t)
     (pop-last-component-by-name! "lookup-picker")
     event-result/consume]

    ;; Insert unqualified symbol on Enter
    [(key-event-enter? event)
     (insert-selected-symbol (unbox state-box) #f)
     (pop-last-component-by-name! "lookup-picker")
     event-result/consume]

    ;; Type to filter - any remaining character events
    [else
     (let ([ch (key-event-char event)])
       (when ch
         (let* ([state (unbox state-box)]
                [current-filter (LookupPickerState-filter-text state)]
                [new-filter (string-append current-filter (string ch))])
           (set-box! state-box (apply-filter state new-filter)))))
     event-result/consume]))

(define (move-selection state-box delta)
  "Move selection by delta (-1 for up, +1 for down) with wrapping"
  (let* ([state (unbox state-box)]
         [filtered (LookupPickerState-filtered-symbols state)] ; Use filtered list
         [count (length filtered)]
         [current (LookupPickerState-selected-index state)]
         [next (+ current delta)]
         ;; Wrap around: if next < 0, wrap to end; if next >= count, wrap to start
         [new-index (cond
                      [(< next 0) (- count 1)]
                      [(>= next count) 0]
                      [else next])])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 (LookupPickerState-filtered-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0 ; Reset preview scroll
                                 (LookupPickerState-filter-text state)
                                 (LookupPickerState-metadata state) ; Preserve metadata
                                 (LookupPickerState-preview-width state)))))

(define (move-page state-box direction)
  "Move selection by one page (direction: -1 up, 1 down)"
  (let* ([state (unbox state-box)]
         [filtered (LookupPickerState-filtered-symbols state)] ; Use filtered list
         [count (length filtered)]
         [current (LookupPickerState-selected-index state)]
         [new-index (max 0 (min (- count 1) (+ current (* direction PAGE_SIZE))))])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 (LookupPickerState-filtered-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0 ; Reset preview scroll
                                 (LookupPickerState-filter-text state)
                                 (LookupPickerState-metadata state) ; Preserve metadata
                                 (LookupPickerState-preview-width state)))))

(define (move-to-boundary state-box boundary)
  "Move to first or last entry (boundary: 'first or 'last)"
  (let* ([state (unbox state-box)]
         [filtered (LookupPickerState-filtered-symbols state)] ; Use filtered list
         [count (length filtered)]
         [new-index (if (eq? boundary 'first)
                        0
                        (- count 1))])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 (LookupPickerState-filtered-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0 ; Reset preview scroll
                                 (LookupPickerState-filter-text state)
                                 (LookupPickerState-metadata state) ; Preserve metadata
                                 (LookupPickerState-preview-width state)))))

(define (scroll-preview state-box delta)
  "Scroll preview pane by delta lines"
  (let* ([state (unbox state-box)]
         [selected-symbol (get-selected-symbol state)])

    (when selected-symbol
      (let ([info (get-symbol-info-cached state selected-symbol)])
        (when info
          (let* ([current-scroll (LookupPickerState-preview-scroll state)]
                 [preview-width (LookupPickerState-preview-width state)]
                 [formatted-lines (format-symbol-documentation info preview-width)]
                 [max-scroll (max 0 (- (length formatted-lines) PREVIEW_SCROLL_HEIGHT))]
                 [new-scroll (max 0 (min max-scroll (+ current-scroll delta)))])

            (set-box! state-box
                      (LookupPickerState (LookupPickerState-session state)
                                         (LookupPickerState-symbols state)
                                         (LookupPickerState-filtered-symbols state)
                                         (LookupPickerState-selected-index state)
                                         (LookupPickerState-scroll-offset state)
                                         (LookupPickerState-cache state)
                                         new-scroll
                                         (LookupPickerState-filter-text state)
                                         (LookupPickerState-metadata state)
                                         preview-width))))))))

(define (insert-selected-symbol state qualified?)
  "Insert selected symbol at cursor (qualified if qualified? is #t)"
  (let ([symbol (get-selected-symbol state)])
    (when symbol
      (if qualified?
          ;; Insert fully-qualified symbol (namespace/symbol)
          (let* ([metadata (LookupPickerState-metadata state)]
                 [symbol-meta (if (hash-contains? metadata symbol)
                                  (hash-ref metadata symbol)
                                  (hash '#:ns #f '#:type #f))]
                 [ns (hash-ref symbol-meta '#:ns)]
                 [qualified-name (if (and ns (not (equal? ns #f)) (not (string=? ns "")))
                                     (string-append ns "/" symbol)
                                     symbol)])
            (helix.static.insert_string qualified-name))
          ;; Insert unqualified symbol
          (helix.static.insert_string symbol)))))

;;;; Component Registration ;;;;

(define (show-lookup-picker session debug-fn)
  "Create and show lookup picker component"

  ;; Fetch symbol list and metadata (returns cons pair)
  (let* ([result (fetch-symbol-list session debug-fn)]
         [symbols (car result)]
         [metadata (cdr result)])

    (if (null? symbols)
        (helix.echo "No symbols found. Ensure cider-nrepl middleware is loaded.")
        (let* ([state-box (box (make-lookup-picker-state session symbols metadata))]

               ;; Define handler functions
               ;; Component system passes state-box as first param to all functions
               [function-map (hash "handle_event"
                                   handle-lookup-event
                                   "cursor"
                                   (lambda (state-box rect) #f) ; No cursor for Phase 1
                                   "required_size"
                                   (lambda (state-box size) size))] ; Use full size

               ;; Create component (returns component object)
               ;; Render function called as: (render state-box rect buffer)
               [component (new-component! "lookup-picker"
                                          state-box
                                          (lambda (state-box rect buffer)
                                            (render-lookup-picker (unbox state-box) rect buffer))
                                          function-map)])

          ;; Push the component object
          (push-component! component)))))
