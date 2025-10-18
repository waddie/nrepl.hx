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
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm")

;; Load the steel-nrepl dylib for completions and lookup
(#%require-dylib "libsteel_nrepl" (prefix-in ffi. (only-in completions lookup)))

;; Load documentation formatting utilities
(require "cogs/nrepl/format-docs.scm")

(provide show-lookup-picker)

;;;; Constants ;;;;

(define MIN_AREA_WIDTH_FOR_PREVIEW 72)
(define OVERLAY_SCALE_PERCENT 90)
(define OVERLAY_BOTTOM_CLIP 2)

;;;; Overlay Transformation ;;;;

(define (apply-overlay-transform rect)
  "Apply overlay transformation to rect per R0.2: clip bottom 2 rows, center with 90% width/height"
  ;; Step 1: Clip 2 rows from bottom
  (let* ([terminal-width (area-width rect)]
         [terminal-height (area-height rect)]
         [terminal-x (area-x rect)]
         [terminal-y (area-y rect)]
         [clipped-height (max 0 (- terminal-height OVERLAY_BOTTOM_CLIP))]

         ;; Step 2: Calculate 90% dimensions
         [inner-width (quotient (* terminal-width OVERLAY_SCALE_PERCENT) 100)]
         [inner-height (quotient (* clipped-height OVERLAY_SCALE_PERCENT) 100)]

         ;; Step 3: Center the area (5% margin on each side)
         [offset-x (quotient (- terminal-width inner-width) 2)]
         [offset-y (quotient (- clipped-height inner-height) 2)])

    ;; Return centered, reduced area
    (area (+ terminal-x offset-x) (+ terminal-y offset-y) inner-width inner-height)))

;;;; Utility Functions ;;;;

(define (truncate-string s max-width)
  "Truncate string to max-width, adding ... if needed"
  (if (<= (string-length s) max-width)
      s
      (string-append (substring s 0 (- max-width 3)) "...")))

(define (eval-string s)
  "Safely evaluate string as S-expression"
  (with-handler (lambda (e) #f) (eval (read (open-input-string s)))))

(define (prefetch-symbol-info state index)
  "Prefetch symbol info for given index (optimization)"
  ;; Phase 1: No-op, implement in Phase 3
  void)

;;;; Component State Structure ;;;;

;; State structure for Phase 2 - added preview-scroll
(struct LookupPickerState
        (session ; NReplSession - nREPL session object
         symbols ; (list string) - Symbol names
         selected-index ; usize - Currently selected index (0-based)
         scroll-offset ; usize - For scrolling long lists
         cache ; (hash string -> hash) - Symbol lookup cache
         preview-scroll) ; usize - Scroll offset for preview pane
  #:transparent)

(define (make-lookup-picker-state session symbols)
  (LookupPickerState session
                     symbols
                     0 ; selected-index starts at 0
                     0 ; scroll-offset starts at 0
                     (hash) ; empty cache
                     0)) ; preview-scroll starts at 0

;;;; Fetching Symbol List ;;;;

(define (fetch-symbol-list session debug-fn)
  "Fetch completions for empty prefix to get all symbols"
  (with-handler (lambda (err)
                  (debug-fn (string-append "Error in fetch-symbol-list: " (to-string err)))
                  (list)) ; Return empty list on error
                (begin
                  (debug-fn (string-append "Calling ffi.completions"))
                  (let* ([completions-str (ffi.completions session "" #f #f)])
                    (debug-fn (string-append "Completions string (length "
                                             (to-string (string-length completions-str))
                                             "): "
                                             (substring completions-str
                                                        0
                                                        (min 100 (string-length completions-str)))))
                    (let ([completions-list (eval-string completions-str)])
                      (debug-fn (string-append "Parsed list type: "
                                               (if (list? completions-list) "list" "not-list")
                                               ", length: "
                                               (if (list? completions-list)
                                                   (to-string (length completions-list))
                                                   "N/A")))
                      (if (list? completions-list)
                          completions-list
                          (list))))))) ; Return empty list on error

;;;; Symbol Info Caching ;;;;

(define (get-selected-symbol state)
  "Get currently selected symbol name"
  (let* ([symbols (LookupPickerState-symbols state)]
         [index (LookupPickerState-selected-index state)])
    (if (and (>= index 0) (< index (length symbols)))
        (list-ref symbols index)
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
  "Render the lookup picker component following standard picker sizing algorithm"
  (let* ([overlay-area (apply-overlay-transform rect)]
         [overlay-width (area-width overlay-area)]
         [overlay-height (area-height overlay-area)]
         [overlay-x (area-x overlay-area)]
         [overlay-y (area-y overlay-area)]
         [show-preview (> overlay-width MIN_AREA_WIDTH_FOR_PREVIEW)]
         [picker-width (if show-preview
                           (quotient overlay-width 2) ; 50% when preview shown
                           overlay-width)] ; 100% when preview hidden
         [picker-area (area overlay-x overlay-y picker-width overlay-height)]
         [preview-area (if show-preview
                           (area (+ overlay-x picker-width)
                                 overlay-y
                                 (- overlay-width picker-width)
                                 overlay-height)
                           #f)])

    (buffer/clear buffer picker-area)
    (when show-preview
      (buffer/clear buffer preview-area))

    ;; Draw borders
    (let ([border-style (make-block (theme->bg *helix.cx*) (theme->bg *helix.cx*) "all" "plain")])
      (block/render buffer picker-area border-style)
      (when show-preview
        (block/render buffer preview-area border-style)))

    (let* ([picker-content-x (+ overlay-x 2)]
           [picker-content-y (+ overlay-y 1)]
           [picker-content-width (- picker-width 4)]
           [picker-content-height (- overlay-height 3)]
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
                                       0)])

      ;; Draw symbol list in picker content area
      (draw-symbol-list buffer
                        picker-content-x
                        picker-content-y
                        picker-content-width
                        picker-content-height
                        (LookupPickerState-symbols state)
                        (LookupPickerState-selected-index state)
                        (LookupPickerState-scroll-offset state))

      ;; Draw preview in preview content area (if shown)
      (when show-preview
        (draw-preview buffer
                      preview-content-x
                      preview-content-y
                      preview-content-width
                      preview-content-height
                      state
                      (get-selected-symbol state)))

      ;; Draw status line at bottom of picker pane
      (draw-status-line buffer
                        picker-content-x
                        (+ overlay-y (- overlay-height 2))
                        picker-content-width
                        state))))

(define (draw-symbol-list buffer x y width height symbols selected scroll)
  "Draw scrollable list of symbols"
  (let* ([visible-count (min height (length symbols))]
         [start-index scroll]
         [end-index (min (+ start-index visible-count) (length symbols))])

    (let loop ([i start-index])
      (when (< i end-index)
        (let* ([symbol (list-ref symbols i)]
               [row (+ y (- i scroll))]
               [is-selected (= i selected)]
               [style-obj (if is-selected
                              (theme-scope *helix.cx* "ui.menu.selected")
                              (style))])

          (let ([display-text (if is-selected
                                  (string-append "> " symbol)
                                  (string-append "  " symbol))])
            (frame-set-string! buffer x row (truncate-string display-text width) style-obj))
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

(define (draw-status-line buffer x y width state)
  "Draw status line at bottom"
  (let* ([count (length (LookupPickerState-symbols state))]
         [current (+ (LookupPickerState-selected-index state) 1)]
         [status (string-append (number->string current) "/" (number->string count) " symbols")]
         [style-obj (style-fg (style) Color/Gray)])
    (frame-set-string! buffer x y (truncate-string status width) style-obj)))

;;;; Event Handling ;;;;

(define (handle-lookup-event state-box event)
  "Handle keyboard events for picker"
  (cond
    ;; Close on Escape or Ctrl-c
    [(or (key-event-escape? event)
         (and (equal? (key-event-modifier event) key-modifier-ctrl)
              (equal? (key-event-char event) #\c)))
     (begin
       (pop-last-component-by-name! "lookup-picker")
       event-result/consume)]

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
     (scroll-preview state-box -10)
     event-result/consume]

    ;; Page down in preview: PageDown
    [(key-event-page-down? event)
     (scroll-preview state-box 10)
     event-result/consume]

    ;; Go to first: Home
    [(key-event-home? event)
     (move-to-boundary state-box 'first)
     event-result/consume]

    ;; Go to last: End
    [(key-event-end? event)
     (move-to-boundary state-box 'last)
     event-result/consume]

    ;; Insert symbol on Enter
    [(key-event-enter? event)
     (insert-selected-symbol (unbox state-box))
     (pop-last-component-by-name! "lookup-picker")
     event-result/consume]

    ;; Ignore other events
    [else event-result/ignore]))

(define (move-selection state-box delta)
  "Move selection by delta (-1 for up, +1 for down)"
  (let* ([state (unbox state-box)]
         [symbols (LookupPickerState-symbols state)]
         [count (length symbols)]
         [current (LookupPickerState-selected-index state)]
         [new-index (max 0 (min (- count 1) (+ current delta)))])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0)) ; Reset preview scroll when selection changes

    ;; Prefetch symbol info for new selection
    (prefetch-symbol-info state-box new-index)))

(define (move-page state-box direction)
  "Move selection by one page (direction: -1 up, 1 down)"
  (let* ([state (unbox state-box)]
         [symbols (LookupPickerState-symbols state)]
         [count (length symbols)]
         [current (LookupPickerState-selected-index state)]
         [page-size 10] ; Fixed page size for Phase 1
         [new-index (max 0 (min (- count 1) (+ current (* direction page-size))))])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0)) ; Reset preview scroll when selection changes

    ;; Prefetch symbol info for new selection
    (prefetch-symbol-info state-box new-index)))

(define (move-to-boundary state-box boundary)
  "Move to first or last entry (boundary: 'first or 'last)"
  (let* ([state (unbox state-box)]
         [symbols (LookupPickerState-symbols state)]
         [count (length symbols)]
         [new-index (if (eq? boundary 'first)
                        0
                        (- count 1))])

    (set-box! state-box
              (LookupPickerState (LookupPickerState-session state)
                                 (LookupPickerState-symbols state)
                                 new-index
                                 (calculate-scroll-offset new-index)
                                 (LookupPickerState-cache state)
                                 0)) ; Reset preview scroll when selection changes

    ;; Prefetch symbol info for new selection
    (prefetch-symbol-info state-box new-index)))

(define (scroll-preview state-box delta)
  "Scroll preview pane by delta lines"
  (let* ([state (unbox state-box)]
         [selected-symbol (get-selected-symbol state)])

    (when selected-symbol
      (let ([info (get-symbol-info-cached state selected-symbol)])
        (when info
          (let* ([current-scroll (LookupPickerState-preview-scroll state)]
                 [formatted-lines (format-symbol-documentation info 80)]
                 [max-scroll (max 0 (- (length formatted-lines) 20))]
                 [new-scroll (max 0 (min max-scroll (+ current-scroll delta)))])

            (set-box! state-box
                      (LookupPickerState (LookupPickerState-session state)
                                         (LookupPickerState-symbols state)
                                         (LookupPickerState-selected-index state)
                                         (LookupPickerState-scroll-offset state)
                                         (LookupPickerState-cache state)
                                         new-scroll))))))))

(define (calculate-scroll-offset new-index)
  "Calculate scroll offset to keep selection visible"
  ;; Phase 1: Simple - just keep selected item visible
  ;; Phase 2: Add smooth scrolling with padding
  new-index)

(define (insert-selected-symbol state)
  "Insert selected symbol at cursor"
  (let ([symbol (get-selected-symbol state)])
    (when symbol
      (helix.static.insert_string symbol))))

;;;; Component Registration ;;;;

(define (show-lookup-picker session debug-fn)
  "Create and show lookup picker component"

  ;; Fetch symbol list
  (let ([symbols (fetch-symbol-list session debug-fn)])

    (if (null? symbols)
        (helix.echo "No symbols found. Ensure cider-nrepl middleware is loaded.")
        (let* ([state-box (box (make-lookup-picker-state session symbols))]

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
