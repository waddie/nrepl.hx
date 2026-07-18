;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Jack-in configuration system
;; Manages command templates and user customization

(require "steel/result")
(require-builtin steel/filesystem)
(require "project-detection.scm")

(provide get-jack-in-command
  nrepl-configure-jack-in
  load-project-config
  build-clojure-command
  build-babashka-command
  build-nbb-command
  build-leiningen-command
  build-shadow-command
  build-elixir-mix-command
  build-basilisp-command
  alias-info-list->names
  jack-in-version
  nrepl-set-jack-in-version
  jack-in-middleware-vector
  nrepl-add-jack-in-middleware
  nrepl-set-jack-in-env
  jack-in-env-prefix
  shell-single-quote
  nrepl-set-after-jack-in-code
  after-jack-in-code
  nrepl-enable-piggieback
  config-load-errors)

;;; Global configuration storage

(define *jack-in-commands* (box (hash)))

;;; Jack-in dependency versions

(define *jack-in-versions*
  (box (hash 'nrepl "1.7.0" 'cider-nrepl "0.62.1" 'piggieback "0.7.0")))

(define (jack-in-version key)
  (hash-ref (unbox *jack-in-versions*) key))

(define (nrepl-set-jack-in-version key version)
  (set-box! *jack-in-versions*
    (hash-insert (unbox *jack-in-versions*) key version)))

(define (clojure-sdeps-string)
  (string-append "{:deps {nrepl/nrepl {:mvn/version \"" (jack-in-version 'nrepl) "\"} "
    "cider/cider-nrepl {:mvn/version \""
    (jack-in-version 'cider-nrepl)
    "\"}"
    (if (piggieback-enabled?)
      (string-append " cider/piggieback {:mvn/version \""
        (jack-in-version 'piggieback)
        "\"}")
      "")
    "}}"))

;;; Extra nREPL middleware

(define *extra-middleware* (box '()))

(define (nrepl-add-jack-in-middleware mw)
  (set-box! *extra-middleware* (cons mw (unbox *extra-middleware*))))

(define (jack-in-middleware-vector)
  (string-append "[cider.nrepl/cider-middleware"
    (if (piggieback-enabled?) " cider.piggieback/wrap-cljs-repl" "")
    (apply string-append
      (map (lambda (m) (string-append " " m)) (reverse (unbox *extra-middleware*))))
    "]"))

;;; Piggieback (opt-in ClojureScript-over-JVM support)

(define *piggieback-enabled* (box #f))

(define (nrepl-enable-piggieback)
  (set-box! *piggieback-enabled* #t))

(define (piggieback-enabled?)
  (unbox *piggieback-enabled*))

;;; Helper functions for alias-info structs

(define (alias-info-list->names alias-infos)
  "Extract alias names from list of alias-info structs.
   Returns list of alias name strings."
  (if (not alias-infos)
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
    (string-append "clojure -Sdeps '" (clojure-sdeps-string) "' "
      "-M"
      alias-str
      " -m nrepl.cmdline "
      "--middleware \""
      (jack-in-middleware-vector)
      "\" "
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
  (string-append "clojure -Sdeps '" (clojure-sdeps-string) "' "
    "-M -m nrepl.cmdline "
    "--middleware \""
    (jack-in-middleware-vector)
    "\" "
    "--port "
    (number->string port)))

(define (default-babashka port)
  "Default Babashka nREPL command"
  (string-append "bb nrepl-server " (number->string port)))

(define (default-nbb port)
  "Default nbb (ClojureScript on Node.js) nREPL command"
  (string-append "npx nbb nrepl-server :port " (number->string port)))

(define (lein-inject-prefix)
  "The `lein update-in ... --` chain that injects nREPL and the cider-nrepl
   plugin (which registers its own middleware) before the launch task."
  (string-append
    "update-in :dependencies conj '[nrepl/nrepl \""
    (jack-in-version 'nrepl)
    "\"]' -- "
    "update-in :plugins conj '[cider/cider-nrepl \""
    (jack-in-version 'cider-nrepl)
    "\"]' -- "))

(define (default-leiningen port . opts)
  "Default Leiningen nREPL command with cider-nrepl injected; optional profile list"
  (let* ([profiles (if (null? opts) '() (car opts))]
         [profile-part (if (null? profiles)
                        ""
                        (string-append "with-profile +"
                          (string-join profiles ",+")
                          " "))])
    (string-append "lein " (lein-inject-prefix) profile-part
      "trampoline repl :headless :port "
      (number->string port))))

(define (default-shadow-cljs builds)
  "Default shadow-cljs nREPL command. shadow-cljs owns its nREPL port
   (announced via .shadow-cljs/nrepl.port), so no --port here. -d injects
   cider-nrepl; shadow adds its own middleware when it is present. With
   builds: watch them; without: plain server."
  (string-append "npx shadow-cljs -d cider/cider-nrepl:" (jack-in-version 'cider-nrepl)
    (if (null? builds)
      " server"
      (string-append " watch " (string-join builds " ")))))

(define (default-elixir-mix port project-root)
  "Default Elixir Mix nREPL command (repartee). Runs `mix repartee.server` in
   the project root (the spawn wrapper does not cd, so the command embeds it;
   the root is double-quoted to survive spaces). Passes --port explicitly
   (repartee defaults to an ephemeral port) and --no-port-file (nrepl.hx
   manages its own .nrepl-port). Requires repartee as a dependency of the
   project (https://github.com/nrepl/nrepl-beam)."
  (string-append
    (if project-root
      (string-append "cd \"" project-root "\" && ")
      "")
    "mix repartee.server --port "
    (number->string port)
    " --no-port-file"))

(define (default-basilisp port)
  "Default basilisp nREPL command (Clojure-compatible Lisp on Python)"
  (string-append "basilisp nrepl-server --port " (number->string port)))

;;; Command template registration

(define (nrepl-configure-jack-in command-type template-fn)
  "Register or override a jack-in command template.
   command-type: symbol like 'clojure-cli, 'babashka, 'leiningen
   template-fn: function taking (port [aliases]) and returning command string"
  (let* ([current-commands (unbox *jack-in-commands*)]
         [updated-commands (hash-insert current-commands command-type template-fn)])
    (set-box! *jack-in-commands* updated-commands)))

(define (get-command-template command-type)
  "The user-registered template for command-type, or #f when none is set.
   Callers fall back to their built-in default on #f, so every builder can
   use the uniform (if template (template ...) (default ...)) shape."
  (let ([custom-commands (unbox *jack-in-commands*)])
    (if (hash-contains? custom-commands command-type)
      (hash-ref custom-commands command-type)
      #f)))

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

(define (build-nbb-command port)
  "Build nbb (ClojureScript on Node.js) nREPL jack-in command"
  (let ([template (get-command-template 'nbb)])
    (if template (template port) (default-nbb port))))

(define (build-leiningen-command port . opts)
  "Build Leiningen nREPL jack-in command; optional profile list. A custom
   template keeps its one-argument (template port) contract."
  (let ([template (get-command-template 'leiningen)]
        [profiles (if (null? opts) '() (car opts))])
    (if template
      (template port)
      (default-leiningen port profiles))))

(define (build-shadow-command builds)
  "Build shadow-cljs nREPL jack-in command. A custom template keeps its
   one-argument (template builds) contract."
  (let ([template (get-command-template 'shadow-cljs)])
    (if template
      (template builds)
      (default-shadow-cljs builds))))

(define (build-elixir-mix-command port project-root)
  "Build Elixir Mix (repartee) nREPL jack-in command"
  (let* ([template (get-command-template 'elixir-mix)])
    (if template
      (template port project-root)
      (default-elixir-mix port project-root))))

(define (build-basilisp-command port)
  "Build basilisp nREPL jack-in command"
  (let ([template (get-command-template 'basilisp)])
    (if template (template port) (default-basilisp port))))

(define (get-jack-in-command project-type port alias-infos . opts)
  "Get jack-in command for project type.
   project-type: 'clojure-cli, 'babashka, 'leiningen, 'elixir-mix, or python-* types
   port: port number
   alias-infos: list of alias-info structs or #f (for clojure-cli only)
   opts: optional project root (for elixir-mix only, which must cd there)"
  (let ([project-root (if (null? opts) #f (car opts))])
    (cond
      [(equal? project-type 'clojure-cli) (build-clojure-command port alias-infos)]
      [(equal? project-type 'babashka) (build-babashka-command port)]
      [(equal? project-type 'leiningen) (build-leiningen-command port)]
      [(equal? project-type 'elixir-mix) (build-elixir-mix-command port project-root)]
      [(member project-type '(python-poetry python-setuptools python-pipenv python-pip))
        (build-basilisp-command port)]
      [else #f])))

;;; Jack-in environment variables

(define *jack-in-env* (box '()))

(define (nrepl-set-jack-in-env pairs)
  (set-box! *jack-in-env* pairs))

(define (shell-single-quote s)
  "Wrap s in single quotes for sh, escaping embedded single quotes as '\\''."
  (let loop ([i 0] [acc '("'")])
    (if (>= i (string-length s))
      (apply string-append (reverse (cons "'" acc)))
      (let ([ch (string-ref s i)])
        (loop (+ i 1)
          (cons (if (char=? ch #\') "'\\''" (string ch)) acc))))))

(define (jack-in-env-prefix)
  "export statements for the configured jack-in env, or empty string.
   Exports (not VAR=x prefixes) so compound commands like `cd x && ...` inherit them."
  (apply string-append
    (map (lambda (pair)
          (string-append "export " (car pair) "=" (shell-single-quote (cdr pair)) "; "))
      (unbox *jack-in-env*))))

;;; After-jack-in code

(define *after-jack-in-code* (box '()))

(define (nrepl-set-after-jack-in-code forms)
  "Set the code string(s) to evaluate in the connected session right after
   jack-in succeeds. forms: a single code string, or a list of code strings."
  (set-box! *after-jack-in-code* (if (string? forms) (list forms) forms)))

(define (after-jack-in-code)
  "The configured after-jack-in code strings, in submission order."
  (unbox *after-jack-in-code*))

;;; Project-local configuration

;; Directive symbol -> module procedure. The single registry for config-file
;; directives: add new directives here (and to the provide list and README).
;; Built by an insert chain, not an inline multi-line (hash ...): that shape
;; miscompiles under the bare steel CLI used by the headless tests.
(define CONFIG-DIRECTIVES
  (let* ([h (hash)]
         [h (hash-insert h 'nrepl-configure-jack-in nrepl-configure-jack-in)]
         [h (hash-insert h 'nrepl-set-jack-in-version nrepl-set-jack-in-version)]
         [h (hash-insert h 'nrepl-add-jack-in-middleware nrepl-add-jack-in-middleware)]
         [h (hash-insert h 'nrepl-set-jack-in-env nrepl-set-jack-in-env)]
         [h (hash-insert h 'nrepl-set-after-jack-in-code nrepl-set-after-jack-in-code)]
         [h (hash-insert h 'nrepl-enable-piggieback nrepl-enable-piggieback)])
    h))

(define (config-directive-proc name)
  "The module procedure for a config-file directive symbol, or #f."
  (if (hash-contains? CONFIG-DIRECTIVES name)
    (hash-ref CONFIG-DIRECTIVES name)
    #f))

;; Errors collected while applying the current config file. Read via
;; config-load-errors after load-project-config; reset by each load.
(define *config-load-errors* (box '()))

(define (config-load-errors)
  "Error strings from the most recent load-project-config, newest first.
   Empty when the load was clean (or no config file existed)."
  (unbox *config-load-errors*))

(define (config-arg-value arg)
  "The runtime value of one directive argument: quoted forms are unwrapped
   (eval cannot rebuild dotted pairs), self-evaluating values pass through,
   anything else (e.g. a lambda form) is evaluated."
  (cond
    [(and (list? arg) (not (null? arg)) (equal? (car arg) 'quote)) (cadr arg)]
    [(or (string? arg) (number? arg) (boolean? arg)) arg]
    [else (eval arg)]))

(define (apply-config-form expr)
  "Interpret one project-config form. Known config directives are dispatched
   directly (module-level eval cannot see this module's bindings); their
   arguments are resolved via config-arg-value. Other forms fall through to
   eval. Errors are recorded in *config-load-errors* instead of being
   silently swallowed."
  (with-handler
    (lambda (err)
      (set-box! *config-load-errors*
        (cons (to-string err) (unbox *config-load-errors*)))
      void)
    (let ([proc (and (list? expr) (not (null? expr)) (config-directive-proc (car expr)))])
      (if proc
        (apply proc (map config-arg-value (cdr expr)))
        (eval expr)))))

;;; Config baseline
;;;
;;; State captured before the first project config is applied (after init.scm
;;; directives ran) and restored before each load, so project configs are
;;; idempotent and one project's settings do not leak into another's jack-in.

(define *config-baseline* (box #f))

(define (snapshot-config-baseline!)
  ;; The hash is built by an insert chain, not an inline multi-line (hash ...)
  ;; in argument position: that shape miscompiles under the bare steel CLI
  ;; (0.8.2) even though the Helix pin has the fix.
  (when (not (unbox *config-baseline*))
    (let* ([h (hash)]
           [h (hash-insert h 'commands (unbox *jack-in-commands*))]
           [h (hash-insert h 'versions (unbox *jack-in-versions*))]
           [h (hash-insert h 'middleware (unbox *extra-middleware*))]
           [h (hash-insert h 'piggieback (unbox *piggieback-enabled*))]
           [h (hash-insert h 'env (unbox *jack-in-env*))]
           [h (hash-insert h 'after-code (unbox *after-jack-in-code*))])
      (set-box! *config-baseline* h))))

(define (restore-config-baseline!)
  (let ([b (unbox *config-baseline*)])
    (when b
      (set-box! *jack-in-commands* (hash-ref b 'commands))
      (set-box! *jack-in-versions* (hash-ref b 'versions))
      (set-box! *extra-middleware* (hash-ref b 'middleware))
      (set-box! *piggieback-enabled* (hash-ref b 'piggieback))
      (set-box! *jack-in-env* (hash-ref b 'env))
      (set-box! *after-jack-in-code* (hash-ref b 'after-code)))))

(define (load-project-config workspace-root)
  "Load project-local jack-in configuration from .helix/nrepl-jack-in.scm.
   Snapshots a baseline on first call and restores it before every load
   (including when no config file exists), so repeated loads are idempotent
   and per-project settings do not leak across projects. Directives issued
   after the first load (outside init.scm) are reset by the next load.
   Returns #t if loaded, #f if not found or error."
  (with-handler (lambda (err) #f)
    (begin
      (snapshot-config-baseline!)
      (restore-config-baseline!)
      (set-box! *config-load-errors* '())
      (let* ([config-path (string-append workspace-root "/.helix/nrepl-jack-in.scm")])
        (if (is-file? config-path)
          (begin
            ;; Read and apply all expressions in the config file
            (let* ([file-port (open-input-file config-path)])
              (let loop ()
                (let ([expr (read file-port)])
                  (if (eof-object? expr)
                    (begin
                      (close-port file-port)
                      #t)
                    (begin
                      (apply-config-form expr)
                      (loop)))))))
          #f)))))
