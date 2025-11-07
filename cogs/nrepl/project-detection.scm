;; Project detection for nREPL jack-in
;; Detects Clojure/Babashka projects and parses configuration

(require "steel/result")
(require-builtin steel/process)
(require "cogs/nrepl/string-utils.scm")

(provide project-info
         make-project-info
         project-info-project-type
         project-info-project-root
         project-info-project-file
         project-info-aliases
         project-info-has-nrepl-port?
         detect-project
         find-project-files
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
      (let* ([content (read-port-to-string (open-input-file deps-edn-path))])
        ;; Extract aliases with metadata
        (extract-alias-info content))))

(define (extract-alias-info content)
  "Extract alias information from deps.edn content.
   Returns list of alias-info structs with name, has-main-opts?, description"
  ;; Token-based approach: split on whitespace and braces, find keywords
  (if (not (string-contains? content ":aliases"))
      (list) ; No :aliases found
      ;; Process entire content (filter will exclude non-alias keywords)
      (let* ([property-keywords '(":extra-paths" ":extra-deps"
                                                 ":main-opts"
                                                 ":mvn/version"
                                                 ":local/root"
                                                 ":git/"
                                                 ":sha"
                                                 ":exclusions"
                                                 ":override-deps"
                                                 ":default-deps"
                                                 ":classpath-overrides")]
             ;; Tokenize on whitespace AND braces/brackets
             [tokens (tokenize content " \t\n\r{}[]()")]
             ;; Find all keywords (tokens starting with :)
             [keywords
              (filter (lambda (t)
                        (and (string? t) (> (string-length t) 1) (equal? (substring t 0 1) ":")))
                      tokens)]
             ;; Filter out :aliases itself and known property keywords
             [alias-keywords (filter (lambda (k)
                                       (and (not (equal? k ":aliases"))
                                            (not (member k property-keywords))))
                                     keywords)])
        ;; Create alias-info for each, checking for :main-opts nearby
        (map (lambda (alias-kw)
               (let* ([alias-name (substring alias-kw 1 (string-length alias-kw))]
                      ;; Simple heuristic: check if ":main-opts" appears in same context
                      [has-main? (string-contains? content (string-append alias-kw " {:main-opts"))])
                 (make-alias-info alias-name has-main? #f)))
             alias-keywords))))

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
