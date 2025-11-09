;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; file-utils.scm - File System Utilities
;;;
;;; Common file system operations for working with project files.

(require-builtin steel/process)
(require-builtin steel/ports)

(require "cogs/nrepl/sorting-utils.scm")

(provide scan-directory-recursive
         read-file-preview
         get-relative-path
         is-file?
         is-dir?
         sort-files-by-distance)

;;;; File System Operations ;;;;

;;@doc
;; Check if path is a regular file.
;;
;; Parameters:
;;   path - File path to check
;;
;; Returns:
;;   Boolean - #t if path exists and is a file
(define (is-file? path)
  (with-handler (lambda (err) #f)
                (let* ([cmd (command "sh" (list "-c" (string-append "[ -f \"" path "\" ]")))]
                       [child-result (spawn-process cmd)]
                       [child (Ok->value child-result)]
                       [exit-code-result (wait child)]
                       [exit-code (Ok->value exit-code-result)])
                  (equal? exit-code 0))))

;;@doc
;; Check if path is a directory.
;;
;; Parameters:
;;   path - Directory path to check
;;
;; Returns:
;;   Boolean - #t if path exists and is a directory
(define (is-dir? path)
  (with-handler (lambda (err) #f)
                (let* ([cmd (command "sh" (list "-c" (string-append "[ -d \"" path "\" ]")))]
                       [child-result (spawn-process cmd)]
                       [child (Ok->value child-result)]
                       [exit-code-result (wait child)]
                       [exit-code (Ok->value exit-code-result)])
                  (equal? exit-code 0))))

;;;; Directory Scanning ;;;;

;;@doc
;; Recursively scan directory for files matching patterns.
;;
;; Uses `find` command to traverse directories and locate project files.
;; Returns list of absolute paths.
;;
;; Parameters:
;;   root-dir - Root directory to scan
;;   patterns - List of filename patterns (e.g., '("deps.edn" "bb.edn" "package.json"))
;;
;; Returns:
;;   List of absolute file paths, or empty list on error
;;
;; Example:
;;   (scan-directory-recursive "/workspace" '("deps.edn" "bb.edn"))
;;   => ("/workspace/deps.edn" "/workspace/subproject/bb.edn")
(define (scan-directory-recursive root-dir patterns)
  (if (or (not root-dir) (null? patterns))
      (list)
      (with-handler
       (lambda (err) (list)) ; Return empty list on error
       (let* ([find-expr (build-find-expression patterns)]
              [find-cmd
               (string-append "find \"" root-dir "\" -type f \\( " find-expr " \\) 2>/dev/null")]
              [cmd (command "sh" (list "-c" find-cmd))]
              [_ (set-piped-stdout! cmd)]
              [child-result (spawn-process cmd)])
         (if (Err? child-result)
             (list)
             (let* ([child (Ok->value child-result)]
                    [stdout-result (wait->stdout child)])
               (if (Err? stdout-result)
                   (list)
                   (let* ([stdout-str (Ok->value stdout-result)]
                          [split-lines (split-many stdout-str "\n")]
                          [filtered-lines (filter (lambda (line) (not (string=? line "")))
                                                  split-lines)])
                     filtered-lines))))))))

(define (build-find-expression patterns)
  "Build find expression for -name patterns.
   Example: '(\"deps.edn\" \"bb.edn\") => \"-name deps.edn -o -name bb.edn\""
  (apply string-append
         (let loop ([remaining patterns]
                    [result (list)])
           (if (null? remaining)
               (reverse result)
               (let ([pattern (car remaining)]
                     [rest (cdr remaining)])
                 (if (null? result)
                     ;; First pattern - no -o prefix
                     (loop rest (cons (string-append "-name \"" pattern "\"") result))
                     ;; Subsequent patterns - add -o
                     (loop rest
                           (cons (string-append "-name \"" pattern "\"") (cons " -o " result)))))))))

;;;; File Reading ;;;;

;;@doc
;; Read first N lines of file for preview.
;;
;; Parameters:
;;   filepath - Path to file
;;   max-lines - Maximum number of lines to read
;;
;; Returns:
;;   String containing first max-lines of file, or #f on error
;;
;; Example:
;;   (read-file-preview "/path/to/deps.edn" 50)
(define (read-file-preview filepath max-lines)
  (if (not (is-file? filepath))
      #f
      (with-handler (lambda (err) #f) ; Return #f on read error
                    (let* ([port (open-input-file filepath)]
                           [lines (read-lines port max-lines)])
                      (close-input-port port)
                      (if (null? lines)
                          ""
                          (apply string-append
                                 (map (lambda (line) (string-append line "\n")) lines)))))))

(define (read-lines port max-lines)
  "Read up to max-lines from port. Returns list of strings."
  (let loop ([count 0]
             [result (list)])
    (if (>= count max-lines)
        (reverse result)
        (let ([line (read-line-from-port port)])
          (if (eof-object? line)
              (reverse result)
              (loop (+ count 1) (cons line result)))))))

(define (read-line-from-port port)
  "Read single line from port (without newline). Returns eof-object on EOF."
  (let loop ([chars (list)])
    (let ([ch (read-char port)])
      (cond
        [(eof-object? ch)
         (if (null? chars)
             ch
             (list->string (reverse chars)))]
        [(char=? ch #\newline) (list->string (reverse chars))]
        [else (loop (cons ch chars))]))))

;;;; Path Manipulation ;;;;

;;@doc
;; Convert absolute path to relative path from workspace root.
;;
;; Parameters:
;;   absolute-path - Full path
;;   workspace-root - Workspace root directory
;;
;; Returns:
;;   Relative path string, or absolute path if conversion fails
;;
;; Example:
;;   (get-relative-path "/workspace/sub/deps.edn" "/workspace")
;;   => "sub/deps.edn"
(define (get-relative-path absolute-path workspace-root)
  (if (or (not absolute-path) (not workspace-root))
      absolute-path
      (let* ([root-with-slash (if (string-suffix? workspace-root "/")
                                  workspace-root
                                  (string-append workspace-root "/"))]
             [root-len (string-length root-with-slash)])
        (if (and (>= (string-length absolute-path) root-len)
                 (string=? (substring absolute-path 0 root-len) root-with-slash))
            ;; Path starts with workspace root - strip it
            (substring absolute-path root-len (string-length absolute-path))
            ;; Path doesn't start with workspace root - return as is
            absolute-path))))

(define (string-suffix? s suffix)
  "Check if string s ends with suffix"
  (let ([s-len (string-length s)]
        [suffix-len (string-length suffix)])
    (and (>= s-len suffix-len) (string=? (substring s (- s-len suffix-len) s-len) suffix))))

;;;; File Sorting ;;;;

;;@doc
;; Sort files by distance from root (depth), then alphabetically.
;;
;; Files closer to the root (fewer directory levels) come first.
;; Within the same depth, files are sorted alphabetically.
;;
;; Parameters:
;;   files - List of absolute file paths
;;   workspace-root - Workspace root directory
;;
;; Returns:
;;   Sorted list of file paths
;;
;; Example:
;;   (sort-files-by-distance '("/ws/deps.edn" "/ws/sub/bb.edn" "/ws/project.clj") "/ws")
;;   => ("/ws/deps.edn" "/ws/project.clj" "/ws/sub/bb.edn")
(define (sort-files-by-distance files workspace-root)
  (if (or (null? files) (not workspace-root))
      files
      (let ([files-with-depth (map (lambda (filepath)
                                     (let* ([rel-path (get-relative-path filepath workspace-root)]
                                            [depth (count-path-separators rel-path)])
                                       (list depth filepath)))
                                   files)])
        ;; Sort by depth first, then by filepath
        (map (lambda (pair) (cadr pair))
             (sort files-with-depth
                   (lambda (a b)
                     (let ([depth-a (car a)]
                           [depth-b (car b)]
                           [path-a (cadr a)]
                           [path-b (cadr b)])
                       (if (= depth-a depth-b)
                           ;; Same depth - sort alphabetically
                           (string<? path-a path-b)
                           ;; Different depth - sort by depth
                           (< depth-a depth-b)))))))))

(define (count-path-separators path)
  "Count number of '/' characters in path"
  (let loop ([i 0]
             [count 0])
    (if (>= i (string-length path))
        count
        (loop (+ i 1)
              (if (char=? (string-ref path i) #\/)
                  (+ count 1)
                  count)))))
