;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Project detection for nREPL jack-in
;; Detects Clojure/Babashka projects and parses configuration

(require "steel/result")
(require-builtin steel/process)
(require "cogs/nrepl/string-utils.scm")
(require "cogs/nrepl/file-utils.scm")
(require "cogs/nrepl/project-file-types.scm")

(provide project-info
         make-project-info
         project-info-project-type
         project-info-project-root
         project-info-project-file
         project-info-aliases
         project-info-has-nrepl-port?
         detect-project
         detect-project-from-file
         find-project-files
         find-project-files-recursive
         alias-info
         make-alias-info
         alias-info-name
         alias-info-has-main-opts?
         alias-info-description)

;;; Project info struct

(struct project-info
        (project-type ; 'clojure-cli, 'babashka, 'leiningen, or #f
         project-root ; Path to workspace root
         project-file ; Path to project file (deps.edn, etc.)
         aliases ; List of alias-info structs or #f
         has-nrepl-port?) ; Boolean: does .nrepl-port exist?
  #:transparent)

(define (make-project-info project-type project-root project-file aliases has-nrepl-port?)
  "Constructor for project-info"
  (project-info project-type project-root project-file aliases has-nrepl-port?))

;;; Alias info struct

(struct alias-info
        (name ; String: alias name without leading : (e.g., "dev")
         has-main-opts? ; Boolean: does this alias define :main-opts?
         description) ; String or #f: optional description/doc
  #:transparent)

(define (make-alias-info name has-main-opts? description)
  "Constructor for alias-info"
  (alias-info name has-main-opts? description))

;;; Project file detection

(define (find-project-files workspace-root)
  "Find project files in workspace root.
   Returns list of (type . path) pairs, e.g., (('clojure-cli . \"/path/deps.edn\") ...)"
  (let* ([deps-edn (string-append workspace-root "/deps.edn")]
         [bb-edn (string-append workspace-root "/bb.edn")]
         [project-clj (string-append workspace-root "/project.clj")])
    ;; Build list of found project files
    (filter (lambda (item) item) ; Remove #f entries
            (list (if (is-file? deps-edn)
                      (cons 'clojure-cli deps-edn)
                      #f)
                  (if (is-file? bb-edn)
                      (cons 'babashka bb-edn)
                      #f)
                  (if (is-file? project-clj)
                      (cons 'leiningen project-clj)
                      #f)))))

(define (has-nrepl-port-file? workspace-root)
  "Check if .nrepl-port file exists"
  (is-file? (string-append workspace-root "/.nrepl-port")))

;;; deps.edn alias parsing

(define (parse-deps-edn-aliases deps-edn-path)
  "Parse deps.edn and extract alias information.
   Returns list of alias-info structs with name, has-main-opts?, and description"
  ;; Check if file exists first to avoid errors
  (if (not (is-file? deps-edn-path))
      (list) ; Return empty list if file doesn't exist
      (let* ([content (read-port-to-string (open-input-file deps-edn-path))]
             [aliases (extract-alias-info content)])
        (helix.echo
         (string-append "nREPL: Found " (to-string (length aliases)) " aliases in " deps-edn-path))
        aliases)))

(define (find-in-plist plist key)
  "Find value for key in plist (alternating key-value list)"
  (if (null? plist)
      #f
      (if (equal? (car plist) key)
          (if (null? (cdr plist))
              #f
              (cadr plist))
          (find-in-plist (cdr plist) key))))

(define (extract-alias-info content)
  "Extract alias information from deps.edn content using EDN parsing.
   Returns list of alias-info structs with name, has-main-opts?, description.
   Only returns TOP-LEVEL aliases, not nested keywords.

   Note: Steel's read function parses EDN as S-expressions (plists),
   so {:a 1 :b 2} becomes (:a 1 :b 2) as an alternating key-value list."
  (let* ([data (read (open-input-string content))])
    ;; data is a plist like (:deps ... :aliases ...)
    (if (list? data)
        (let ([aliases-value (find-in-plist data ':aliases)])
          (if aliases-value
              ;; aliases-value is also a plist like (:dev ... :test ... :poly ...)
              (if (list? aliases-value)
                  (let loop ([remaining aliases-value]
                             [result (list)])
                    (if (null? remaining)
                        (reverse result)
                        (if (null? (cdr remaining))
                            (reverse result) ; Odd number of elements, done
                            (let* ([alias-key (car remaining)]
                                   [alias-config (cadr remaining)]
                                   ;; Convert keyword to string (remove leading :)
                                   [alias-name (let ([key-str (to-string alias-key)])
                                                 (if (equal? (substring key-str 0 1) ":")
                                                     (substring key-str 1 (string-length key-str))
                                                     key-str))]
                                   ;; Check if config has :main-opts
                                   [has-main? (if (list? alias-config)
                                                  (if (find-in-plist alias-config ':main-opts) #t #f)
                                                  #f)])
                              (loop (cddr remaining)
                                    (cons (make-alias-info alias-name has-main? #f) result))))))
                  (list))
              (list)))
        (list))))

;;; Project detection

(define (detect-project)
  "Detect project type in current workspace.
   Returns project-info struct or #f if no project found."
  (let* ([workspace-root (helix-find-workspace)])
    (if (not workspace-root)
        #f
        (let* ([project-files (find-project-files workspace-root)]
               [has-port? (has-nrepl-port-file? workspace-root)])
          (if (null? project-files)
              #f
              ;; Prioritize: bb.edn > deps.edn > project.clj
              (let* ([prioritized (prioritize-project-files project-files)])
                (let* ([project-type (car prioritized)]
                       [project-file (cdr prioritized)]
                       [aliases (if (equal? project-type 'clojure-cli)
                                    (let* ([all-aliases (parse-deps-edn-aliases project-file)])
                                      (if (null? all-aliases)
                                          #f ; No aliases found
                                          all-aliases))
                                    #f)])
                  (make-project-info project-type
                                     workspace-root
                                     project-file
                                     aliases
                                     has-port?))))))))

(define (prioritize-project-files project-files)
  "Prioritize project files: bb.edn > deps.edn > project.clj
   Returns (type . path) pair for highest priority file found."
  (let ([bb (filter (lambda (p) (equal? (car p) 'babashka)) project-files)]
        [deps (filter (lambda (p) (equal? (car p) 'clojure-cli)) project-files)]
        [lein (filter (lambda (p) (equal? (car p) 'leiningen)) project-files)])
    (cond
      [(not (null? bb)) (car bb)]
      [(not (null? deps)) (car deps)]
      [(not (null? lein)) (car lein)]
      [else (car project-files)]))) ; Shouldn't reach here but return first as fallback

;;;; Recursive Project File Detection ;;;;

(define (find-project-files-recursive workspace-root)
  "Recursively find all project files in workspace.
   Returns list of absolute file paths.
   Uses extensible project file type registry to scan for all known project files."
  (if (not workspace-root)
      (list)
      (let* ([patterns (get-all-project-filenames)]
             [found-files (scan-directory-recursive workspace-root patterns)])
        found-files)))

(define (detect-project-from-file filepath)
  "Detect project info from specific project file path.
   Returns project-info struct or #f if file doesn't exist or isn't recognized.

   Parameters:
     filepath - Absolute path to project file (e.g., \"/workspace/deps.edn\")

   Returns:
     project-info struct with project-type, project-root, etc., or #f"
  (if (or (not filepath) (not (is-file? filepath)))
      #f
      (let* ([project-type (detect-file-type filepath)]
             [project-root (extract-project-root filepath)])
        (if (not project-type)
            #f
            (let* ([has-port? (has-nrepl-port-file? project-root)]
                   [aliases (if (equal? project-type 'clojure-cli)
                                (let* ([all-aliases (parse-deps-edn-aliases filepath)])
                                  (if (null? all-aliases) #f all-aliases))
                                #f)])
              (make-project-info project-type project-root filepath aliases has-port?))))))

(define (extract-project-root filepath)
  "Extract project root directory from file path.
   Returns directory containing the project file.
   Example: \"/workspace/sub/deps.edn\" => \"/workspace/sub\""
  (let ([last-slash (find-last-char filepath #\/)])
    (if last-slash
        (substring filepath 0 last-slash)
        filepath)))

(define (find-last-char s ch)
  "Find index of last occurrence of char ch in string s. Returns index or #f."
  (let ([len (string-length s)])
    (let loop ([i (- len 1)])
      (cond
        [(< i 0) #f]
        [(char=? (string-ref s i) ch) i]
        [else (loop (- i 1))]))))
