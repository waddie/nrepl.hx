;; Copyright (C) 2025 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Process manager for nREPL jack-in
;; Spawns and manages nREPL server processes

(require "steel/result")
(require-builtin steel/process)
(require-builtin steel/filesystem)
(require (only-in "run-command/run-command.scm" run-argv))

(provide spawned-process
  make-spawned-process
  spawned-process-process-handle
  spawned-process-port
  spawned-process-workspace-root
  spawned-process-log-path
  spawn-nrepl-server
  try-connect-to-port
  server-exit-code
  kill-server
  get-process-output)

;;; Spawned process struct

(struct spawned-process
  (process-handle ; Steel process handle from spawn-process
    command ; Command string that was executed
    port ; Port number server is using
    workspace-root ; Where server was started
    log-path) ; File the server's stdout/stderr is redirected to
  #:transparent)

(define (make-spawned-process process-handle command port workspace-root log-path)
  "Constructor for spawned-process"
  (spawned-process process-handle command port workspace-root log-path))

;;; Temp-file paths for capturing a spawned server's output and exit status.
;;; Keyed by port so a jack-in re-uses (and overwrites) the same files rather
;;; than accumulating temp files. macOS-native, like the rest of jack-in.

(define (server-log-path port)
  (string-append "/tmp/nrepl-hx-jackin-" (number->string port) ".log"))

(define (server-exit-path port)
  (string-append "/tmp/nrepl-hx-jackin-" (number->string port) ".exit"))

(define (exit-path-for process-info)
  "The exit-sentinel path for a spawned process, derived from its log path
   (/tmp/...<key>.log -> /tmp/...<key>.exit) so it survives port re-keying."
  (let ([log (spawned-process-log-path process-info)])
    (string-append (substring log 0 (- (string-length log) 4)) ".exit")))

;; Delete a file if present, swallowing any error (like `rm -f`).
(define (delete-file-quietly path)
  (with-handler (lambda (err) #f)
    (when (path-exists? path)
      (delete-file! path))
    #t))

;; Read a file's contents. Returns the contents, or #f if the file is missing or
;; empty. A blocking read on a *file* (unlike a pipe to a live process) cannot
;; deadlock, which is why the server is redirected to a file rather than piped.
(define (read-file-contents path)
  (with-handler (lambda (err) #f)
    (let ([out (read-port-to-string (open-input-file path))])
      (if (equal? out "") #f out))))

;;; Process spawning

(define (spawn-nrepl-server cmd-string workspace-root port)
  "Spawn an nREPL server process with the given command.
   Returns spawned-process struct or #f on failure."
  (with-handler (lambda (err) #f) ; Return #f on error
    (let* ([log-path (server-log-path port)]
           [exit-path (server-exit-path port)]
           ;; Clear any log/sentinel left by a previous jack-in on
           ;; this port, so a stale exit file can't be mistaken for
           ;; this run's failure.
           [_ (delete-file-quietly log-path)]
           [_ (delete-file-quietly exit-path)]
           ;; Redirect the server's stdout+stderr to a log FILE (not
           ;; the terminal - that would corrupt the TUI; not a pipe -
           ;; reading a live process's pipe would block). Then drop
           ;; an exit-code sentinel when the command returns, so the
           ;; poll loop can fail fast when the command dies straight
           ;; away (e.g. not found on PATH) instead of waiting out
           ;; the full 30s timeout.
           [wrapped (string-append "{ " cmd-string " ; } > \"" log-path
                     "\" 2>&1; echo $? > \""
                     exit-path
                     "\"")]
           [cmd (command "sh" (list "-c" wrapped))]
           [child-result (spawn-process cmd)]
           [process-handle (Ok->value child-result)])
      (make-spawned-process process-handle cmd-string port workspace-root log-path))))

;;; Server readiness polling helper

(define (server-exit-code process-info)
  "If the spawned server command has already exited, return its exit code as a
   trimmed string; otherwise #f (still running). A non-#f result means the
   server died before binding its port - jack-in should give up immediately."
  (let ([raw (read-file-contents (exit-path-for process-info))])
    (if raw (trim raw) #f)))

(define (try-connect-to-port port)
  "Check whether the (local) server is listening on `port`.
   Returns #t if a process holds the port in LISTEN state, #f otherwise.

   Deliberately does NOT open a TCP connection to the port. A throwaway
   connection (e.g. `nc -z`) immediately before the real nREPL connect wedges
   nrepl-steel's fragile per-connection serve-loop, so its next connection
   times out after a handful of evals. `lsof` inspects the OS socket table
   instead, leaving the real `nrepl:connect` as the only connection the server
   ever sees - matching the proven manual `:nrepl-connect` path. Jack-in is
   always local, so a LISTEN socket on `port` is our server, bound and ready to
   accept."
  (with-handler
    (lambda (err) #f) ; lsof failed / not found
    ;; We only use the exit code: lsof exits 0 when it finds a matching listening
    ;; socket, non-zero when none. run-argv captures stdout to a pipe, so lsof's
    ;; PID output never paints over Helix's buffer.
    (let* ([port-str (number->string port)]
           [result (run-argv "lsof"
                    (list (string-append "-iTCP:" port-str) "-sTCP:LISTEN" "-t"))])
      (hash-ref result 'ok))))

;;; Process management

(define (kill-server process-info)
  "Kill a spawned nREPL server process.
   Returns #t if killed successfully, #f otherwise."
  (with-handler (lambda (err) #f) ; Return #f on error
    ;; Drop the jack-in log/sentinel temp files for this port.
    (delete-file-quietly (spawned-process-log-path process-info))
    (delete-file-quietly (exit-path-for process-info))
    ;; Kill by port number - more reliable than regex pattern matching
    ;; Use -sTCP:LISTEN to find only the server process (not connected clients like Helix)
    (let* ([port (spawned-process-port process-info)]
           [port-pattern (string-append ":" (number->string port))]
           [result (run-argv "lsof" (list "-ti" port-pattern "-sTCP:LISTEN"))]
           [pids-str (hash-ref result 'stdout)]
           [pids (filter (lambda (s) (not (equal? s ""))) (split-many pids-str "\n"))])
      (if (null? pids)
        #f ; No process found on that port
        ;; Kill all PIDs found
        (begin
          (for-each (lambda (pid) (run-argv "kill" (list "-TERM" pid)))
            pids)
          #t)))))

(define (get-process-output process-info)
  "Read whatever the spawned server wrote to its log file (stdout + stderr).
   Returns the captured text, or #f if nothing was captured."
  (read-file-contents (spawned-process-log-path process-info)))
