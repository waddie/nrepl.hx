;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; project-file-types.scm - Extensible Project File Type Registry
;;;
;;; Defines known project file types and provides detection/labeling functions.

(provide PROJECT_FILE_TYPES
         detect-file-type
         get-file-type-label
         get-file-type-language
         get-all-project-filenames)

;;;; Project File Type Registry ;;;;

;; Structure: (filename project-type label language)
;; - filename: Exact filename to match (e.g., "deps.edn")
;; - project-type: Symbol identifier (e.g., 'clojure-cli)
;; - label: Human-readable description (e.g., "Clojure CLI")
;; - language: Programming language (e.g., "Clojure")

(define PROJECT_FILE_TYPES
  (list (list "deps.edn" 'clojure-cli "Clojure CLI" "Clojure")
        (list "bb.edn" 'babashka "Babashka" "Clojure")
        (list "project.clj" 'leiningen "Leiningen" "Clojure")
        (list "shadow-cljs.edn" 'shadow-cljs "Shadow CLJS" "ClojureScript")
        ;; Python
        (list "pyproject.toml" 'python-poetry "Python Poetry" "Python")
        (list "setup.py" 'python-setuptools "Python Setuptools" "Python")
        (list "Pipfile" 'python-pipenv "Python Pipenv" "Python")
        (list "requirements.txt" 'python-pip "Python Pip" "Python")))

;; POSSIBLE FUTURE SUPPORT
;; JavaScript/TypeScript
; (list "package.json" 'npm "Node.js/NPM" "JavaScript")
; (list "deno.json" 'deno "Deno" "JavaScript")
; (list "bun.lockb" 'bun "Bun" "JavaScript")
;; Rust
; (list "Cargo.toml" 'rust-cargo "Rust Cargo" "Rust")
;; Go
; (list "go.mod" 'go-modules "Go Modules" "Go")
;; Ruby
; (list "Gemfile" 'ruby-bundler "Ruby Bundler" "Ruby")
;; Java/JVM
; (list "pom.xml" 'maven "Maven" "Java")
; (list "build.gradle" 'gradle "Gradle" "Java")
; (list "build.gradle.kts" 'gradle-kotlin "Gradle Kotlin DSL" "Kotlin")
;; Other
; (list "Makefile" 'make "Makefile" "Make")
; (list "CMakeLists.txt" 'cmake "CMake" "C/C++"

;;;; Detection Functions ;;;;

;;@doc
;; Detect project file type from filepath.
;;
;; Parameters:
;;   filepath - Absolute or relative path to project file
;;
;; Returns:
;;   Project type symbol (e.g., 'clojure-cli), or #f if unknown
;;
;; Example:
;;   (detect-file-type "/workspace/deps.edn") => 'clojure-cli
;;   (detect-file-type "/workspace/unknown.txt") => #f
(define (detect-file-type filepath)
  (if (not filepath)
      #f
      (let ([filename (extract-filename filepath)])
        (let loop ([types PROJECT_FILE_TYPES])
          (if (null? types)
              #f
              (let* ([entry (car types)]
                     [pattern (car entry)]
                     [project-type (cadr entry)])
                (if (string=? filename pattern)
                    project-type
                    (loop (cdr types)))))))))

;;@doc
;; Get human-readable label for project file type.
;;
;; Parameters:
;;   filepath - Absolute or relative path to project file
;;
;; Returns:
;;   Label string (e.g., "Clojure CLI"), or "Unknown" if not recognized
;;
;; Example:
;;   (get-file-type-label "/workspace/deps.edn") => "Clojure CLI"
(define (get-file-type-label filepath)
  (if (not filepath)
      "Unknown"
      (let ([filename (extract-filename filepath)])
        (let loop ([types PROJECT_FILE_TYPES])
          (if (null? types)
              "Unknown"
              (let* ([entry (car types)]
                     [pattern (car entry)]
                     [label (caddr entry)])
                (if (string=? filename pattern)
                    label
                    (loop (cdr types)))))))))

;;@doc
;; Get programming language for project file.
;;
;; Parameters:
;;   filepath - Absolute or relative path to project file
;;
;; Returns:
;;   Language string (e.g., "Clojure"), or "Unknown" if not recognized
;;
;; Example:
;;   (get-file-type-language "/workspace/deps.edn") => "Clojure"
(define (get-file-type-language filepath)
  (if (not filepath)
      "Unknown"
      (let ([filename (extract-filename filepath)])
        (let loop ([types PROJECT_FILE_TYPES])
          (if (null? types)
              "Unknown"
              (let* ([entry (car types)]
                     [pattern (car entry)]
                     [language (cadddr entry)])
                (if (string=? filename pattern)
                    language
                    (loop (cdr types)))))))))

;;@doc
;; Get list of all known project filenames for scanning.
;;
;; Returns:
;;   List of filename strings (e.g., '("deps.edn" "bb.edn" ...))
;;
;; Example:
;;   (get-all-project-filenames)
;;   => ("deps.edn" "bb.edn" "project.clj" "package.json" ...)
(define (get-all-project-filenames)
  (map car PROJECT_FILE_TYPES))

;;;; Helper Functions ;;;;

(define (extract-filename filepath)
  "Extract filename from path (last component after /).
   Example: \"/path/to/deps.edn\" => \"deps.edn\""
  (let ([parts (split-path filepath)])
    (if (null? parts)
        filepath
        (car (reverse parts)))))

(define (split-path path)
  "Split path on / into list of components"
  (let loop ([start 0]
             [result (list)])
    (let ([slash-pos (find-char-in-string path #\/ start)])
      (if (not slash-pos)
          ;; No more slashes - add final part
          (reverse (cons (substring path start (string-length path)) result))
          ;; Found slash - extract part and continue
          (let ([part (substring path start slash-pos)])
            (loop (+ slash-pos 1)
                  (if (string=? part "")
                      result ; Skip empty parts (e.g., leading /)
                      (cons part result))))))))

(define (find-char-in-string s ch start)
  "Find first occurrence of char ch in string s starting at index start.
   Returns index or #f if not found."
  (let ([len (string-length s)])
    (let loop ([i start])
      (cond
        [(>= i len) #f]
        [(char=? (string-ref s i) ch) i]
        [else (loop (+ i 1))]))))
