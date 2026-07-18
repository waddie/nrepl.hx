;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; session-picker.scm - nREPL Session Picker Component
;;;
;;; Single-select picker over the server's sessions (the `ls-sessions` op).
;;; Enter attaches to the selected session (the previous one stays alive on
;;; the server); Ctrl-k kills the selected session, except the currently
;;; attached one. A synthetic "[new session]" first entry clones a fresh
;;; session and attaches to it.
;;;
;;; Items are the wire session id strings plus the 'new-session symbol; all
;;; session semantics live in the caller's callbacks.

(require-builtin helix/components)
(require (only-in "helix/misc.scm" set-status!))
(require (only-in "ui-utils.hx/strings.scm" word-wrap-line))
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker! picker-current-item))
(require (only-in "ui-utils.hx/keys.scm" ctrl-char?))
(require "style-utils.scm")

(provide show-session-picker)

(define (session-label current-wire-id)
  (lambda (item)
    (cond
      [(eq? item 'new-session) "[new session]"]
      [(equal? item current-wire-id) (string-append item "  (current)")]
      [else item])))

;; Preview: what Enter and Ctrl-k do for the selected entry.
(define (session-preview current-wire-id)
  (lambda (item width)
    (let ([text
            (cond
              [(eq? item 'new-session)
                "Enter: clone a fresh session on the server and attach to it."]
              [(equal? item current-wire-id)
                "Currently attached - evals run in this session. Ctrl-k is disabled here; switch sessions first to kill it."]
              [else
                "Enter: attach to this session (the current one stays alive). Ctrl-k: kill this session on the server."])])
      (style-lines (word-wrap-line text width) (style)))))

;; Ctrl-k kills the selected session via on-kill, closing the picker (the
;; caller reopens it with a fresh list). The attached session and the
;; [new session] entry are refused with a status note.
(define (session-keys current-wire-id on-kill)
  (lambda (state-box event)
    (if (ctrl-char? event #\k)
      (let ([item (picker-current-item (unbox state-box))])
        (cond
          [(or (not item) (eq? item 'new-session)) event-result/consume]
          [(equal? item current-wire-id)
            (set-status! "nREPL: cannot kill the attached session; switch first")
            event-result/consume]
          [else
            (on-kill item)
            event-result/close]))
      #f)))

;;@doc
;; Show the session picker.
;;   sessions        - list of wire session id strings (from nrepl:ls-sessions)
;;   current-wire-id - the attached session's wire id, or #f if unknown
;;   on-attach       - function (wire-id -> void) called when a session is chosen
;;   on-new          - function (-> void) called for the [new session] entry
;;   on-kill         - function (wire-id -> void) called on Ctrl-k
(define (show-session-picker sessions current-wire-id on-attach on-new on-kill)
  ;; Discard show-picker!'s state-box return so it does not leak onto Helix's
  ;; echo line as a stringified item list.
  (show-picker!
    (make-picker #:name "session-picker"
      #:items
      (cons 'new-session sessions)
      #:item-label
      (session-label current-wire-id)
      #:title
      "nREPL sessions"
      #:instructions
      "↑/↓ or j/k: move   Enter: attach   Ctrl-k: kill   Esc: cancel"
      #:preview
      (session-preview current-wire-id)
      #:keys
      (session-keys current-wire-id on-kill)
      #:on-accept
      (lambda (item)
        (if (eq? item 'new-session)
          (on-new)
          (on-attach item)))
      #:empty-message
      "No sessions on server"))
  ;; Return void (not the box) so nothing is echoed.
  (if #f #f))
