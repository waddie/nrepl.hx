;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; scheme-server-picker.scm - Scheme Server Picker Component
;;;
;;; Single-select picker for choosing how to launch a Scheme nREPL server during
;;; jack-in. The preview pane shows the exact shell command the selected method
;;; will run, resolved with the chosen workspace root and port.

(require-builtin helix/components)
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require "helix/misc.scm")

(require "ui-utils.scm")
(require "picker-utils.scm")
(require "format-docs.scm") ; truncate-string
(require "scheme-servers.scm")

(provide show-scheme-server-picker)

;;;; State ;;;;

(struct SchemeServerPickerState
  (servers ; list of scheme-server descriptors
    cursor-index ; integer: current selection
    workspace-root ; string: for resolving the previewed command
    port ; integer: for resolving the previewed command
    callback) ; function (scheme-server -> void)
  #:transparent)

(define (make-scheme-server-picker-state servers workspace-root port callback)
  (SchemeServerPickerState servers 0 workspace-root port callback))

;;;; Selection ;;;;

(define (selected-server state)
  (let ([servers (SchemeServerPickerState-servers state)]
        [idx (SchemeServerPickerState-cursor-index state)])
    (if (and (>= idx 0) (< idx (length servers)))
      (list-ref servers idx)
      #f)))

(define (move-cursor state delta)
  "Move cursor by delta with wrapping. Returns new state."
  (let* ([count (length (SchemeServerPickerState-servers state))]
         [current (SchemeServerPickerState-cursor-index state)]
         [next (+ current delta)]
         [new-index (cond
                     [(< next 0) (- count 1)]
                     [(>= next count) 0]
                     [else next])])
    (SchemeServerPickerState (SchemeServerPickerState-servers state)
      new-index
      (SchemeServerPickerState-workspace-root state)
      (SchemeServerPickerState-port state)
      (SchemeServerPickerState-callback state))))

;;;; Rendering ;;;;

(define (render-scheme-server-picker state-box rect buffer)
  (let* ([state (unbox state-box)]
         [overlay-area (apply-overlay-transform rect)]
         [layout (apply-two-pane-layout overlay-area)]
         [show-preview (hash-ref layout '#:show-preview)]
         [picker-area (hash-ref layout '#:picker-area)]
         [preview-area (hash-ref layout '#:preview-area)]
         [picker-width (hash-ref layout '#:picker-width)]
         [preview-width (hash-ref layout '#:preview-width)])

    (buffer/clear buffer overlay-area)

    ;; Borders
    (let ([border-style (make-block (theme->bg *helix.cx*) (theme->bg *helix.cx*) "all" "plain")])
      (block/render buffer picker-area border-style)
      (when show-preview
        (block/render buffer preview-area border-style)))

    ;; Picker pane
    (let* ([px (+ (area-x picker-area) 2)]
           [py (+ (area-y picker-area) 1)])
      (frame-set-string! buffer px py "Select Scheme nREPL server" (style))
      (frame-set-string! buffer px (+ py 1) "↑/↓ or j/k: move   Enter: start   Esc: cancel"
        (style-fg (style) Color/Gray))
      (draw-server-list buffer px (+ py 3) (- picker-width 4) state))

    ;; Preview pane (resolved command + description)
    (when show-preview
      (let ([prx (+ (area-x preview-area) 2)]
            [pry (+ (area-y preview-area) 1)])
        (draw-preview buffer prx pry (- preview-width 4) (- (area-height preview-area) 2) state)))))

(define (draw-server-list buffer x y width state)
  (let ([servers (SchemeServerPickerState-servers state)]
        [cursor (SchemeServerPickerState-cursor-index state)])
    (let loop ([i 0])
      (when (< i (length servers))
        (let* ([server (list-ref servers i)]
               [is-cursor (= i cursor)]
               [prefix (if is-cursor "> " "  ")]
               [line (string-append prefix (scheme-server-label server))]
               [line-style (if is-cursor (style-fg (style) Color/Blue) (style))])
          (frame-set-string! buffer x (+ y i) (truncate-string line width) line-style)
          (loop (+ i 1)))))))

(define (draw-preview buffer x y width height state)
  (let ([server (selected-server state)])
    (when server
      (let* ([workspace-root (SchemeServerPickerState-workspace-root state)]
             [port (SchemeServerPickerState-port state)]
             [cmd (scheme-server-command server workspace-root port)]
             [description (scheme-server-description server)]
             ;; Build preview lines: description, blank, "Command:", then the
             ;; command wrapped to the pane width.
             [lines (append
                     (wrap-text description width)
                     (list "" "Command:")
                     (wrap-text cmd width))])
        (let loop ([i 0])
          (when (and (< i (length lines)) (< i height))
            (let ([line (list-ref lines i)]
                  [line-style (if (>= i (- (length lines) (length (wrap-text cmd width))))
                               (style-fg (style) Color/Green)
                               (style))])
              (frame-set-string! buffer x (+ y i) (truncate-string line width) line-style)
              (loop (+ i 1)))))))))

;; Greedy word wrap to a given width. Returns a list of lines.
(define (wrap-text text width)
  (if (<= width 0)
    (list text)
    (let ([words (split-many text " ")])
      (let loop ([remaining words]
                 [current ""]
                 [acc '()])
        (cond
          [(null? remaining)
            (reverse (if (string=? current "") acc (cons current acc)))]
          [(string=? current "")
            (loop (cdr remaining) (car remaining) acc)]
          [(<= (+ (string-length current) 1 (string-length (car remaining))) width)
            (loop (cdr remaining) (string-append current " " (car remaining)) acc)]
          [else
            (loop (cdr remaining) (car remaining) (cons current acc))])))))

;;;; Event Handling ;;;;

(define (handle-scheme-server-picker-event state-box event)
  (let ([state (unbox state-box)])
    (cond
      [(key-event-escape? event) event-result/close]

      [(key-event-enter? event)
        (let ([server (selected-server state)]
              [callback (SchemeServerPickerState-callback state)])
          (when (and server callback)
            (callback server))
          event-result/close)]

      [(or (key-event-up? event)
          (and (key-event-char event) (equal? (key-event-char event) #\k)))
        (set-box! state-box (move-cursor state -1))
        event-result/consume]

      [(or (key-event-down? event)
          (and (key-event-char event) (equal? (key-event-char event) #\j)))
        (set-box! state-box (move-cursor state 1))
        event-result/consume]

      [else event-result/consume])))

(define (cursor-handler state-box rect) #f)

;;;; Public API ;;;;

;;@doc
;; Show the Scheme server picker.
;;   servers        - list of scheme-server descriptors
;;   workspace-root - string, for resolving the previewed command
;;   port           - integer, for resolving the previewed command
;;   callback       - function (scheme-server -> void) called on selection
(define (show-scheme-server-picker servers workspace-root port callback)
  (if (null? servers)
    (helix.echo "No Scheme servers to select")
    (let* ([state (make-scheme-server-picker-state servers workspace-root port callback)]
           [state-box (box state)]
           [function-map (hash "handle_event" handle-scheme-server-picker-event
                          "cursor"
                          cursor-handler)]
           [component (new-component! "scheme-server-picker" state-box
                       render-scheme-server-picker
                       function-map)])
      (push-component! component))))
