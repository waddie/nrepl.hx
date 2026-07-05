;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; server-picker.scm - nREPL Server Recipe Picker Component
;;;
;;; Single-select picker for choosing how to launch an nREPL server during
;;; jack-in when there is no project manifest to detect (Scheme and the Clojure
;;; fallback). The preview pane shows the exact shell command the selected recipe
;;; will run, resolved with the chosen workspace root and port. The title is
;;; supplied by the caller so the same component serves any language.
;;;
;;; The list, preview, scrolling and key handling come from ui-utils.hx's
;;; make-picker; this module supplies only the recipe label, the command
;;; preview, and the accept callback.

(require-builtin helix/components)
(require (only-in "ui-utils.hx/strings.scm" word-wrap-line))
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker!))
(require "server-recipe.scm")

(provide show-server-picker)

;; Pair each line with a style without map (whose struct-carrying callback can
;; miscompile under Helix's Steel).
(define (style-lines lines st)
  (let loop ([ls lines] [acc '()])
    (if (null? ls)
      (reverse acc)
      (loop (cdr ls) (cons (cons (car ls) st) acc)))))

;; Preview: the recipe description, then the resolved shell command in green,
;; each word-wrapped to the pane width.
(define (recipe-preview workspace-root port)
  (lambda (recipe width)
    (let ([description (server-recipe-description recipe)]
          [cmd (server-recipe-command recipe workspace-root port)])
      (append
        (style-lines (word-wrap-line description width) (style))
        (list (cons "" (style)) (cons "Command:" (style)))
        (style-lines (word-wrap-line cmd width) (style-fg (style) Color/Green))))))

;;@doc
;; Show the server recipe picker.
;;   title          - string, header shown above the list
;;   recipes        - list of server-recipe descriptors
;;   workspace-root - string, for resolving the previewed command
;;   port           - integer, for resolving the previewed command
;;   callback       - function (server-recipe -> void) called on selection
(define (show-server-picker title recipes workspace-root port callback)
  ;; Discard show-picker!'s state-box return so it does not leak onto Helix's
  ;; echo line as a stringified item list.
  (show-picker!
    (make-picker #:name "server-picker"
      #:items
      recipes
      #:item-label
      server-recipe-label
      #:title
      title
      #:instructions
      "↑/↓ or j/k: move   Enter: start   Esc: cancel"
      #:preview
      (recipe-preview workspace-root port)
      #:on-accept
      callback
      #:empty-message
      "No nREPL servers to select"))
  ;; Return void (not the box) so nothing is echoed.
  (if #f #f))
