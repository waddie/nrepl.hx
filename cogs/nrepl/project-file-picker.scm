;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; project-file-picker.scm - Project File Picker Component
;;;
;;; Interactive picker for selecting a project manifest when jack-in finds more
;;; than one. Files are listed workspace-relative in a two-column layout (path,
;;; type), fuzzy-filtered, with a preview of each file's first lines.
;;;
;;; The list, filter, columns, preview and key handling come from ui-utils.hx's
;;; make-picker. This module supplies the relative-path label, the type column,
;;; and the memoised file preview.

(require-builtin helix/components)
(require (only-in "ui-utils.hx/picker.scm" make-picker show-picker!))
(require (only-in "ui-utils.hx/picker-model.scm" picker-column))
(require "file-utils.scm")
(require "project-file-types.scm")
(require "style-utils.scm")

(provide show-project-file-picker)

(define PREVIEW-LINES 50) ; lines of file content to show in the preview
(define TYPE-COLUMN-WIDTH 16)

;; Preview: the file's first PREVIEW-LINES lines, memoised per path. Returns #f
;; when the file cannot be read, so make-picker shows the missing message.
(define (make-file-preview)
  (let ([cache (box (hash))])
    (lambda (filepath width)
      (let ([c (unbox cache)])
        (if (hash-contains? c filepath)
          (hash-ref c filepath)
          (let* ([text (read-file-preview filepath PREVIEW-LINES)]
                 [lines (if text (style-lines (split-many text "\n") (style)) #f)])
            (set-box! cache (hash-insert c filepath lines))
            lines))))))

;;@doc
;; Show the project file picker.
;;   workspace-root - workspace root directory (paths shown relative to it)
;;   files          - list of absolute file paths to choose from
;;   callback       - function (filepath -> void) called with the selected path
;;   toggle-keys    - custom key handler ((state-box event) -> event-result
;;                    or #f) for toggling to the server picker, or #f. When
;;                    supplied the picker also opens with zero files, showing
;;                    the empty message in the body so the toggle back works.
(define (show-project-file-picker workspace-root files callback toggle-keys)
  (when workspace-root
    (let ([rel (lambda (f) (get-relative-path f workspace-root))])
      (show-picker!
        (make-picker #:name "project-file-picker"
          #:items
          (sort-files-by-distance files workspace-root)
          #:item-label
          rel
          #:columns
          (list
            (picker-column "Project File" 'flex rel 'left)
            (picker-column "Type" TYPE-COLUMN-WIDTH get-file-type-label))
          #:filter?
          #t
          #:preview
          (make-file-preview)
          #:preview-empty
          "No file selected"
          #:preview-missing
          "Could not load preview"
          #:selected-style
          'theme
          #:instructions
          (if toggle-keys "Ctrl-t: server picker   Esc: cancel" #f)
          #:keys
          (or toggle-keys (lambda (state-box event) #f))
          #:on-accept
          callback
          #:allow-empty?
          (and toggle-keys #t)
          #:empty-message
          "No project files found"))))
  ;; Return void (not the box) so nothing is echoed.
  (if #f #f))
