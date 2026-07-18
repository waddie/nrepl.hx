;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; style-utils.scm - Shared Picker Line Styling

(provide style-lines)

;;@doc
;; Pair each line with a style, producing (line . style) pairs.
(define (style-lines lines st)
  (map (lambda (line) (cons line st)) lines))
