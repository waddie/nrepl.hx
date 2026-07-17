(nrepl-configure-jack-in 'babashka
  (lambda (port) (string-append "custom-bb " (number->string port))))
(nrepl-set-jack-in-env '(("CFG" . "yes")))
