;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Alias picker component for nREPL jack-in
;; Multi-select UI for choosing which deps.edn aliases to use

(require-builtin helix/components)
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm")
(require "project-detection.scm") ; For alias-info struct

(provide show-alias-picker
         AliasPickerState
         make-alias-picker-state)

;;; Constants

(define OVERLAY_SCALE_PERCENT 90)
(define OVERLAY_BOTTOM_CLIP 2)

;;; State struct

(struct AliasPickerState
        (aliases ; list of alias-info structs (from project-detection.scm)
         selected-names ; list of selected alias names (strings)
         cursor-index ; integer: current cursor position
         callback) ; function (list-of-strings -> void) to call with selected names
  #:transparent)

(define (make-alias-picker-state aliases initial-selection callback)
  "Create initial picker state.
   aliases: list of alias-info structs
   initial-selection: list of alias names to pre-select (strings)
   callback: function to call with list of selected alias names"
  (AliasPickerState aliases initial-selection 0 callback))

;;; Selection helpers

(define (alias-selected? state alias-name)
  "Check if an alias is currently selected"
  (member alias-name (AliasPickerState-selected-names state)))

(define (toggle-alias state index)
  "Toggle selection of alias at given index. Returns new state."
  (let* ([aliases (AliasPickerState-aliases state)]
         [alias-info (list-ref aliases index)]
         [alias-name (alias-info-name alias-info)]
         [selected-names (AliasPickerState-selected-names state)]
         [new-names (if (member alias-name selected-names)
                        (filter (lambda (n) (not (equal? n alias-name))) selected-names)
                        (cons alias-name selected-names))])
    (AliasPickerState (AliasPickerState-aliases state)
                      new-names
                      (AliasPickerState-cursor-index state)
                      (AliasPickerState-callback state))))

(define (move-cursor state delta)
  "Move cursor by delta (-1 for up, +1 for down) with wrapping. Returns new state."
  (let* ([aliases (AliasPickerState-aliases state)]
         [count (length aliases)]
         [current (AliasPickerState-cursor-index state)]
         [next (+ current delta)]
         ;; Wrap around at boundaries
         [new-index (cond
                      [(< next 0) (- count 1)]
                      [(>= next count) 0]
                      [else next])])
    (AliasPickerState (AliasPickerState-aliases state)
                      (AliasPickerState-selected-names state)
                      new-index
                      (AliasPickerState-callback state))))

(define (get-selected-names state)
  "Get list of currently selected alias names (strings)"
  (AliasPickerState-selected-names state))

;;; Rendering

(define (apply-overlay-transform rect)
  "Apply overlay transformation to rect: clip bottom 2 rows, center with 90% width/height"
  ;; Step 1: Clip 2 rows from bottom
  (let* ([terminal-width (area-width rect)]
         [terminal-height (area-height rect)]
         [terminal-x (area-x rect)]
         [terminal-y (area-y rect)]
         [clipped-height (- terminal-height OVERLAY_BOTTOM_CLIP)]
         ;; Step 2: Calculate 90% dimensions
         [overlay-width (quotient (* terminal-width OVERLAY_SCALE_PERCENT) 100)]
         [overlay-height (quotient (* clipped-height OVERLAY_SCALE_PERCENT) 100)]
         ;; Step 3: Center the overlay
         [overlay-x (+ terminal-x (quotient (- terminal-width overlay-width) 2))]
         [overlay-y (+ terminal-y (quotient (- clipped-height overlay-height) 2))])
    (area overlay-x overlay-y overlay-width overlay-height)))

(define (render-alias-picker state-box rect buffer)
  "Render the alias picker component"
  (let* ([state (unbox state-box)]
         [aliases (AliasPickerState-aliases state)]
         [cursor-idx (AliasPickerState-cursor-index state)]
         ;; Apply overlay transform for margins
         [overlay-area (apply-overlay-transform rect)]
         [x (area-x overlay-area)]
         [y (area-y overlay-area)]
         [width (area-width overlay-area)]
         [height (area-height overlay-area)])

    ;; Clear area
    (buffer/clear buffer overlay-area)

    ;; Draw border
    (let* ([block (make-block (theme->bg *helix.cx*) (theme->bg *helix.cx*) "all" "plain")])
      (block/render buffer overlay-area block))

    ;; Title
    (frame-set-string! buffer (+ x 2) y "Select aliases for jack-in" (style))

    ;; Instructions
    (frame-set-string! buffer
                       (+ x 2)
                       (+ y 1)
                       "Space: toggle  Enter: confirm  Esc: cancel"
                       (style-fg (style) Color/Gray))

    ;; Render alias list
    (let loop ([idx 0]
               [line-y (+ y 3)])
      (when (and (< idx (length aliases)) (< line-y (+ y height -1)))
        (let* ([alias-info (list-ref aliases idx)]
               [alias-name (alias-info-name alias-info)]
               [has-main? (alias-info-has-main-opts? alias-info)]
               [is-selected? (alias-selected? state alias-name)]
               [is-cursor? (= idx cursor-idx)]

               ;; Format line components
               [cursor-char (if is-cursor? ">" " ")]
               [checkbox (if is-selected? "[✓]" "[ ]")]
               [warning (if has-main? " ⚠ :main-opts" "")]
               [line-text (string-append cursor-char " " checkbox " :" alias-name warning)]

               ;; Style based on state
               [line-style (cond
                             [is-cursor? (style-fg (style) Color/Blue)]
                             [has-main? (style-fg (style) Color/Yellow)]
                             [else (style)])])

          (frame-set-string! buffer (+ x 2) line-y line-text line-style)

          (loop (+ idx 1) (+ line-y 1)))))))

;;; Event handling

(define (handle-picker-event state-box event)
  "Handle keyboard events for the alias picker"
  (let ([state (unbox state-box)])
    (cond
      ;; Escape - cancel
      [(key-event-escape? event) event-result/close]

      ;; Enter - confirm selection
      [(key-event-enter? event)
       (let ([callback (AliasPickerState-callback state)]
             [selected (get-selected-names state)])
         (callback selected)
         event-result/close)]

      ;; Up arrow or k - move cursor up
      [(or (key-event-up? event) (and (key-event-char event) (equal? (key-event-char event) #\k)))
       (set-box! state-box (move-cursor state -1))
       event-result/consume]

      ;; Down arrow or j - move cursor down
      [(or (key-event-down? event) (and (key-event-char event) (equal? (key-event-char event) #\j)))
       (set-box! state-box (move-cursor state 1))
       event-result/consume]

      ;; Space - toggle selection
      [(and (key-event-char event) (equal? (key-event-char event) #\ ))
       (set-box! state-box (toggle-alias state (AliasPickerState-cursor-index state)))
       event-result/consume]

      ;; Tab - toggle and move down
      [(key-event-tab? event)
       (let* ([state-1 (toggle-alias state (AliasPickerState-cursor-index state))]
              [state-2 (move-cursor state-1 1)])
         (set-box! state-box state-2)
         event-result/consume)]

      ;; All other events - consume to prevent falling through to editor
      [else event-result/consume])))

(define (cursor-handler state-box rect)
  "No cursor needed for this picker"
  #f)

;;; Public API

(define (show-alias-picker aliases initial-selection callback)
  "Show the alias picker component.
   aliases: list of alias-info structs
   initial-selection: list of alias names to pre-select
   callback: function (list-of-strings -> void) called with selected aliases"
  (let* ([state (make-alias-picker-state aliases initial-selection callback)]
         [state-box (box state)]
         [function-map (hash "handle_event" handle-picker-event "cursor" cursor-handler)]
         [component (new-component! "alias-picker" state-box render-alias-picker function-map)])
    (push-component! component)))
