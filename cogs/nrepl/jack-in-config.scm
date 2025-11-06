;; Jack-in configuration system
;; Manages command templates and user customization

(require "steel/result")
(require "cogs/nrepl/project-detection.scm")

(provide get-jack-in-command
         nrepl-configure-jack-in
         load-project-config
         build-clojure-command
         build-babashka-command
         build-leiningen-command
         any-alias-has-main-opts?
         alias-info-list->names)

;;; Global configuration storage

(define *jack-in-commands* (box (hash)))

;;; Helper functions for alias-info structs

(define (alias-info-list->names alias-infos)
  "Extract alias names from list of alias-info structs.
   Returns list of alias name strings."
  (if (or (not alias-infos) (null? alias-infos))
      (list)
      (map alias-info-name alias-infos)))

(define (any-alias-has-main-opts? alias-infos)
  "Check if any alias in the list has :main-opts defined.
   Returns #t if any alias has :main-opts, #f otherwise."
  (if (or (not alias-infos) (null? alias-infos))
      #f
      (let loop ([remaining alias-infos])
        (if (null? remaining)
            #f
            (if (alias-info-has-main-opts? (car remaining))
                #t
                (loop (cdr remaining)))))))

;;; Default command templates

(define (default-clojure-with-aliases port alias-infos)
  "Default Clojure CLI command with project aliases and middleware injection"
  (let* ([alias-names (alias-info-list->names alias-infos)]
         [alias-str (if (null? alias-names)
                        ""
                        (string-append ":" (string-join alias-names ":")))])
    (string-append "clojure -Sdeps '{:deps {nrepl/nrepl {:mvn/version \"1.5.0\"} "
                   "cider/cider-nrepl {:mvn/version \"0.58.0\"}}}' "
                   "-M"
                   alias-str
                   " -m nrepl.cmdline "
                   "--middleware \"[cider.nrepl/cider-middleware]\" "
                   "--port "
                   (number->string port))))

(define (default-clojure-with-main-opts port alias-infos)
  "Default Clojure CLI command when aliases have :main-opts (trust them to start nREPL)"
  (let* ([alias-names (alias-info-list->names alias-infos)]
         [alias-str (if (null? alias-names)
                        ""
                        (string-append ":" (string-join alias-names ":")))])
    (string-append "clojure -M" alias-str)))

(define (default-clojure-with-sdeps port)
  "Default Clojure CLI command with -Sdeps (no project aliases)"
  (string-append "clojure -Sdeps '{:deps {nrepl/nrepl {:mvn/version \"1.5.0\"} "
                 "cider/cider-nrepl {:mvn/version \"0.58.0\"}}}' "
                 "-M -m nrepl.cmdline "
                 "--middleware \"[cider.nrepl/cider-middleware]\" "
                 "--port "
                 (number->string port)))

(define (default-babashka port)
  "Default Babashka nREPL command"
  (string-append "bb nrepl-server " (number->string port)))

(define (default-leiningen port)
  "Default Leiningen nREPL command"
  (string-append "lein trampoline repl :headless :port " (number->string port)))

;;; Command template registration

(define (nrepl-configure-jack-in command-type template-fn)
  "Register or override a jack-in command template.
   command-type: symbol like 'clojure-cli, 'babashka, 'leiningen
   template-fn: function taking (port [aliases]) and returning command string"
  (let* ([current-commands (unbox *jack-in-commands*)]
         [updated-commands (hash-insert current-commands command-type template-fn)])
    (set-box! *jack-in-commands* updated-commands)))

(define (get-command-template command-type)
  "Get command template for given type, falling back to defaults"
  (let* ([custom-commands (unbox *jack-in-commands*)])
    (if (hash-contains? custom-commands command-type)
        (hash-ref custom-commands command-type)
        ;; Return default template
        (cond
          [(equal? command-type 'babashka) default-babashka]
          [(equal? command-type 'leiningen) default-leiningen]
          [(equal? command-type 'clojure-cli-with-aliases) default-clojure-with-aliases]
          [(equal? command-type 'clojure-cli-with-main-opts) default-clojure-with-main-opts]
          [(equal? command-type 'clojure-cli-with-sdeps) default-clojure-with-sdeps]
          [else #f]))))

;;; Command building

(define (build-clojure-command port alias-infos)
  "Build Clojure CLI jack-in command.
   alias-infos: list of alias-info structs or #f
   Checks for :main-opts and uses appropriate command template"
  (if (and alias-infos (not (null? alias-infos)))
      ;; Have aliases - check if any have :main-opts
      (if (any-alias-has-main-opts? alias-infos)
          ;; Aliases have :main-opts - trust them to start nREPL
          (let* ([template (get-command-template 'clojure-cli-with-main-opts)])
            (if template
                (template port alias-infos)
                (default-clojure-with-main-opts port alias-infos)))
          ;; No :main-opts - inject nREPL + middleware via -Sdeps
          (let* ([template (get-command-template 'clojure-cli-with-aliases)])
            (if template
                (template port alias-infos)
                (default-clojure-with-aliases port alias-infos))))
      ;; No aliases, use -Sdeps
      (let* ([template (get-command-template 'clojure-cli-with-sdeps)])
        (if template
            (template port)
            (default-clojure-with-sdeps port)))))

(define (build-babashka-command port)
  "Build Babashka nREPL jack-in command"
  (let* ([template (get-command-template 'babashka)])
    (if template
        (template port)
        (default-babashka port))))

(define (build-leiningen-command port)
  "Build Leiningen nREPL jack-in command"
  (let* ([template (get-command-template 'leiningen)])
    (if template
        (template port)
        (default-leiningen port))))

(define (get-jack-in-command project-type port alias-infos)
  "Get jack-in command for project type.
   project-type: 'clojure-cli, 'babashka, or 'leiningen
   port: port number
   alias-infos: list of alias-info structs or #f (for clojure-cli only)"
  (cond
    [(equal? project-type 'clojure-cli) (build-clojure-command port alias-infos)]
    [(equal? project-type 'babashka) (build-babashka-command port)]
    [(equal? project-type 'leiningen) (build-leiningen-command port)]
    [else #f]))

;;; Project-local configuration

(define (load-project-config workspace-root)
  "Load project-local jack-in configuration from .helix/nrepl-jack-in.scm
   Returns #t if loaded, #f if not found or error."
  (with-handler (lambda (err) #f)
                (let* ([config-path (string-append workspace-root "/.helix/nrepl-jack-in.scm")])
                  (if (is-file? config-path)
                      (begin
                        ;; Read and evaluate all expressions in the config file
                        (let* ([file-port (open-input-file config-path)])
                          (let loop ()
                            (let ([expr (read file-port)])
                              (if (eof-object? expr)
                                  (begin
                                    (close-port file-port)
                                    #t)
                                  (begin
                                    (eval expr)
                                    (loop)))))))
                      #f))))

(define (is-file? path)
  "Check if file exists at path using Steel's built-in is-file?"
  (is-file? path))
