;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; format-docs.scm - Documentation Formatting Utilities
;;;
;;; Functions for formatting symbol documentation into displayable lines
;;; with proper wrapping, styling, and layout.

(require-builtin helix/components)

(provide format-symbol-documentation
         format-arglists
         word-wrap
         word-wrap-line
         truncate-string
         truncate-left)

;;;; Utility Functions ;;;;

(define (truncate-string s max-width)
  "Truncate string to max-width, adding ... if needed"
  (if (<= (string-length s) max-width)
      s
      (string-append (substring s 0 (- max-width 3)) "...")))

(define (truncate-left s max-width)
  "Truncate string from left, keeping right side (for file paths)"
  (if (<= (string-length s) max-width)
      s
      (string-append "..." (substring s (- (string-length s) (- max-width 3))))))

;;;; Documentation Formatting ;;;;

(define (format-symbol-documentation info max-width)
  "Format symbol info into displayable lines
   Returns: (list (line . style) ...)"
  (let ([lines (list)])

    ;; Symbol name (bold) - using steel's style functions
    (when (hash-contains? info '#:name)
      (set! lines (cons (cons (hash-ref info '#:name) (style-with-bold (style))) lines)))

    ;; Namespace (dimmed)
    (when (hash-contains? info '#:ns)
      (set! lines
            (cons (cons (string-append "  " (hash-ref info '#:ns)) (style-fg (style) Color/Gray))
                  lines)))

    ;; Blank line after header
    (when (or (hash-contains? info '#:name) (hash-contains? info '#:ns))
      (set! lines (cons (cons "" (style)) lines)))

    ;; Arglists
    (when (hash-contains? info '#:arglists)
      (let ([arglists (format-arglists (hash-ref info '#:arglists) max-width)])
        (for-each (lambda (line) (set! lines (cons (cons line (style-fg (style) Color/Cyan)) lines)))
                  arglists)))

    ;; Blank line after arglists
    (when (hash-contains? info '#:arglists)
      (set! lines (cons (cons "" (style)) lines)))

    ;; Documentation (word-wrapped)
    (when (hash-contains? info '#:doc)
      (let ([doc-lines (word-wrap (hash-ref info '#:doc) max-width)])
        (for-each (lambda (line) (set! lines (cons (cons line (style)) lines))) doc-lines)))

    ;; Blank line after docs
    (when (hash-contains? info '#:doc)
      (set! lines (cons (cons "" (style)) lines)))

    ;; File location (left-truncated to show filename)
    (when (and (hash-contains? info '#:file) (hash-contains? info '#:line))
      (let* ([line-val (hash-ref info '#:line)]
             [line-str (if (string? line-val)
                           line-val
                           (number->string line-val))]
             [location (string-append (hash-ref info '#:file) ":" line-str)]
             [truncated (truncate-left location max-width)])
        (set! lines (cons (cons truncated (style-fg (style) Color/Gray)) lines))))

    (reverse lines)))

(define (format-arglists arglists-str max-width)
  "Format arglists string into lines
   arglists-str is like: \"([f] [f coll] [f c1 c2] ...)\"
   Returns list of formatted arglist strings"

  (let* ([cleaned (trim arglists-str)]
         ;; Remove outer parens if present
         [inner (if (and (> (string-length cleaned) 0)
                         (char=? (string-ref cleaned 0) #\()
                         (char=? (string-ref cleaned (- (string-length cleaned) 1)) #\)))
                    (substring cleaned 1 (- (string-length cleaned) 1))
                    cleaned)])

    ;; Split on "] [" to get individual arglists
    (let ([arglists (split-many inner "] [")])
      (map (lambda (arglist)
             (let ([formatted
                    (string-append
                     "  "
                     (if (not (and (> (string-length arglist) 0) (char=? (string-ref arglist 0) #\[)))
                         (string-append "[" arglist)
                         arglist)
                     (if (not (and (> (string-length arglist) 0)
                                   (char=? (string-ref arglist (- (string-length arglist) 1)) #\])))
                         "]"
                         ""))])
               (truncate-string formatted max-width)))
           arglists))))

(define (word-wrap text max-width)
  "Word-wrap text to max-width with full reflow, preserving blank lines"
  ;; Split on double newlines to preserve paragraph breaks
  (let ([paragraphs (split-many text "\n\n")])
    (let loop ([remaining paragraphs]
               [result (list)])
      (if (null? remaining)
          result
          (let* ([para (car remaining)]
                 [rest (cdr remaining)]
                 ;; Join all lines in the paragraph into one string, then reflow
                 [lines (split-many para "\n")]
                 [joined (trim (apply string-append
                                      (map (lambda (line) (string-append (trim line) " ")) lines)))]
                 [wrapped (if (string=? joined "")
                              (list "") ; Empty paragraph becomes blank line
                              (word-wrap-line joined max-width))]
                 ;; Add blank line separator between paragraphs (except after last)
                 [with-separator (if (null? rest)
                                     wrapped
                                     (append wrapped (list "")))])
            (loop rest (append result with-separator)))))))

(define (word-wrap-line line max-width)
  "Word-wrap a single line"
  (if (<= (string-length line) max-width)
      (list line)
      (let ([words (split-many line " ")])
        (let loop ([remaining words]
                   [current-line ""]
                   [result (list)])
          (if (null? remaining)
              (if (string=? current-line "")
                  (reverse result)
                  (reverse (cons current-line result)))
              (let* ([word (car remaining)]
                     [test-line (if (string=? current-line "")
                                    word
                                    (string-append current-line " " word))])
                (cond
                  ;; Word fits on current line
                  [(<= (string-length test-line) max-width) (loop (cdr remaining) test-line result)]

                  ;; Current line is empty but word is too long - truncate it
                  [(string=? current-line "")
                   (loop (cdr remaining) "" (cons (truncate-string word max-width) result))]

                  ;; Current line has content - start new line with this word
                  [else (loop (cdr remaining) word (cons current-line result))])))))))
