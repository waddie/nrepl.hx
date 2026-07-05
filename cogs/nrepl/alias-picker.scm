;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; alias-picker.scm - deps.edn alias multi-select for nREPL jack-in
;;;
;;; A multi-select checkbox list of a project's aliases. Aliases that define
;;; :main-opts (which would launch an application rather than a plain REPL) are
;;; flagged in yellow. Selection is confirmed with Enter and returned as a list
;;; of alias names.
;;;
;;; The list, checkboxes, wrapping navigation and Space/Tab toggles come from
;;; ui-utils.hx's make-picker; this module supplies the alias label, the warning
;;; style, and the name/item conversions at the callback boundary.

(require-builtin helix/components)
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker!))
(require "project-detection.scm") ; For alias-info struct

(provide show-alias-picker)

;; The row text after the checkbox: ":name" plus the :main-opts warning.
(define (alias-label ai)
  (string-append ":" (alias-info-name ai)
    (if (alias-info-has-main-opts? ai) " ⚠ :main-opts" "")))

;; Non-cursor style: :main-opts aliases in yellow, everything else default.
(define (alias-style ai)
  (if (alias-info-has-main-opts? ai) (style-fg (style) Color/Yellow) #f))

;; Resolve pre-selected names to their alias-info items, preserving the given
;; name order (aliases apply in order) and dropping any name no longer present.
;; Built with cons/reverse rather than map, whose struct-valued callback can
;; miscompile under Helix's Steel.
(define (names->items names aliases)
  (let loop ([ns names] [acc '()])
    (if (null? ns)
      (reverse acc)
      (let ([ai (find-alias aliases (car ns))])
        (loop (cdr ns) (if ai (cons ai acc) acc))))))

(define (find-alias aliases name)
  (cond
    [(null? aliases) #f]
    [(equal? (alias-info-name (car aliases)) name) (car aliases)]
    [else (find-alias (cdr aliases) name)]))

;; The selected items back to names, in the same cons/reverse-safe manner.
(define (items->names items)
  (let loop ([is items] [acc '()])
    (if (null? is)
      (reverse acc)
      (loop (cdr is) (cons (alias-info-name (car is)) acc)))))

;;@doc
;; Show the alias picker.
;;   aliases           - list of alias-info structs
;;   initial-selection - list of alias names to pre-select
;;   callback          - function (list-of-names -> void) called on confirm
(define (show-alias-picker aliases initial-selection callback)
  (show-picker!
    (make-picker #:name "alias-picker"
      #:items
      aliases
      #:item-label
      alias-label
      #:item-style
      alias-style
      #:multi-select?
      #t
      #:initial-selection
      (names->items initial-selection aliases)
      #:title
      "Select aliases for jack-in"
      #:instructions
      "Space: toggle  Enter: confirm  Esc: cancel"
      #:on-accept
      (lambda (items) (callback (items->names items)))
      #:empty-message
      "No aliases to select"))
  ;; Return void (not the box) so nothing is echoed.
  (if #f #f))
