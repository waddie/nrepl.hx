;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; project-file-picker.scm - Project File Picker Component
;;;
;;; Interactive picker for selecting project files when multiple are found.

(require-builtin helix/components)
(require-builtin steel/ports)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm")

(require "cogs/nrepl/ui-utils.scm")
(require "cogs/nrepl/picker-utils.scm")
(require "cogs/nrepl/string-utils.scm")
(require "cogs/nrepl/file-utils.scm")
(require "cogs/nrepl/project-file-types.scm")
(require "cogs/nrepl/format-docs.scm")

(provide show-project-file-picker)

;;;; Constants ;;;;

(define PREVIEW_LINES 50)
;; Number of lines to show in file preview

;; Column layout
(define MIN_COLUMN_DISPLAY_WIDTH 30) ; Minimum width to show all columns
(define COLUMN_TYPE_WIDTH 16)
(define COLUMN_SPACING 2)

;;;; Component State Structure ;;;;

(struct ProjectFilePickerState
        (workspace-root ; String - workspace root directory
         all-files ; List of absolute file paths (original full list)
         filtered-files ; List of absolute file paths (current filtered view)
         selected-index ; Integer - currently selected index into filtered-files
         scroll-offset ; Integer - for scrolling long lists
         filter-text ; String - user's filter input
         preview-content ; Hash - filepath -> preview string cache
         preview-scroll ; Integer - scroll offset for preview pane
         preview-width ; Integer - current preview pane width
         callback) ; Function - (filepath) -> void
  #:transparent)

(define (make-project-file-picker-state workspace-root files callback)
  (let ([sorted-files (sort-files-by-distance files workspace-root)])
    (ProjectFilePickerState workspace-root
                            sorted-files ; Original full list (sorted)
                            sorted-files ; Initially, filtered = full list
                            0 ; selected-index starts at 0
                            0 ; scroll-offset starts at 0
                            "" ; empty filter text
                            (hash) ; empty preview cache
                            0 ; preview-scroll starts at 0
                            60 ; default preview-width
                            callback)))

;;;; Public API ;;;;

;;@doc
;; Show project file picker component.
;;
;; Parameters:
;;   workspace-root - Workspace root directory
;;   files - List of absolute file paths to choose from
;;   callback - Function called with selected file path
;;
;; Example:
;;   (show-project-file-picker "/workspace"
;;                             '("/workspace/deps.edn" "/workspace/bb.edn")
;;                             (lambda (path) (helix.echo path)))
(define (show-project-file-picker workspace-root files callback)
  (if (or (null? files) (not workspace-root))
      (helix.echo "No project files to select")
      (let* ([state (make-project-file-picker-state workspace-root files callback)]
             [state-box (box state)]
             [function-map (hash "handle_event"
                                 handle-picker-event
                                 "cursor"
                                 (lambda (state-box rect) #f)
                                 "required_size"
                                 (lambda (state-box size) size))]
             [component (new-component! "project-file-picker" state-box render-picker function-map)])
        (push-component! component))))

;;;; Rendering ;;;;

(define (render-picker state-box rect buffer)
  "Render the project file picker component"
  (let* ([state (unbox state-box)]
         [overlay-area (apply-overlay-transform rect)]
         [layout (apply-two-pane-layout overlay-area)]
         [show-preview (hash-ref layout '#:show-preview)]
         [picker-area (hash-ref layout '#:picker-area)]
         [preview-area (hash-ref layout '#:preview-area)]
         [picker-width (hash-ref layout '#:picker-width)]
         [preview-width (hash-ref layout '#:preview-width)])

    ;; Update preview width in state if changed
    (when (not (= preview-width (ProjectFilePickerState-preview-width state)))
      (set-box! state-box
                (ProjectFilePickerState (ProjectFilePickerState-workspace-root state)
                                        (ProjectFilePickerState-all-files state)
                                        (ProjectFilePickerState-filtered-files state)
                                        (ProjectFilePickerState-selected-index state)
                                        (ProjectFilePickerState-scroll-offset state)
                                        (ProjectFilePickerState-filter-text state)
                                        (ProjectFilePickerState-preview-content state)
                                        (ProjectFilePickerState-preview-scroll state)
                                        preview-width
                                        (ProjectFilePickerState-callback state))))

    (buffer/clear buffer overlay-area)

    ;; Draw borders
    (let ([border-style (make-block (theme->bg *helix.cx*) (theme->bg *helix.cx*) "all" "plain")])
      (block/render buffer picker-area border-style)
      (when show-preview
        (block/render buffer preview-area border-style)))

    (let* ([picker-x (+ (area-x picker-area) 2)]
           [picker-y (+ (area-y picker-area) 1)]
           [picker-content-width (- picker-width 4)]
           [picker-content-height (- (area-height picker-area) 2)]
           [filter-y picker-y]
           [separator-y (+ picker-y 1)]
           [list-y (+ picker-y 2)]
           [list-height (- picker-content-height 2)])

      ;; Draw filter bar
      (draw-filter-bar buffer
                       picker-x
                       filter-y
                       picker-content-width
                       (ProjectFilePickerState-filter-text state)
                       (length (ProjectFilePickerState-filtered-files state))
                       (length (ProjectFilePickerState-all-files state)))

      ;; Draw separator
      (frame-set-string! buffer picker-x separator-y (make-string picker-content-width #\─) (style))

      ;; Draw column header
      (draw-column-header buffer picker-x (+ separator-y 1) picker-content-width)

      ;; Draw file list
      (draw-file-list buffer picker-x (+ separator-y 2) picker-content-width (- list-height 1) state)

      ;; Draw preview if enabled
      (when show-preview
        (let* ([preview-x (+ (area-x preview-area) 2)]
               [preview-y (+ (area-y preview-area) 1)]
               [preview-content-width (- preview-width 4)]
               [preview-content-height (- (area-height preview-area) 2)])
          (draw-preview buffer
                        preview-x
                        preview-y
                        preview-content-width
                        preview-content-height
                        state))))))

(define (draw-file-list buffer x y width height state)
  "Draw scrollable list of files with columns (project file, type)"
  (let* ([files (ProjectFilePickerState-filtered-files state)]
         [workspace-root (ProjectFilePickerState-workspace-root state)]
         [selected (ProjectFilePickerState-selected-index state)]
         [scroll (ProjectFilePickerState-scroll-offset state)]
         [visible-count (min height (length files))]
         [start-index scroll]
         [end-index (min (+ start-index visible-count) (length files))]
         ;; Column widths - adjust based on available space with bounds checking
         [type-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_TYPE_WIDTH)]
         [spacing (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_SPACING)]
         [path-width (max 10 (- width type-width spacing))])

    (let loop ([i start-index])
      (when (< i end-index)
        (let* ([filepath (list-ref files i)]
               [relative-path (get-relative-path filepath workspace-root)]
               [type-label (get-file-type-label filepath)]
               [row (+ y (- i scroll))]
               [is-selected (= i selected)]
               [style-obj (if is-selected
                              (theme-scope *helix.cx* "ui.menu.selected")
                              (style))]
               ;; Build column display
               [prefix (if is-selected "> " "  ")]
               [path-col (truncate-left relative-path (- path-width 2))]
               [type-col (truncate-string type-label type-width)]
               ;; Pad columns to fixed width for alignment
               [path-padded (string-append
                             path-col
                             (make-string (max 0 (- path-width (string-length path-col) 2)) #\space))]
               [display-text (string-append prefix path-padded " " type-col)])

          (frame-set-string! buffer x row (truncate-string display-text width) style-obj)
          (loop (+ i 1)))))))

(define (draw-preview buffer x y width height state)
  "Draw file preview pane"
  (let* ([selected-file (get-selected-file state)])
    (if (not selected-file)
        (frame-set-string! buffer x y "No file selected" (style-fg (style) Color/Gray))
        (let ([preview-text (get-preview-content state selected-file)])
          (if (not preview-text)
              (frame-set-string! buffer x y "Could not load preview" (style-fg (style) Color/Gray))
              (draw-preview-text buffer x y width height state preview-text))))))

(define (draw-preview-text buffer x y width height state preview-text)
  "Draw scrollable preview text"
  (let* ([lines (split-many preview-text "\n")]
         [scroll (ProjectFilePickerState-preview-scroll state)]
         [visible-count (min height (length lines))]
         [start-line scroll]
         [end-line (min (+ start-line visible-count) (length lines))])

    (let loop ([i start-line])
      (when (< i end-line)
        (let* ([line (list-ref lines i)]
               [row (+ y (- i scroll))])
          (frame-set-string! buffer x row (truncate-string line width) (style))
          (loop (+ i 1)))))))

(define (draw-column-header buffer x y width)
  "Draw fixed column header row"
  (let* ([type-width (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_TYPE_WIDTH)]
         [spacing (if (< width MIN_COLUMN_DISPLAY_WIDTH) 0 COLUMN_SPACING)]
         [path-width (max 10 (- width type-width spacing))]
         [prefix "  "]
         ;; Pad headers to match column widths
         [path-header (if (> path-width 12)
                          (string-append "Project File"
                                         (make-string (max 0 (- path-width 12 2)) #\space))
                          "Project File")]
         [type-header (if (> type-width 0) "Type" "")]
         [header-parts (filter (lambda (s) (not (string=? s ""))) (list path-header type-header))]
         [header-text (string-append prefix
                                     (apply string-append
                                            (map (lambda (part)
                                                   (if (string=? part (car (reverse header-parts)))
                                                       part
                                                       (string-append part " ")))
                                                 header-parts)))]
         [header-style (style)])

    (frame-set-string! buffer x y (truncate-string header-text width) header-style)))

;;;; State Management ;;;;

(define (get-selected-file state)
  "Get currently selected file path"
  (let* ([filtered (ProjectFilePickerState-filtered-files state)]
         [index (ProjectFilePickerState-selected-index state)])
    (if (and (>= index 0) (< index (length filtered)))
        (list-ref filtered index)
        #f)))

(define (get-preview-content state filepath)
  "Get preview content from cache or load it"
  (let ([cache (ProjectFilePickerState-preview-content state)])
    (if (hash-contains? cache filepath)
        (hash-ref cache filepath)
        (let ([content (read-file-preview filepath PREVIEW_LINES)])
          ;; Update cache (but don't modify state here - just for this render)
          content))))

(define (apply-filter state new-filter)
  "Filter files by substring match and return new state
   Note: Maintains sort order (by distance from root, then alphabetically)"
  (let* ([all-files (ProjectFilePickerState-all-files state)]
         [workspace-root (ProjectFilePickerState-workspace-root state)]
         [filtered (if (string=? new-filter "")
                       all-files
                       ;; Filter maintains order since all-files is already sorted
                       (filter (lambda (filepath)
                                 (let ([relative (get-relative-path filepath workspace-root)])
                                   (string-contains-ci? relative new-filter)))
                               all-files))])

    (ProjectFilePickerState workspace-root
                            all-files
                            filtered
                            0 ; Reset to first item
                            0 ; Reset scroll
                            new-filter
                            (ProjectFilePickerState-preview-content state)
                            0 ; Reset preview scroll
                            (ProjectFilePickerState-preview-width state)
                            (ProjectFilePickerState-callback state))))

(define (move-selection state-box delta)
  "Move selection by delta with wrapping"
  (let* ([state (unbox state-box)]
         [filtered (ProjectFilePickerState-filtered-files state)]
         [count (length filtered)]
         [current (ProjectFilePickerState-selected-index state)])
    (when (> count 0)
      (let* ([next (+ current delta)]
             [new-index (cond
                          [(< next 0) (- count 1)]
                          [(>= next count) 0]
                          [else next])]
             [new-scroll (calculate-scroll-offset new-index)])
        (set-box! state-box
                  (ProjectFilePickerState (ProjectFilePickerState-workspace-root state)
                                          (ProjectFilePickerState-all-files state)
                                          filtered
                                          new-index
                                          new-scroll
                                          (ProjectFilePickerState-filter-text state)
                                          (ProjectFilePickerState-preview-content state)
                                          0 ; Reset preview scroll when changing selection
                                          (ProjectFilePickerState-preview-width state)
                                          (ProjectFilePickerState-callback state)))))))

(define (scroll-preview state-box delta)
  "Scroll preview pane by delta lines"
  (let* ([state (unbox state-box)]
         [current-scroll (ProjectFilePickerState-preview-scroll state)]
         [new-scroll (max 0 (+ current-scroll delta))])
    (set-box! state-box
              (ProjectFilePickerState (ProjectFilePickerState-workspace-root state)
                                      (ProjectFilePickerState-all-files state)
                                      (ProjectFilePickerState-filtered-files state)
                                      (ProjectFilePickerState-selected-index state)
                                      (ProjectFilePickerState-scroll-offset state)
                                      (ProjectFilePickerState-filter-text state)
                                      (ProjectFilePickerState-preview-content state)
                                      new-scroll
                                      (ProjectFilePickerState-preview-width state)
                                      (ProjectFilePickerState-callback state)))))

;;;; Event Handling ;;;;

(define (handle-picker-event state-box event)
  "Handle keyboard events for picker"
  (cond
    ;; Escape - cancel
    [(key-event-escape? event) event-result/close]

    ;; Enter - select and invoke callback
    [(key-event-enter? event)
     (let* ([state (unbox state-box)]
            [selected (get-selected-file state)]
            [callback (ProjectFilePickerState-callback state)])
       (when (and selected callback)
         (callback selected))
       event-result/close)]

    ;; Backspace - remove last filter char
    [(key-event-backspace? event)
     (let* ([state (unbox state-box)]
            [filter-text (ProjectFilePickerState-filter-text state)])
       (if (> (string-length filter-text) 0)
           (let ([new-filter (substring filter-text 0 (- (string-length filter-text) 1))])
             (set-box! state-box (apply-filter state new-filter)))
           void)
       event-result/consume)]

    ;; Navigation - Up/Down, j/k, Ctrl-p/Ctrl-n
    [(or (key-event-up? event)
         (and (key-event-char event)
              (equal? (key-event-char event) #\k)
              (not (key-event-modifier event))))
     (move-selection state-box -1)
     event-result/consume]

    [(or (key-event-down? event)
         (and (key-event-char event)
              (equal? (key-event-char event) #\j)
              (not (key-event-modifier event))))
     (move-selection state-box 1)
     event-result/consume]

    [(and (key-event-char event)
          (equal? (key-event-char event) #\p)
          (equal? (key-event-modifier event) key-modifier-ctrl))
     (move-selection state-box -1)
     event-result/consume]

    [(and (key-event-char event)
          (equal? (key-event-char event) #\n)
          (equal? (key-event-modifier event) key-modifier-ctrl))
     (move-selection state-box 1)
     event-result/consume]

    ;; Preview scrolling
    [(key-event-page-up? event)
     (scroll-preview state-box (- PREVIEW_SCROLL_DELTA))
     event-result/consume]

    [(key-event-page-down? event)
     (scroll-preview state-box PREVIEW_SCROLL_DELTA)
     event-result/consume]

    ;; Character input - add to filter
    [(key-event-char event)
     (let* ([state (unbox state-box)]
            [char (key-event-char event)]
            [filter-text (ProjectFilePickerState-filter-text state)]
            [new-filter (string-append filter-text (string char))])
       (set-box! state-box (apply-filter state new-filter))
       event-result/consume)]

    [else event-result/consume]))
