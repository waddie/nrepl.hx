;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; format-docs.scm - Documentation Formatting Utilities
;;;
;;; Functions for formatting symbol documentation into displayable lines
;;; with proper wrapping, styling, and layout. The generic wrapping and
;;; truncation helpers live in ui-utils.hx/strings.scm.

(require-builtin helix/components)
(require (only-in "ui-utils.hx/strings.scm"
          truncate-string/dots
          truncate-left
          word-wrap))

(provide format-symbol-documentation
  format-arglists)

;;;; Documentation Formatting ;;;;

;; Pair each string in `lst` with `sty`, producing (line . style) pairs.
;; Explicit loop, not map: map with a struct-valued callback (styles are FFI
;; structs) can crash Helix's Steel under the full plugin module graph.
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
              (truncate-string/dots formatted max-width)))
        arglists))))
