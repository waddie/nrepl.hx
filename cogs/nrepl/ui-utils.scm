;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; ui-utils.scm - Shared UI Utilities
;;;
;;; Common UI helper functions for components.

(require-builtin helix/components)

(provide OVERLAY_SCALE_PERCENT
         OVERLAY_BOTTOM_CLIP
         apply-overlay-transform)

;;;; Constants ;;;;

(define OVERLAY_SCALE_PERCENT 90) ; Overlay takes 90% of terminal width/height
(define OVERLAY_BOTTOM_CLIP 2) ; Clip 2 rows from bottom (status line)

;;;; Overlay Transformation ;;;;

;;@doc
;; Apply overlay transformation to rect for centered modal overlays
;;
;; This function applies a standard transformation for modal overlays:
;; 1. Clips N rows from bottom (to avoid status line)
;; 2. Scales to OVERLAY_SCALE_PERCENT% of terminal dimensions
;; 3. Centers the result in the terminal
;;
;; Parameters:
;;   rect - The terminal rect to transform
;;
;; Returns:
;;   New rect representing the centered overlay area
;;
;; Example:
;;   Terminal rect: (area 0 0 100 40)
;;   After transform: (area 5 3 90 34)  ; Centered 90% width/height
(define (apply-overlay-transform rect)
  (let* ([terminal-width (area-width rect)]
         [terminal-height (area-height rect)]
         [terminal-x (area-x rect)]
         [terminal-y (area-y rect)]

         ;; Step 1: Clip rows from bottom (for status line)
         [clipped-height (max 0 (- terminal-height OVERLAY_BOTTOM_CLIP))]

         ;; Step 2: Calculate scaled dimensions (90% of terminal size)
         [inner-width (quotient (* terminal-width OVERLAY_SCALE_PERCENT) 100)]
         [inner-height (quotient (* clipped-height OVERLAY_SCALE_PERCENT) 100)]

         ;; Step 3: Center the area (equal margins on all sides)
         [offset-x (quotient (- terminal-width inner-width) 2)]
         [offset-y (quotient (- clipped-height inner-height) 2)])

    ;; Return centered, scaled area
    (area (+ terminal-x offset-x) (+ terminal-y offset-y) inner-width inner-height)))
