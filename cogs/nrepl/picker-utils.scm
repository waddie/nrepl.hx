;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; picker-utils.scm - Shared Picker UI Utilities
;;;
;;; Common rendering and layout functions for picker components.

(require-builtin helix/components)
(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "cogs/nrepl/format-docs.scm")

(provide PAGE_SIZE
         PREVIEW_SCROLL_DELTA
         MIN_AREA_WIDTH_FOR_PREVIEW
         SCROLL_PADDING
         draw-filter-bar
         calculate-scroll-offset
         apply-two-pane-layout)

;;;; Constants ;;;;

;; Navigation
(define PAGE_SIZE 10)
;; Number of items to skip when using Ctrl-u/Ctrl-d (page up/down)

(define PREVIEW_SCROLL_DELTA 10)
;; Number of lines to scroll when using PageUp/PageDown in preview pane

;; Layout
(define MIN_AREA_WIDTH_FOR_PREVIEW 72)
;; Minimum terminal width to show preview pane (otherwise single-pane mode)

(define SCROLL_PADDING 5)
;; Number of items to keep above selection when scrolling

;;;; Filter Bar Rendering ;;;;

;;@doc
;; Draw standard Helix-style filter bar.
;;
;; Renders a filter input line with:
;; - Filter text + cursor on left
;; - Count "filtered/total" on right
;;
;; Parameters:
;;   buffer      - Frame buffer for rendering
;;   x           - X coordinate
;;   y           - Y coordinate
;;   width       - Available width
;;   filter-text - Current filter string
;;   filtered-count - Number of filtered items
;;   total-count - Total number of items
;;
;; Example output: "myfilter█         23/487"
(define (draw-filter-bar buffer x y width filter-text filtered-count total-count)
  (let* ([cursor-char "█"]
         [count-text (string-append (number->string filtered-count) "/" (number->string total-count))]
         [count-len (string-length count-text)]
         [text-style (style)]
         [max-filter-width (- width count-len 1)])

    ;; Clear the line
    (frame-set-string! buffer x y (make-string width #\space) (style))

    ;; Draw filter text with cursor (left side)
    (let ([display-text (string-append filter-text cursor-char)])
      (frame-set-string! buffer x y (truncate-string display-text max-filter-width) text-style))

    ;; Draw count (right side)
    (frame-set-string! buffer (+ x (- width count-len)) y count-text text-style)))

;;;; Scroll Offset Calculation ;;;;

;;@doc
;; Calculate scroll offset to keep selection centered with padding.
;;
;; Uses conservative approach (not viewport-aware). Keeps SCROLL_PADDING
;; items above the selected item when possible.
;;
;; Parameters:
;;   new-index - The newly selected index
;;
;; Returns:
;;   Scroll offset (non-negative integer)
;;
;; Example:
;;   (calculate-scroll-offset 10)  => 5  (keeps 5 items above selection)
;;   (calculate-scroll-offset 2)   => 0  (can't have 5 above when at top)
(define (calculate-scroll-offset new-index)
  (max 0 (- new-index SCROLL_PADDING)))

;;;; Two-Pane Layout ;;;;

;;@doc
;; Calculate two-pane layout dimensions.
;;
;; Given an overlay area, returns layout info for picker and preview panes.
;; If area is too narrow, preview is disabled (preview-area will be #f).
;;
;; Parameters:
;;   overlay-area - Area struct (from apply-overlay-transform)
;;
;; Returns:
;;   Hash with:
;;     '#:show-preview - Boolean
;;     '#:picker-area - Area struct for picker pane
;;     '#:preview-area - Area struct for preview pane (or #f)
;;     '#:picker-width - Width of picker pane
;;     '#:preview-width - Width of preview pane (or 0)
;;
;; Example:
;;   (apply-two-pane-layout area)
;;   => (hash '#:show-preview #t '#:picker-area ... '#:preview-area ...)
(define (apply-two-pane-layout overlay-area)
  (let* ([overlay-width (area-width overlay-area)]
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
                           #f)]
         [preview-width (if show-preview
                            (- overlay-width picker-width)
                            0)])

    (hash '#:show-preview
          show-preview
          '#:picker-area
          picker-area
          '#:preview-area
          preview-area
          '#:picker-width
          picker-width
          '#:preview-width
          preview-width)))
