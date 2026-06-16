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
  "Truncate string to max-width, adding ... if needed.
   Degrades gracefully when max-width is too small for the ellipsis."
  (cond
    [(<= max-width 0) ""]
    [(<= (string-length s) max-width) s]
    ;; Too narrow to fit \"...\" - hard cut instead of underflowing the substring
    [(< max-width 3) (substring s 0 max-width)]
    [else (string-append (substring s 0 (- max-width 3)) "...")]))

(define (truncate-left s max-width)
  "Truncate string from left, keeping right side (for file paths).
   Degrades gracefully when max-width is too small for the ellipsis."
  (cond
    [(<= max-width 0) ""]
    [(<= (string-length s) max-width) s]
    [(< max-width 3) (substring s (- (string-length s) max-width) (string-length s))]
    [else (string-append "..." (substring s (- (string-length s) (- max-width 3))))]))

;;;; Documentation Formatting ;;;;

;; Pair each string in `lst` with `sty`, producing (line . style) pairs.
;; Plain tail recursion over cons/reverse keeps this robust regardless of the
;; underlying list representation (see word-wrap's note on Steel's list quirk).
(define (style-each lst sty)
  (let loop ([xs lst] [acc (list)])
    (if (null? xs)
      (reverse acc)
      (loop (cdr xs) (cons (cons (car xs) sty) acc)))))

(define (format-symbol-documentation info max-width)
  "Format symbol info into displayable lines
   Returns: (list (line . style) ...)"
  (let* ([has-name (hash-contains? info '#:name)]
         [has-ns (hash-contains? info '#:ns)]
         [has-arglists (hash-contains? info '#:arglists)]
         [has-doc (hash-contains? info '#:doc)]
         [wrapped (if has-doc (word-wrap (hash-ref info '#:doc) max-width) (list))]
         [doc-lines (style-each wrapped (style))])
    (append
      ;; Symbol name (bold)
      (if has-name
        (list (cons (hash-ref info '#:name) (style-with-bold (style))))
        (list))

      ;; Namespace (dimmed)
      (if has-ns
        (list (cons (string-append "  " (hash-ref info '#:ns)) (style-fg (style) Color/Gray)))
        (list))

      ;; Blank line after header
      (if (or has-name has-ns)
        (list (cons "" (style)))
        (list))

      ;; Arglists
      (if has-arglists
        (style-each (format-arglists (hash-ref info '#:arglists) max-width)
          (style-fg (style) Color/Cyan))
        (list))

      ;; Blank line after arglists
      (if has-arglists (list (cons "" (style))) (list))

      ;; Documentation (word-wrapped)
      doc-lines

      ;; Blank line after docs
      (if has-doc (list (cons "" (style))) (list))

      ;; File location (left-truncated to show filename)
      (if (and (hash-contains? info '#:file) (hash-contains? info '#:line))
        (let* ([line-val (hash-ref info '#:line)]
               [line-str (if (string? line-val)
                          line-val
                          (number->string line-val))]
               [location (string-append (hash-ref info '#:file) ":" line-str)])
          (list (cons (truncate-left location max-width) (style-fg (style) Color/Gray))))
        (list)))))

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

;; Cons each element of `lst` onto `acc`, in order (left-to-right), so a
;; reverse-accumulated `acc` stays in document order after a final `reverse`.
(define (cons-all lst acc)
  (if (null? lst)
    acc
    (cons-all (cdr lst) (cons (car lst) acc))))

;; Join `lines` into one string, each trimmed and space-separated. Avoids `map`.
(define (join-trimmed lines)
  (let loop ([xs lines]
             [acc ""])
    (if (null? xs)
      acc
      (loop (cdr xs) (string-append acc (trim (car xs)) " ")))))

(define (word-wrap text max-width)
  "Word-wrap text to max-width with full reflow, preserving blank lines.

   Assembled with cons/reverse only (no `append`/`map`): under Helix's bundled
   Steel, building the result with iterative `append` produced a malformed list
   whose `null?`/`pair?`/`car`/`cdr`/`map` reported it empty while `length`
   reported its true size, so downstream traversal silently dropped every line."
  ;; Split on double newlines to preserve paragraph breaks
  (let ([paragraphs (split-many text "\n\n")])
    ;; `acc` accumulates lines in reverse; a blank separator is inserted before
    ;; every paragraph except the first.
    (let loop ([remaining paragraphs]
               [acc (list)]
               [first? #t])
      (if (null? remaining)
        (reverse acc)
        (let* ([para (car remaining)]
               [rest (cdr remaining)]
               ;; Join all lines in the paragraph into one string, then reflow
               [lines (split-many para "\n")]
               [joined (trim (join-trimmed lines))]
               [wrapped (if (string=? joined "")
                         (list "") ; Empty paragraph becomes blank line
                         (word-wrap-line joined max-width))]
               [acc-with-sep (if first? acc (cons "" acc))])
          (loop rest (cons-all wrapped acc-with-sep) #f))))))

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
