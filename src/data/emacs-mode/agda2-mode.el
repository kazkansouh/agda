;;; agda2-mode.el --- Major mode for Agda

;;; Commentary:

;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Dependency


;;; Code:

(defvar agda2-version "2.3.1"
  "The version of the Agda mode.
Note that, by default, the same version of the underlying Haskell
library is used (see `agda2-ghci-options').")

(require 'cl)
(set (make-local-variable 'lisp-indent-function)
     'common-lisp-indent-function)
(require 'comint)
(require 'pp)
(require 'eri)
(require 'annotation)
(require 'agda-input)
(require 'agda2-highlight)
(require 'agda2-abbrevs)
(require 'haskell-ghci)
;; due to a bug in haskell-mode-2.1
(setq haskell-ghci-mode-map (copy-keymap comint-mode-map))
;; Load filladapt, if it is installed.
(condition-case nil
    (require 'filladapt)
  (error nil))
(unless (fboundp 'overlays-in) (load "overlay")) ; for Xemacs
(unless (fboundp 'propertize)                    ; for Xemacs 21.4
 (defun propertize (string &rest properties)
  "Return a copy of STRING with text properties added.
First argument is the string to copy.
Remaining arguments form a sequence of PROPERTY VALUE pairs for text
properties to add to the result."
  (let ((str (copy-sequence string)))
    (add-text-properties 0 (length str) properties str)
    str)))
(unless (fboundp 'run-mode-hooks)
  (fset 'run-mode-hooks 'run-hooks))  ; For Emacs versions < 21.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Utilities

(defmacro agda2-let (varbind funcbind &rest body)
  "Expands to (let* VARBIND (labels FUNCBIND BODY...))."
  `(let* ,varbind (labels ,funcbind ,@body)))
(put 'agda2-let 'lisp-indent-function 2)

(defun agda2-chunkify (n xs)
  "Returns a list containing chunks of XS of length at most N.
All the elements of XS are included, in their original order."
  (let ((i 0)
        (len (length xs))
        out)
    (while (< i len)
      (let ((new-i (+ i (min n (- len i)))))
        (setq out (cons (subseq xs i new-i) out))
        (setq i new-i)))
    (nreverse out)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; User options

(defgroup agda2 nil
  "Major mode for interactively developing Agda programs."
  :group 'languages)

(defcustom agda2-include-dirs
  '(".")
  "The directories Agda uses to search for files.
The directory names should either be absolute or be relative to
the root of the current project."
  :type '(repeat directory)
  :group 'agda2)

(defcustom agda2-external-tools
  'nil
  "Names and paths of external tools."
  :type '(repeat (cons (string :tag "Tool Name") (file :tag "Executable Path")))
  :group 'agda2)

(defcustom agda2-backend
  "MAlonzo"
  "The backend which is used to compile Agda programs."
  :type '(choice (const "MAlonzo")
                 (const "Epic")
                 (const "JS"))
  :group 'agda2)

(defcustom agda2-ghci-options
  (list "-ignore-dot-ghci"    ; Make sure that the user's .ghci is not
                              ; read.
        "-hide-all-packages"  ; To avoid problems if some conflicting
                              ; package is exposed in one of the
                              ; user's package databases.
        "-package base"       ; To gain access to the Prelude.
        (concat "-package Agda-" agda2-version))
  "Command-line options given to GHCi.
These options are prepended to `haskell-ghci-program-args'."
  :type '(repeat string)
  :group 'agda2)

(defcustom agda2-toplevel-module "Agda.Interaction.GhciTop"
  "The name of the Agda toplevel module."
  :type 'string :group 'agda2)

(defcustom agda2-mode-hook
  '(agda2-fix-ghci-for-windows)
  "Hooks for `agda2-mode'."
  :type 'hook :group 'agda2)

(defcustom agda2-information-window-max-height
  0.35
  "*The maximum height of the information window.
A multiple of the frame height."
  :type 'number
  :group 'agda2)

(defcustom agda2-fontset-name
  (unless (or (eq window-system 'mac)
              ;; Emacs-23 uses a revamped font engine which should
              ;; make agda2-fontset-name unnecessary in most cases.
              ;; And if it turns out to be necessary, we should
              ;; probably use face-remapping-alist rather than
              ;; set-frame-font so the special font only applies to
              ;; Agda buffers, and so it applies in all frames where
              ;; Agda buffers are displayed.
              (boundp 'face-remapping-alist))
    "fontset-agda2")
  "Default font to use in the selected frame when activating the Agda mode.
This is only used if it's non-nil and Emacs is not running in a
terminal.

Note that this setting (if non-nil) affects non-Agda buffers as
well, and that you have to restart Emacs if you want settings to
this variable to take effect."
  :type '(choice (string :tag "Fontset name")
                 (const :tag "Do not change the font" nil))
  :group 'agda2)

(defcustom agda2-fontset-spec-of-fontset-agda2
    "-*-fixed-Medium-r-Normal-*-18-*-*-*-c-*-fontset-agda2,
    ascii:-Misc-Fixed-Medium-R-Normal--18-120-100-100-C-90-ISO8859-1,
    latin-iso8859-2:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-2,
    latin-iso8859-3:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-3,
    latin-iso8859-4:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-4,
    cyrillic-iso8859-5:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-5,
    greek-iso8859-7:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-7,
    latin-iso8859-9:-*-Fixed-*-r-*-*-18-*-*-*-c-*-iso8859-9,
    mule-unicode-0100-24ff:-Misc-Fixed-Medium-R-Normal--18-120-100-100-C-90-ISO10646-1,
    mule-unicode-2500-33ff:-Misc-Fixed-Medium-R-Normal--18-120-100-100-C-90-ISO10646-1,
    mule-unicode-e000-ffff:-Misc-Fixed-Medium-R-Normal--18-120-100-100-C-90-ISO10646-1,
    japanese-jisx0208:-Misc-Fixed-Medium-R-Normal-ja-18-*-*-*-C-*-JISX0208.1990-0,
    japanese-jisx0212:-Misc-Fixed-Medium-R-Normal-ja-18-*-*-*-C-*-JISX0212.1990-0,
    thai-tis620:-Misc-Fixed-Medium-R-Normal--24-240-72-72-C-120-TIS620.2529-1,
    lao:-Misc-Fixed-Medium-R-Normal--24-240-72-72-C-120-MuleLao-1,
    tibetan:-TibMdXA-fixed-medium-r-normal--16-160-72-72-m-160-MuleTibetan-0,
    tibetan-1-column:-TibMdXA-fixed-medium-r-normal--16-160-72-72-m-80-MuleTibetan-1,
    korean-ksc5601:-Daewoo-Mincho-Medium-R-Normal--16-120-100-100-C-160-KSC5601.1987-0,
    chinese-gb2312:-ISAS-Fangsong ti-Medium-R-Normal--16-160-72-72-c-160-GB2312.1980-0,
    chinese-cns11643-1:-HKU-Fixed-Medium-R-Normal--16-160-72-72-C-160-CNS11643.1992.1-0,
    chinese-big5-1:-ETen-Fixed-Medium-R-Normal--16-150-75-75-C-160-Big5.ETen-0,
    chinese-big5-2:-ETen-Fixed-Medium-R-Normal--16-150-75-75-C-160-Big5.ETen-0"
  "Specification of the \"fontset-agda2\" fontset.
This fontset is only created if `agda2-fontset-name' is
\"fontset-agda2\" and Emacs is not run in a terminal.

Note that the text \"fontset-agda2\" has to be part of the
string (in a certain way; see the default setting) in order for the
agda2 fontset to be created properly.

Note also that the default setting may not work unless suitable
fonts are installed on your system. Refer to the README file
accompanying the Agda distribution for more details.

Note finally that you have to restart Emacs if you want settings
to this variable to take effect."
  :group 'agda2
  :type 'string)

(if (and (equal agda2-fontset-name "fontset-agda2") window-system)
    (create-fontset-from-fontset-spec agda2-fontset-spec-of-fontset-agda2 t t))

(defun agda2-fix-ghci-for-windows ()
  (if (string-match "windows" system-configuration)
      (setq haskell-ghci-program-name "ghc"
            haskell-ghci-program-args '("--interactive"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Global and buffer-local vars, initialization

(defvar agda2-mode-syntax-table
  (let ((tbl (make-syntax-table)))
    ;; Set the syntax of every char to "w" except for those whose default
    ;; syntax in `standard-syntax-table' is `paren' or `whitespace'.
    (map-char-table (lambda (keys val)
                      ;; `keys' here can be a normal char, a generic char
                      ;; (Emacs<23), or a char range (Emacs>=23).
                      (unless (memq (car val)
                                    (eval-when-compile
                                      (mapcar 'car
                                              (list (string-to-syntax "(")
                                                    (string-to-syntax ")")
                                                    (string-to-syntax " ")))))
                        (modify-syntax-entry keys "w" tbl)))
                    (standard-syntax-table))
    ;; Then override the remaining special cases.
    (dolist (cs '((?{ . "(}1n") (?} . "){4n") (?- . "w 123b") (?\n . "> b")
                  (?. . ".") (?\; . ".") (?_ . ".") (?! . ".")))
      (modify-syntax-entry (car cs) (cdr cs) tbl))
    tbl)
  "Syntax table used by the Agda mode:

{}   | Comment characters, matching parentheses.
-    | Comment character, word constituent.
\n   | Comment ender.
.;_! | Punctuation.

Remaining characters inherit their syntax classes from the
standard syntax table if that table treats them as matching
parentheses or whitespace.  Otherwise they are treated as word
constituents.")

(defconst agda2-command-table
  `(
    (agda2-load                              "\C-c\C-l"         (global)       "Load")
    (agda2-load                              "\C-c\C-x\C-l")
    (agda2-compile                           "\C-c\C-x\C-c"     (global)       "Compile")
    (agda2-quit                              "\C-c\C-x\C-q"     (global)       "Quit")
    (agda2-restart                           "\C-c\C-x\C-r"     (global)       "Restart")
    (agda2-remove-annotations                "\C-c\C-x\C-d"     (global)       "Remove goals and highlighting (\"deactivate\")")
    (agda2-display-implicit-arguments        "\C-c\C-x\C-h"     (global)       "Toggle display of hidden arguments")
    (agda2-show-constraints                  ,(kbd "C-c C-=")   (global)       "Show constraints")
    (agda2-solveAll                          ,(kbd "C-c C-s")   (global)       "Solve constraints")
    (agda2-show-goals                        ,(kbd "C-c C-?")   (global)       "Show goals")
    (agda2-next-goal                         "\C-c\C-f"         (global)       "Next goal") ; Forward.
    (agda2-previous-goal                     "\C-c\C-b"         (global)       "Previous goal") ; Back.
    (agda2-give                              ,(kbd "C-c C-SPC") (local)        "Give")
    (agda2-refine                            "\C-c\C-r"         (local)        "Refine")
    (agda2-auto                              "\C-c\C-a"         (local)        "Auto")
    (agda2-make-case                         "\C-c\C-c"         (local)        "Case")
    (agda2-goal-type                         "\C-c\C-t"         (local)        "Goal type")
    (agda2-show-context                      "\C-c\C-e"         (local)        "Context (environment)")
    (agda2-infer-type-maybe-toplevel         "\C-c\C-d"         (local global) "Infer (deduce) type")
    (agda2-goal-and-context                  ,(kbd "C-c C-,")   (local)        "Goal type and context")
    (agda2-goal-and-context-and-inferred     ,(kbd "C-c C-.")   (local)        "Goal type, context and inferred type")
    (agda2-module-contents-maybe-toplevel    ,(kbd "C-c C-o")   (local global) "Module contents")
    (agda2-compute-normalised-maybe-toplevel "\C-c\C-n"         (local global) "Evaluate term to normal form")
    (describe-char                           nil                (global)       "Information about the character at point")
    (eri-indent                  ,(kbd "TAB"))
    (eri-indent-reverse          [S-iso-lefttab])
    (eri-indent-reverse          [S-lefttab])
    (eri-indent-reverse          [S-tab])
    (agda2-goto-definition-mouse [mouse-2])
    (agda2-goto-definition-keyboard "\M-.")
    (agda2-go-back                  "\M-*")
    )
  "Table of commands, used to build keymaps and menus.
Each element has the form (CMD &optional KEYS WHERE DESC) where
CMD is a command; KEYS is its key binding (if any); WHERE is a
list which should contain 'local if the command should exist in
the goal menu and 'global if the command should exist in the main
menu; and DESC is the description of the command used in the
menus.")

(defvar agda2-mode-map
  (let ((map (make-sparse-keymap "Agda mode")))
    (define-key map [menu-bar Agda]
      (cons "Agda" (make-sparse-keymap "Agda")))
    (define-key map [down-mouse-3]  'agda2-popup-menu-3)
    (dolist (d (reverse agda2-command-table))
      (destructuring-bind (f &optional keys kinds desc) d
        (if keys (define-key map keys f))
        (if (member 'global kinds)
            (define-key map
              (vector 'menu-bar 'Agda (intern desc)) (cons desc f)))))
    map)
  "Keymap for `agda2-mode'.")

(defvar agda2-goal-map
  (let ((map (make-sparse-keymap "Agda goal")))
    (dolist (d (reverse agda2-command-table))
      (destructuring-bind (f &optional keys kinds desc) d
        (if (member 'local kinds)
            (define-key map
              (vector (intern desc)) (cons desc f)))))
    map)
  "Keymap for agda2 goal menu.")

(defvar agda2-info-buffer nil
  "Agda information buffer.")

(defvar agda2-process-buffer nil
  "Agda subprocess buffer.
Set in `agda2-restart'.")

(defvar agda2-process nil
  "Agda subprocess.
Set in `agda2-restart'.")

(defvar agda2-in-progress nil
  "Is the Agda process currently busy?")

;; Some buffer locals
(defvar agda2-buffer-external-status ""
  "External status of an `agda2-mode' buffer (dictated by the Haskell side).")
(make-variable-buffer-local 'agda2-buffer-external-status)

(defconst agda2-help-address
  ""
  "Address accepting submissions of bug reports and questions.")

;; Annotation for a goal
;; {! .... !}
;; ----------  overlay:    agda2-gn num, face highlight, after-string num,
;;                         modification-hooks (agda2-protect-goal-markers)
;; -           text-props: category agda2-delim1
;;  -          text-props: category agda2-delim2
;;         -   text-props: category agda2-delim3
;;          -  text-props: category agda2-delim4
;;
;; Char categories for {! ... !}
(defvar agda2-open-brace  "{")
(defvar agda2-close-brace " }")
(setplist 'agda2-delim1 `(display ,agda2-open-brace))
(setplist 'agda2-delim2 `(display ,agda2-open-brace rear-nonsticky t
                                  agda2-delim2 t))
(setplist 'agda2-delim3 `(display ,agda2-close-brace agda2-delim3 t))
(setplist 'agda2-delim4 `(display ,agda2-close-brace rear-nonsticky t))

;; Note that strings used with the display property are compared by
;; reference. If the agda2-*-brace definitions were inlined, then
;; goals would be displayed as "{{ }}n" instead of "{ }n".

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; agda2-mode

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.l?agda\\'" . agda2-mode))
;;;###autoload
(modify-coding-system-alist 'file "\\.l?agda\\'" 'utf-8)
;;;###autoload
(eval `(define-derived-mode agda2-mode
  ,(if (fboundp 'prog-mode) 'prog-mode)
  "Agda"
  "Major mode for Agda files.

The following paragraph does not apply to Emacs 23 or newer.

  Note that when this mode is activated the default font of the
  current frame is changed to the fontset `agda2-fontset-name'.
  The reason is that Agda programs often use mathematical symbols
  and other Unicode characters, so we try to provide a suitable
  default font setting, which can display many of the characters
  encountered. If you prefer to use your own settings, set
  `agda2-fontset-name' to nil.

Special commands:
\\{agda2-mode-map}"
 (setq local-abbrev-table agda2-mode-abbrev-table
       indent-tabs-mode   nil
       mode-line-process
         '((:eval (unless (eq 0 (length agda2-buffer-external-status))
                    (concat ":" agda2-buffer-external-status)))))
 (let ((l '(max-specpdl-size    2600
            max-lisp-eval-depth 2800)))
   (while l (set (make-local-variable (pop l)) (pop l))))
 (if (and window-system agda2-fontset-name)
     (condition-case nil
         (set-frame-font agda2-fontset-name)
       (error (error "Unable to change the font; change agda2-fontset-name or tweak agda2-fontset-spec-of-fontset-agda2"))))
 ;; Deactivate highlighting if the buffer is edited before
 ;; typechecking is complete.
 (add-hook 'first-change-hook 'agda2-abort-highlighting nil 'local)
 ;; If GHCi is not running syntax highlighting does not work properly.
 (unless (eq 'run (agda2-process-status))
   (agda2-restart))
 (agda2-highlight-setup)
 (agda2-highlight-reload)
 (agda2-comments-and-paragraphs-setup)
 (force-mode-line-update)
 ;; Protect global value of default-input-method from set-input-method.
 (make-local-variable 'default-input-method)
 (set-input-method "Agda")
 ;; Highlighting etc. is removed when we switch from the Agda mode.
 ;; Use case: When a file M.lagda with a local variables list
 ;; including "mode: latex" is loaded chances are that the Agda mode
 ;; is activated before the LaTeX mode, and the LaTeX mode does not
 ;; seem to remove the text properties set by the Agda mode.
 (add-hook 'change-major-mode-hook 'agda2-quit nil 'local)))

(defun agda2-export-external-tools ()
       "Formats the paths of the external tools, and exports them to the env variable AGDA_EXTERNAL_TOOLS"
       (setq list agda2-external-tools)
       (setq acc ())
       (while list
         (setq acc (concat acc (concat (concat (car (car list)) (concat "=" (cdr (car list)))) ";")))
         (setq list (cdr list)))
       (if (not (not acc)) (setenv "AGDA_EXTERNAL_TOOLS" (substring acc 0 -1))))

(defun agda2-restart ()
  "Kill and restart the *ghci* buffer and load `agda2-toplevel-module'."
  (interactive)
  (save-excursion (let ((agda2-bufname "*ghci*")
                        (ignore-dot-ghci "-ignore-dot-ghci"))
                    (condition-case nil
                      (progn
                        ;; GHCi doesn't always die when its buffer is
                        ;; killed, so GHCi is killed before the buffer
                        ;; is.
                        (set-buffer agda2-bufname)
                        (condition-case nil
                            (comint-kill-subjob)
                          (error nil))
                        (kill-buffer agda2-bufname))
                      (error nil))
                    (set (make-local-variable 'haskell-ghci-program-args)
                         (append agda2-ghci-options haskell-ghci-program-args))
		    (agda2-export-external-tools)
                    (haskell-ghci-start-process nil)
                    (setq agda2-process        haskell-ghci-process
                          agda2-process-buffer haskell-ghci-process-buffer
                          agda2-in-progress    nil
                          mode-name "Agda GHCi")
                    (set (make-local-variable 'comint-input-sender)
                         'agda2-send)
                    ;; Avoid the "Marker does not point anywhere"
                    ;; message.
                    (set (make-local-variable 'ansi-color-for-comint-mode)
                         nil)
                    (set-buffer-file-coding-system 'utf-8)
                    (set-buffer-process-coding-system 'utf-8 'utf-8)
                    (rename-buffer agda2-bufname)
                    (set-process-query-on-exit-flag agda2-process nil)))
  (agda2-call-ghci 'wait nil ":mod +" agda2-toplevel-module)
  (with-current-buffer agda2-process-buffer
      (add-hook 'comint-preoutput-filter-functions
                'agda2-ghci-filter
                nil 'local)
      (add-hook 'comint-output-filter-functions
                'agda2-ghci-run-last-commands
                nil 'local))
  (agda2-remove-annotations))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Communicating with Agda

(defun agda2-raise-ghci-error ()
  "Raises an error.
The error message directs the user to the *ghci* buffer."
  (error "Problem encountered. The *ghci* buffer can perhaps explain why."))

(defun agda2-send (proc s)
  "Sends the string S to PROC.
Splits up S into small chunks and sends them one after the other,
because when GHCi is used in shell buffers it chokes on overly
long strings (some versions of GHCi, on some systems)."
  (let* ((chunk-size 200))
    (dolist (chunk (agda2-chunkify chunk-size s))
      (comint-send-string proc chunk)))
  (comint-send-string proc "\n"))

(defun agda2-ghci-running nil
  "Does the GHCi buffer exist and is the GHCi process running?"
  (and (buffer-live-p agda2-process-buffer)
       (eq (agda2-process-status) 'run)))

(defun agda2-call-ghci (wait restart &rest args)
  "Executes commands in GHCi.
Saves the buffer and sends the list of strings ARGS to GHCi.
Waits for output if WAIT is non-nil. If RESTART is non-nil and
the GHCi process is not running, or the GHCi buffer does not
exist, then an attempt is made to restart the process."
  (save-buffer)
  (when (and restart (not (agda2-ghci-running)))
    ;; Try restarting automatically, but only once, in case there is
    ;; some major problem.
    (agda2-restart)
    (unless (agda2-ghci-running)
      (agda2-raise-ghci-error)))
  (with-current-buffer agda2-process-buffer
    (goto-char (point-max))
    (insert (apply 'concat (agda2-intersperse " " args)))
    (comint-send-input)
    (when wait (haskell-ghci-wait-for-output))))

;; The following variables are used by the filter process,
;; `agda2-ghci-filter'. Their values are only modified by the filter
;; process, `agda2-go', and `agda2-abort-highlighting'.

(defvar agda2-highlight-in-progress nil
  "If nil, then highlighting annotations are not applied.")
(make-variable-buffer-local 'agda2-highlight-in-progress)

(defvar agda2-responses-expected nil
  "Is the Agda process expected to produce at least one response?")
(make-variable-buffer-local 'agda2-responses-expected)

(defvar agda2-responses 0
  "The number of encountered response commands.")
(make-variable-buffer-local 'agda2-responses)

(defvar agda2-ghci-chunk-incomplete ""
  "Buffer for incomplete lines.
\(See `agda2-ghci-filter'.)")
(make-variable-buffer-local 'agda2-ghci-chunk-incomplete)

(defvar agda2-last-responses nil
  "Response commands which should be run after other commands.
The command which arrived last is stored first in the list.")
(make-variable-buffer-local 'agda2-last-responses)

(defvar agda2-file-buffer nil
  "The Agda buffer.
Note that this variable is not buffer-local.")

(defun agda2-go (responses-expected highlight &rest args)
  "Executes commands in GHCi.
Sends the list of strings ARGS to GHCi, waits for output and
executes the responses, if any. If no responses are received, and
RESPONSES-EXPECTED is non-nil, then an error is raised. If
HIGHLIGHT is non-nil, then the buffer's syntax highlighting may
be updated."

  (when agda2-in-progress
    (error "Another command is currently in progress
\(if a command has been aborted you may want to restart Agda)"))

  (setq agda2-in-progress           t
        agda2-highlight-in-progress highlight
        agda2-responses-expected    responses-expected
        agda2-responses             0
        agda2-ghci-chunk-incomplete ""
        agda2-last-responses        nil
        agda2-file-buffer           (current-buffer))

  (apply 'agda2-call-ghci
         nil
         'restart
         "ioTCM"
         (agda2-string-quote (buffer-file-name))
         (if highlight "True" "False")
         "("
         (append args '(")"))))

(defun agda2-ghci-filter (chunk)
  "Evaluate the Agda process's commands.
This filter function assumes that every line contains either some
kind of error message (which cannot be parsed as a list), or
exactly one command. Incomplete lines are stored in a
buffer (`agda2-ghci-chunk-incomplete').

Every command is run by this function, unless it has the form
\"(('last . priority) . cmd)\", in which case it is run by
`agda2-ghci-run-last-commands' at the end, after the GHCi prompt
has reappeared, after all non-last commands, and after all
interactive highlighting is complete. The last commands can have
different integer priorities; those with the lowest priority are
executed first.

Non-last commands should not call the Agda process.

Commands of the form \"(agda2-typechecking-emacs ARGS)\" are
interpreted by this filter function; the highlighting
instructions in ARGS are applied to the Agda buffer, unless
`agda2-highlighting-in-progress' is nil.

All commands are echoed to the *ghci* buffer, with the exception
of the agda2-typechecking-emacs ones.

The non-last commands are run in the order in which they appear,
with the exception of the agda2-typechecking-emacs ones, which
are run before the other non-last commands.

When the prompt has been reached an error is raised if
`agda2-responses-expected' is non-nil and no commands have
arrived. Otherwise highlighting annotations are
reloaded from `agda2-highlighting-file', unless
`agda2-highlighting-in-progress' is nil."

  (with-current-buffer agda2-file-buffer

    (let (;; The input lines in the current chunk.
          (lines (split-string chunk "\n"))

          ;; Interactive highlighting annotations found in the current
          ;; chunk (reversed).
          (highlighting-anns ())

          ;; Non-last commands found in the current chunk (reversed).
          (non-last-commands ())

          ;; The text that is echoed to the *ghci* buffer.
          (echoed-text ""))

      (when (consp lines)

        (setq lines (cons (concat agda2-ghci-chunk-incomplete (car lines))
                          (cdr lines))

              ;; Stash away the last incomplete line, if any. (Note
              ;; that (split-string "...\n" "\n") evaluates to (...
              ;; "").)
              agda2-ghci-chunk-incomplete (car (last lines)))

        ;; Handle every complete line.
        (dolist (line (butlast lines))

          (let* (;; The command. Lines which cannot be parsed as a single
                 ;; list, without any junk, are ignored.
                 (cmd (condition-case nil
                          (let ((result (read-from-string line)))
                            (if (and (listp (car result))
                                     (= (cdr result) (length line)))
                                (car result)))
                        (error nil)))

                 ;; Is the command an interactive highlighting command?
                 (highlighting-cmd (equal (car-safe cmd)
                                          'agda2-typechecking-emacs)))

            (unless highlighting-cmd
              (setq echoed-text (concat echoed-text line "\n")))

            (when cmd
              (incf agda2-responses)

              (if highlighting-cmd
                  ;; Store the highlighting annotations.
                  (setq highlighting-anns
                        (append (reverse (cdr cmd)) highlighting-anns))

                ;; Store the command.
                (if (equal 'last (car-safe (car cmd)))
                    (push (cons (cdr (car cmd)) (cdr cmd))
                          agda2-last-responses)
                  (push cmd non-last-commands))))))

        ;; Apply interactive highlighting annotations.
        (when agda2-highlight-in-progress
          (apply 'agda2-highlight-load-anns 'keep
                 (reverse highlighting-anns)))

        ;; Run non-last commands.
        (agda2-exec-responses (nreverse non-last-commands))

        ;; Check if the prompt has been reached. This function assumes
        ;; that the prompt does not include any newline characters.
        (when (string-match
               (with-current-buffer agda2-process-buffer comint-prompt-regexp)
               agda2-ghci-chunk-incomplete)

          (setq agda2-in-progress nil)

          (setq echoed-text (concat echoed-text agda2-ghci-chunk-incomplete)
                agda2-ghci-chunk-incomplete "")

          (when (and agda2-responses-expected
                     (equal agda2-responses 0))
            (agda2-raise-ghci-error))))

      echoed-text)))

(defun agda2-ghci-run-last-commands (text)
  "Execute the last commands in the right order.
\(After the prompt has reappeared.) See `agda2-ghci-filter'. The
TEXT argument is not used."
  (unless agda2-in-progress
    (with-current-buffer agda2-file-buffer
      (let ((responses
             (mapcar 'cdr (sort (nreverse agda2-last-responses)
                                (lambda (x y) (<= (car x) (car y)))))))
        (setq agda2-last-responses nil)
        (agda2-exec-responses responses))
      (setq agda2-highlight-in-progress nil))))

(defun agda2-abort-highlighting nil
  "Abort any interactive highlighting.
This function should be used in `first-change-hook'."
  (when agda2-highlight-in-progress
    (setq agda2-highlight-in-progress nil)
    (message "\"%s\" has been modified. Interrupting highlighting."
             (buffer-name (current-buffer)))))

(defun agda2-highlight-load-and-delete-action (file &optional keep)
  "Like `agda2-highlight-load', but deletes FILE when done.
And highlighting is only updated if `agda2-highlight-in-progress'
is non-nil."
  (unwind-protect
      (if agda2-highlight-in-progress
          (agda2-highlight-load file keep))
    (delete-file file)))

(defun agda2-goal-cmd (cmd &optional want ask &rest args)
  "Reads input from goal or minibuffer and sends command to Agda.

An error is raised if point is not in a goal.

The command sent to Agda is

  CMD <goal number> <goal range> <user input> ARGS.

The user input is computed as follows:

* If WANT is nil, then the user input is the empty string.

* If WANT is a string, and either ASK is non-nil or the goal only
  contains whitespace, then the input is taken from the
  minibuffer. In this case WANT is used as the prompt string.

* Otherwise (including if WANT is 'goal) the goal contents are
  used.

If the user input is not taken from the goal, then an empty goal
range is given.

An error is raised if no responses are received."
  (multiple-value-bind (o g) (agda2-goal-at (point))
    (unless g (error "For this command, please place the cursor in a goal"))
    (let ((txt (buffer-substring-no-properties (+ (overlay-start o) 2)
                                               (- (overlay-end   o) 2)))
          (input-from-goal nil))
      (cond ((null want) (setq txt ""))
            ((and (stringp want)
                  (or ask (string-match "\\`\\s *\\'" txt)))
             (setq txt (read-string (concat want ": ") nil nil txt t)))
            (t (setq input-from-goal t)))
      (apply 'agda2-go t nil cmd
             (format "%d" g)
             (if input-from-goal (agda2-goal-Range o) "noRange")
             (agda2-string-quote txt) args))))

;; Note that the following function is a security risk, since it
;; evaluates code without first inspecting it. The code (supposedly)
;; comes from the Agda backend, but there could be bugs in the backend
;; which can be exploited by an attacker which manages to trick
;; someone into type-checking compromised Agda code.

(defun agda2-exec-responses (responses)
  "Interprets responses."
  (mapc (lambda (r)
          (let ((inhibit-read-only t))
            (eval r)))
          responses))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; User commands and response processing

(defun agda2-load ()
  "Load current buffer."
  (interactive)
  (agda2-go t t "cmd_load"
            (agda2-string-quote (buffer-file-name))
            (agda2-list-quote agda2-include-dirs)
            ))

(defun agda2-compile ()
  "Compile the current module.

The variable `agda2-backend' determines which backend is used."
  (interactive)
  (agda2-go t t "cmd_compile"
            agda2-backend
            (agda2-string-quote (buffer-file-name))
            (agda2-list-quote agda2-include-dirs)
            ))

(defun agda2-give()
  "Give to the goal at point the expression in it" (interactive)
  (agda2-goal-cmd "cmd_give" "expression to give"))

(defun agda2-give-action (old-g paren)
  "Update the goal OLD-G with the expression in it."
  (agda2-update old-g paren))

(defun agda2-refine ()
  "Refine the goal at point.
If the goal contains an expression e, and some \"suffix\" of the
type of e unifies with the goal type, then the goal is replaced
by e applied to a suitable number of new goals.

If the goal is empty, the goal type is a data type, and there is
exactly one constructor which unifies with this type, then the
goal is replaced by the constructor applied to a suitable number
of new goals."
  (interactive)
  (agda2-goal-cmd "cmd_refine_or_intro" 'goal))

(defun agda2-auto ()
 "Simple proof search" (interactive)
 (agda2-goal-cmd "cmd_auto" 'goal))

(defun agda2-make-case ()
  "Refine the pattern var given in the goal.
Assumes that <clause> = {!<var>!} is on one line."
  (interactive)
  (agda2-goal-cmd "cmd_make_case" "pattern var to case"))

(defun agda2-make-case-action (newcls)
  "Replace the line at point with new clauses NEWCLS and reload."
  (agda2-forget-all-goals);; we reload later anyway.
  (let* ((p0 (point))
         ;; (p1 (goto-char (agda2-decl-beginning)))
         (p1 (goto-char (+ (current-indentation) (line-beginning-position))))
         (indent (current-column))
         cl)
    (goto-char p0)
    (re-search-forward "!}" (line-end-position) 'noerr)
    (delete-region p1 (point))
    (while (setq cl (pop newcls))
      (insert cl)
      (if newcls (insert "\n" (make-string indent ?  ))))
    (goto-char p1))
  (agda2-load))

(defun agda2-make-case-action-extendlam (newcls)
  "Replace definition of extended lambda with new clauses NEWCLS and reload."
  (agda2-forget-all-goals);; we reload later anyway.
  (let* ((p (+ (re-search-backward "\\({[^!]\\)\\|;") 1))
         cl)
    (goto-char p)
    (delete-region p (- (re-search-forward "\\([^!]}\\)\\|;") 1))
    (goto-char p)
    (insert "  ")
    (goto-char (+ p 1))
    (while (setq cl (pop newcls))
      (insert cl)
      (if newcls (insert " ; ")))
    (goto-char p))
  (agda2-load))

(defun agda2-status-action (status)
  "Display the string STATUS in the current buffer's mode line.
\(precondition: the current buffer has to use the Agda mode as the
major mode)."
  (setq agda2-buffer-external-status status))

(defun agda2-info-buffer nil
  "Creates the Agda info buffer, if it does not already exist.
The buffer is returned."
  (unless (buffer-live-p agda2-info-buffer)
    (setq agda2-info-buffer
          (generate-new-buffer "*Agda information*"))

    (with-current-buffer agda2-info-buffer
      (compilation-mode "AgdaInfo")
      ;; Support for jumping to positions mentioned in the text.
      (set (make-local-variable 'compilation-error-regexp-alist)
           '(("\\([\\\\/][^[:space:]]*\\):\\([0-9]+\\),\\([0-9]+\\)-\\(\\([0-9]+\\),\\)?\\([0-9]+\\)"
              1 (2 . 5) (3 . 6))))
      ;; No support for recompilation. The key binding is removed, and
      ;; attempts to run `recompile' will (hopefully) result in an
      ;; error.
      (let ((map (copy-keymap (current-local-map))))
        (define-key map (kbd "g") 'undefined)
        (use-local-map map))
      (set (make-local-variable 'compile-command)
           'agda2-does-not-support-compilation-via-the-compilation-mode)

      (set-syntax-table agda2-mode-syntax-table)
      (set-input-method "Agda")))

  agda2-info-buffer)

(defun agda2-info-action (name text &optional append)
  "Insert TEXT into the Agda info buffer and display it.
NAME is displayed in the buffer's mode line.

If APPEND is non-nil, then TEXT is appended at the end of the
buffer, and point placed after this text.

If APPEND is nil, then any previous text is removed before TEXT
is inserted, and point is placed before this text."
  (interactive)
  (with-current-buffer (agda2-info-buffer)
    (unless append (erase-buffer))
    (save-excursion
      (goto-char (point-max))
      (insert text))
    (put-text-property 0 (length name) 'face '(:weight bold) name)
    (setq mode-line-buffer-identification name)
    (save-selected-window
      (pop-to-buffer (current-buffer) 'not-this-window 'norecord)
      (fit-window-to-buffer
       nil (truncate
            (* (frame-height) agda2-information-window-max-height)))
      (if append
          (goto-char (point-max))
        (goto-char (point-min))))))

(defun agda2-show-goals()
  "Show all goals." (interactive)
  (agda2-go t t "cmd_metas"))

(defun agda2-show-constraints()
  "Show constraints." (interactive)
  (agda2-go t t "cmd_constraints"))

(defun agda2-remove-annotations ()
  "Removes buffer annotations (overlays and text properties)."
  (interactive)
  (dolist (o (overlays-in (point-min) (point-max)))
    (delete-overlay o))
  (let ((inhibit-read-only t))
    (annotation-preserve-mod-p-and-undo
     (set-text-properties (point-min) (point-max) '()))
    (force-mode-line-update)))

(defun agda2-next-goal ()     "Go to the next goal, if any."     (interactive)
  (agda2-mv-goal 'next-single-property-change     'agda2-delim2 1 (point-min)))
(defun agda2-previous-goal () "Go to the previous goal, if any." (interactive)
  (agda2-mv-goal 'previous-single-property-change 'agda2-delim3 0 (point-max)))
(defun agda2-mv-goal (change delim adjust wrapped)
  (agda2-let ()
      ((go (p) (while (and (setq p (funcall change p 'category))
                           (not (eq (get-text-property p 'category) delim))))
           (if p (goto-char (+ adjust p)))))
    (or (go (point)) (go wrapped) (message "No goals in the buffer"))))

(defun agda2-quit ()
  "Quit and clean up after agda2."
  (interactive)
  (remove-hook 'first-change-hook 'agda2-abort-highlighting 'local)
  (agda2-remove-annotations)
  (condition-case nil
      (with-current-buffer agda2-process-buffer
        (comint-kill-subjob))
    (error nil))
  (kill-buffer agda2-process-buffer))

(defmacro agda2-maybe-normalised (name comment cmd want)
  "This macro constructs a function NAME which runs CMD.
COMMENT is used to build the function's comment. The function
NAME takes a prefix argument which tells whether it should
normalise types or not when running CMD (through
`agda2-goal-cmd'; WANT is used as `agda2-goal-cmd's WANT
argument)."
  (let ((eval (make-symbol "eval")))
  `(defun ,name (&optional not-normalise)
     ,(concat comment ".

With a prefix argument the result is not explicitly normalised.")
     (interactive "P")
     (let ((,eval (if not-normalise "Instantiated" "Normalised")))
       (agda2-goal-cmd (concat ,cmd " Agda.Interaction.BasicOps." ,eval)
                       ,want)))))

(defmacro agda2-maybe-normalised-toplevel (name comment cmd prompt)
  "This macro constructs a function NAME which runs CMD.
COMMENT is used to build the function's comments. The function
NAME takes a prefix argument which tells whether it should
normalise types or not when running CMD (through
`agda2-go' t nil; the string PROMPT is used as the goal command
prompt)."
  (let ((eval (make-symbol "eval")))
    `(defun ,name (not-normalise expr)
       ,(concat comment ".

With a prefix argument the result is not explicitly normalised.")
       (interactive ,(concat "P\nM" prompt ": "))
       (let ((,eval (if not-normalise "Instantiated" "Normalised")))
         (agda2-go t nil
                   (concat ,cmd " Agda.Interaction.BasicOps." ,eval " "
                           (agda2-string-quote expr)))))))

(agda2-maybe-normalised
 agda2-goal-type
 "Show the type of the goal at point"
 "cmd_goal_type"
 nil)

(agda2-maybe-normalised
 agda2-infer-type
 "Infer the type of the goal at point"
 "cmd_infer"
 "expression to type")

(agda2-maybe-normalised-toplevel
   agda2-infer-type-toplevel
   "Infers the type of the given expression. The scope used for
the expression is that of the last point inside the current
top-level module"
   "cmd_infer_toplevel"
   "Expression")

(defun agda2-infer-type-maybe-toplevel ()
  "Infers the type of the given expression.
Either uses the scope of the current goal or, if point is not in a goal, the
top-level scope."
  (interactive)
  (call-interactively (if (agda2-goal-at (point))
                          'agda2-infer-type
                        'agda2-infer-type-toplevel)))

(agda2-maybe-normalised
 agda2-goal-and-context
 "Shows the type of the goal at point and the currect context"
 "cmd_goal_type_context"
 nil)

(agda2-maybe-normalised
 agda2-goal-and-context-and-inferred
 "Shows the context, the goal and the given expression's inferred type"
 "cmd_goal_type_context_infer"
 "expression to type")

(agda2-maybe-normalised
 agda2-show-context
 "Show the context of the goal at point"
 "cmd_context"
 nil)

(defun agda2-module-contents ()
  "Shows all the top-level names in the given module.
Along with their types."
  (interactive)
  (agda2-goal-cmd "cmd_show_module_contents" "Module name"))

(defun agda2-module-contents-toplevel (module)
  "Shows all the top-level names in the given module.
Along with their types."
  (interactive "MModule name: ")
  (agda2-go t nil
            "cmd_show_module_contents_toplevel"
            (agda2-string-quote module)))

(defun agda2-module-contents-maybe-toplevel ()
  "Shows all the top-level names in the given module.
Along with their types.

Uses either the scope of the current goal or, if point is not in
a goal, the top-level scope."
  (interactive)
  (call-interactively (if (agda2-goal-at (point))
                          'agda2-module-contents
                        'agda2-module-contents-toplevel)))

(defun agda2-solveAll ()
  "Solves all goals that are already instantiated internally."
  (interactive)
  (agda2-go t t "cmd_solveAll"))

(defun agda2-solveAll-action (iss)
  (save-excursion
    (while iss
      (let* ((g (pop iss)) (txt (pop iss)))
        (agda2-replace-goal g txt)
        (agda2-goto-goal g)
        (agda2-give)))))

(defun agda2-compute-normalised (&optional arg)
  "Compute the normal form of the expression in the goal at point.
With a prefix argument \"abstract\" is ignored during the computation."
  (interactive "P")
  (let ((cmd (concat "cmd_compute"
                     (if arg " True" " False"))))
    (agda2-goal-cmd cmd "expression to normalise")))

(defun agda2-compute-normalised-toplevel (expr &optional arg)
  "Computes the normal form of the given expression.
The scope used for the expression is that of the last point inside the current
top-level module.
With a prefix argument \"abstract\" is ignored during the computation."
  (interactive "MExpression: \nP")
  (let ((cmd (concat "cmd_compute_toplevel"
                     (if arg " True" " False")
                     " ")))
    (agda2-go t nil (concat cmd (agda2-string-quote expr)))))

(defun agda2-compute-normalised-maybe-toplevel ()
  "Computes the normal form of the given expression,
using the scope of the current goal or, if point is not in a goal, the
top-level scope.
With a prefix argument \"abstract\" is ignored during the computation."
  (interactive)
  (if (agda2-goal-at (point))
      (call-interactively 'agda2-compute-normalised)
    (call-interactively 'agda2-compute-normalised-toplevel)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;

(defun agda2-highlight-reload nil
  "Loads precomputed syntax highlighting info for the current buffer.
If there is any to load."
  (agda2-go nil t
            "cmd_write_highlighting_info"
            (agda2-string-quote (buffer-file-name))))

(defun agda2-literate-p ()
  "Is the current buffer a literate Agda buffer?"
  (equal (file-name-extension (buffer-name)) "lagda"))

(defun agda2-goals-action (goals)
  "Annotates the goals in the current buffer with text properties.
GOALS is a list of the buffer's goal numbers, in the order in
which they appear in the buffer. Note that this function should
be run /after/ syntax highlighting information has been loaded,
because the two highlighting mechanisms interact in unfortunate
ways."
  (agda2-forget-all-goals)
  (agda2-let
      ((literate (agda2-literate-p))
       stk
       top)
      ((delims() (re-search-forward "[?]\\|[{][-!]\\|[-!][}]\\|--\\|\\\\begin{code}\\|\\\\end{code}" nil t))
       (is-lone-questionmark ()
          (save-excursion
            (save-match-data
                (backward-char 3)
                (looking-at
                 "\\(.[{(]\\|.\\s \\)[?]\\(\\s \\|[)};]\\|$\\)"))))
       (make(p)  (agda2-make-goal p (point) (pop goals)))
       (inside-comment() (and stk (null     (car stk))))
       (inside-goal()    (and stk (integerp (car stk))))
       (outside-code()   (and stk (eq (car stk) 'outside)))
       (inside-code()    (not (outside-code))))
    (save-excursion
      ;; In literate mode we should start out in the "outside of code"
      ;; state.
      (if literate (push 'outside stk))
      (goto-char (point-min))
      (while (and goals (delims))
        (labels ((c (s) (equal s (match-string 0))))
          (cond
           ((c "\\begin{code}") (when (outside-code)               (pop stk)))
           ((c "\\end{code}")   (when (not stk)                    (push 'outside stk)))
           ((c "--")            (when (not stk)                    (end-of-line)))
           ((c "{-")            (when (and (inside-code)
                                           (not (inside-goal)))    (push nil           stk)))
           ((c "-}")            (when (inside-comment)             (pop stk)))
           ((c "{!")            (when (and (inside-code)
                                           (not (inside-comment))) (push (- (point) 2) stk)))
           ((c "!}")            (when (inside-goal)
                                  (setq top (pop stk))
                                  (unless stk (make top))))
           ((c "?")             (progn
                                  (when (and (not stk) (is-lone-questionmark))
                                    (delete-char -1)
                                    (insert "{!!}")
                                    (make (- (point) 4)))))))))))

(defun agda2-make-goal (p q n)
  "Make a goal with number N at <P>{!...!}<Q>.  Assume the region is clean."
  (annotation-preserve-mod-p-and-undo
   (flet ((atp (x ps) (add-text-properties x (1+ x) ps)))
     (atp p       '(category agda2-delim1))
     (atp (1+ p)  '(category agda2-delim2))
     (atp (- q 2) '(category agda2-delim3))
     (atp (1- q)  '(category agda2-delim4)))
   (let ((o (make-overlay p q nil t nil)))
     (overlay-put o 'modification-hooks '(agda2-protect-goal-markers))
     (overlay-put o 'agda2-gn           n)
     (overlay-put o 'face               'highlight)
     (overlay-put o 'after-string       (propertize (format "%s" n) 'face 'highlight)))))

(defun agda2-protect-goal-markers (ol action beg end &optional length)
  "Ensures that the goal markers cannot be tampered with.
Except if `inhibit-read-only' is non-nil or /all/ of the goal is
modified."
  (if action
      ;; This is the after-change hook.
      nil
    ;; This is the before-change hook.
    (cond
     ((and (<= beg (overlay-start ol)) (>= end (overlay-end ol)))
      ;; The user is trying to remove the whole goal:
      ;; manually evaporate the overlay and add an undo-log entry so
      ;; it gets re-added if needed.
      (when (listp buffer-undo-list)
        (push (list 'apply 0 (overlay-start ol) (overlay-end ol)
                    'move-overlay ol (overlay-start ol) (overlay-end ol))
              buffer-undo-list))
      (delete-overlay ol))
     ((or (< beg (+ (overlay-start ol) 2))
          (> end (- (overlay-end ol) 2)))
      (unless inhibit-read-only
        (signal 'text-read-only nil))))))

(defun agda2-update (old-g new-txt)
  "Update the goal OLD-G.
If NEW-TXT is a string, then the goal is replaced by the string,
and otherwise the text inside the goal is retained (parenthesised
if NEW-TXT is `'paren').

Removes the goal braces, but does not remove the goal overlay or
text properties."
  (multiple-value-bind (p q) (agda2-range-of-goal old-g)
    (save-excursion
      (cond ((stringp new-txt)
             (agda2-replace-goal old-g new-txt))
            ((equal new-txt 'paren)
             (goto-char (- q 2)) (insert ")")
             (goto-char (+ p 2)) (insert "(")))
      (multiple-value-bind (p q) (agda2-range-of-goal old-g)
        (delete-region (- q 2) q)
        (delete-region p (+ p 2))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Misc

(defun agda2-process-status ()
  "Status of `agda2-process-buffer', or \"no process\"."
  (condition-case nil
      (process-status agda2-process)
    (error "no process")))

(defun agda2-intersperse (sep xs)
  (let(ys)(while xs (push (pop xs) ys)(push sep ys))(pop ys)(nreverse ys)))

(defun agda2-goal-Range (o)
  "The Haskell Range of goal overlay O."
  (format "(Range [Interval %s %s])"
          (agda2-mkPos (+ (overlay-start o) 2))
          (agda2-mkPos (- (overlay-end   o) 2))))

(defun agda2-mkPos (&optional p)
  "The Haskell Position corresponding to P or `point'."
  (save-excursion
    (if p (goto-char p))
    (format "(Pn (Just (mkAbsolute %s)) %d %d %d)"
            (agda2-string-quote (file-truename (buffer-file-name)))
            (point)
            (count-lines (point-min) (point))
            (1+ (current-column)))))

(defun agda2-char-quote (c)
  "Convert character C to the notation used in Haskell strings.
The non-ASCII characters are actually rendered as
\"\\xNNNN\\&\", i.e. followed by a \"null character\", to avoid
problems if they are followed by digits.  ASCII characters (code
points < 128) are converted to singleton strings."
  (if (< c 128)
      (list c)
    ;; FIXME: Why return a list rather than a string?  --Stef
    (append (format "\\x%x\\&" (encode-char c 'ucs)) nil)))

(defun agda2-string-quote (s)
  "Format S as a Haskell string literal.
Removes any text properties, escapes newlines, double quotes,
etc., adds surrounding double quotes, and converts non-ASCII
characters to the \\xNNNN notation used in Haskell strings."
  (let ((pp-escape-newlines t)
        (s2 (copy-sequence s)))
    (set-text-properties 0 (length s2) nil s2)
    (mapconcat 'agda2-char-quote (pp-to-string s2) "")))

(defun agda2-list-quote (strings)
  "Convert a list of STRINGS into a string representing it in Haskell syntax."
  (concat "[" (mapconcat 'agda2-string-quote strings ", ") "]"))

(defun agda2-goal-at(pos)
  "Return (goal overlay, goal number) at POS, or nil."
  (let ((os (and pos (overlays-at pos))) o g)
    (while (and os (not(setq g (overlay-get (setq o (pop os)) 'agda2-gn)))))
    (if g (list o g))))

(defun agda2-goal-overlay (g)
  "Returns the overlay of goal number G, if any."
  (car
   (remove nil
           (mapcar (lambda (o) (if (equal (overlay-get o 'agda2-gn) g) o))
                   (overlays-in (point-min) (point-max))))))

(defun agda2-range-of-goal (g)
  "The range of goal G."
  (let ((o (agda2-goal-overlay g)))
    (if o (list (overlay-start o) (overlay-end o)))))

(defun agda2-goto-goal (g)
  (let ((p (+ 2 (car (agda2-range-of-goal g)))))
    (if p (goto-char p))))

(defun agda2-replace-goal (g newtxt)
  "Replace the content of goal G with NEWTXT." (interactive)
  (save-excursion
    (multiple-value-bind (p q) (agda2-range-of-goal g)
      (setq p (+ p 2) q (- q 2))
      (let ((indent (and (goto-char p) (current-column))))
        (delete-region p q) (insert newtxt)
        (while (re-search-backward "^" p t)
          (insert-char ?  indent) (backward-char (1+ indent)))))))

(defun agda2-forget-all-goals ()
  "Remove all goal annotations.
\(Including some text properties which might be used by other
\(minor) modes.)"
  (annotation-preserve-mod-p-and-undo
   (remove-text-properties (point-min) (point-max)
                           '(category nil agda2-delim2 nil agda2-delim3 nil
                             display nil rear-nonsticky nil)))
  (let ((p (point-min)))
    (while (< (setq p (next-single-char-property-change p 'agda2-gn))
              (point-max))
      (delete-overlay (car (agda2-goal-at p))))))

(defun agda2-decl-beginning ()
  "Find the beginning point of the declaration containing the point.
To do: dealing with semicolon separated decls."
  (interactive)
  (save-excursion
    (let* ((pEnd (point))
           (pDef (progn (goto-char (point-min))
                        (re-search-forward "\\s *" pEnd t)))
           (cDef (current-column)))
      (while (re-search-forward
              "where\\(\\s +\\)\\S \\|^\\(\\s *\\)\\S " pEnd t)
        (if (match-end 1)
            (setq pDef (goto-char (match-end 1))
                  cDef (current-column))
          (goto-char (match-end 2))
          (if (>= cDef (current-column))
              (setq pDef (point)
                    cDef (current-column))))
        (forward-char))
      (goto-char pDef)
      (if (equal (current-word) "mutual")
          (or (match-end 2) (match-end 1))
        pDef))))

(defun agda2-beginning-of-decl ()
  (interactive)
  (goto-char (agda2-decl-beginning)))

(defvar agda2-debug-buffer-name "*Agda debug*"
  "The name of the buffer used for Agda debug messages.")

(defun agda2-verbose (msg)
  "Appends the string MSG to the `agda2-debug-buffer-name' buffer.
Note that this buffer's contents is not erased automatically when
a file is loaded."
  (with-current-buffer (get-buffer-create agda2-debug-buffer-name)
    (save-excursion
      (goto-char (point-max))
      (insert msg))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Comments and paragraphs

(defun agda2-comments-and-paragraphs-setup nil
  "Set up comment and paragraph handling for Agda mode."

  ;; Syntax table setup for comments is done elsewhere.

  ;; Enable highlighting of comments via Font Lock mode (which uses
  ;; the syntax table).
  (set (make-local-variable 'font-lock-defaults)
       '(nil nil nil nil nil))

  ;; Empty lines (all white space according to Emacs) delimit
  ;; paragraphs.
  (set (make-local-variable 'paragraph-start) "\\s-*$")
  (set (make-local-variable 'paragraph-separate) paragraph-start)

  ;; Support for adding/removing comments.
  (set (make-local-variable 'comment-start) "-- ")

  ;; Support for proper filling of text in comments (requires that
  ;; Filladapt is activated).
  (when (featurep 'filladapt)
    (add-to-list (make-local-variable
                  'filladapt-token-table)
                 '("--" agda2-comment))
    (add-to-list (make-local-variable 'filladapt-token-match-table)
                 '(agda2-comment agda2-comment) t)
    (add-to-list (make-local-variable 'filladapt-token-conversion-table)
                 '(agda2-comment . exact))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Go to definition site

(defun agda2-goto (filepos &optional other-window)
  "Like `annotation-goto', unless `agda2-highlight-in-progress' is nil."
  (if agda2-highlight-in-progress
      (annotation-goto filepos other-window)))

(defun agda2-goto-definition-keyboard (&optional other-window)
  "Go to the definition site of the name under point (if any).
If this function is invoked with a prefix argument then another window is used
to display the given position."
  (interactive "P")
  (annotation-goto-indirect (point) other-window))

(defun agda2-goto-definition-mouse (ev prefix)
  "Go to the definition site of the name clicked on, if any.
Otherwise, yank (see `mouse-yank-at-click')."
  (interactive "e\nP")
  (let ((pos (posn-point (event-end ev))))
    (if (annotation-goto-possible pos)
        (annotation-goto-indirect pos)
      ;; FIXME: Shouldn't we use something like
      ;; (call-interactively (key-binding ev))?  --Stef
      (mouse-yank-at-click ev prefix))))

(defun agda2-go-back nil
  "Go back to the previous position in which
`agda2-goto-definition-keyboard' or `agda2-goto-definition-mouse' was
invoked."
  (interactive)
  (annotation-go-back))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Implicit arguments

(defun agda2-display-implicit-arguments (&optional arg)
  "Toggle display of implicit arguments.
With prefix argument, turn on display of implicit arguments if
the argument is a positive number, otherwise turn it off."
  (interactive "P")
  (cond ((eq arg nil)       (agda2-go t t "toggleImplicitArgs"))
        ((and (numberp arg)
              (> arg 0))    (agda2-go t t "showImplicitArgs" "True"))
        (t                  (agda2-go t t "showImplicitArgs" "False"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;

(defun agda2-popup-menu-3 (ev)
  "If in a goal, popup the goal menu and call chosen command."
  (interactive "e")
  (let (choice)
    (save-excursion
      (and (agda2-goal-at (goto-char (posn-point (event-end ev))))
           (setq choice (x-popup-menu ev agda2-goal-map))
           (call-interactively
            (lookup-key agda2-goal-map (apply 'vector choice)))))))

(provide 'agda2-mode)
;;; agda2-mode.el ends here
