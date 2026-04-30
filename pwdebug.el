;;; pwdebug.el --- Front-end for the pwdebug Lua debugger -*- lexical-binding: t; -*-

;; Copyright (C) 2026  António Cardoso

;; Author: António Cardoso <finance@plugwise.com>
;; Maintainer: António Cardoso <finance@plugwise.com>
;; URL: https://github.com/PlugwiseBV/pwdebug.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, lua, debug

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; pwdebug.el is the Emacs front-end for the pwdebug Lua debugger.  It
;; manages a shared file of breakpoints / info-points, draws fringe
;; markers in source buffers, and presents an interactive value tree of
;; the paused target's locals, upvalues, environments, and live
;; coroutines — with collapsible tables you can drill into on demand.
;;
;; The package only handles the editor side.  The Lua runtime
;; (`src/dbg_runtime.lua' inside the pwdebug project) must be running
;; inside the target process for breakpoints to fire.  See the project
;; README for setup.
;;
;; IPC contract (paths under /tmp/pwdebug/):
;;   state          "running" | "paused\\n<file>\\n<line>\\n" | "exited"
;;   snapshot.json  per-pause snapshot of the target's stack/locals
;;   cmd            verb queue: continue, step_in, step_over, step_out,
;;                  expand <table-id>
;;
;; Configured points (read & written by pwdebug + this package) live at
;; ~/.config/pwdebug/debug_points.lua.
;;
;; Quick start:
;;   - Enable `pwdebug-mode' in your Lua source buffers
;;     (or add `pwdebug-enable-here' to `lua-mode-hook').
;;   - C-c d b   toggle a plain breakpoint
;;   - C-u C-c d b   toggle a CONDITIONAL breakpoint (prompts for a
;;                   Lua expression that must be truthy to pause)
;;   - C-c d i   toggle an info-point (prompts for a display expression)
;;   - C-c d ?   pop up the full key map
;;
;; When the target pauses, the locals tree appears in a side window;
;; press c / s / n / f for continue / step-into / step-over / step-out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar pwdebug-mode)  ; forward declaration; defined by define-minor-mode below

(defgroup pwdebug nil
  "Front-end for the pwdebug Lua debugger."
  :group 'tools
  :prefix "pwdebug-")

(defcustom pwdebug-points-file
  (expand-file-name "~/.config/pwdebug/debug_points.lua")
  "Shared file holding all configured breakpoints / info-points."
  :type 'file)

(defcustom pwdebug-config-file
  (expand-file-name "~/.config/pwdebug/config.lua")
  "Path to the pwdebug user config (we read `pwcore_root' from it)."
  :type 'file)

(defcustom pwdebug-state-file "/tmp/pwdebug/state"
  "Runtime IPC: \"running\" / \"paused\\n<file>\\n<line>\" / \"exited\"."
  :type 'file)

(defcustom pwdebug-locals-file "/tmp/pwdebug/locals"
  "Runtime IPC: legacy text dump of the paused locals."
  :type 'file)

(defcustom pwdebug-snapshot-file "/tmp/pwdebug/snapshot.json"
  "Runtime IPC: structured JSON snapshot of the paused target."
  :type 'file)

(defcustom pwdebug-cmd-file "/tmp/pwdebug/cmd"
  "Runtime IPC: outbound command queue (continue, step_*, expand <id>)."
  :type 'file)

(defcustom pwdebug-hits-file "/tmp/pwdebug/hits.log"
  "Runtime IPC: append-only log of point hits."
  :type 'file)

(defcustom pwdebug-poll-interval 0.5
  "Seconds between checks of the runtime state file."
  :type 'number)

(defface pwdebug-breakpoint-face
  '((t :foreground "red" :weight bold))
  "Face for breakpoint markers in the fringe.")

(defface pwdebug-infopoint-face
  '((t :foreground "DeepSkyBlue" :weight bold))
  "Face for info-point markers in the fringe.")

(defface pwdebug-disabled-face
  '((t :foreground "gray50"))
  "Face for disabled point markers.")

(defface pwdebug-paused-face
  '((t :background "khaki" :extend t))
  "Face for the line where execution is currently paused.")

(defface pwdebug-locals-header-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the PAUSED header in the locals buffer.")

(defface pwdebug-locals-frame-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for FRAME headers in the locals buffer.")

(defface pwdebug-locals-section-face
  '((t :inherit font-lock-type-face :weight bold))
  "Face for ARGS/LOCALS/UPVALUES section labels.")

(defface pwdebug-locals-name-face
  '((t :inherit font-lock-variable-name-face))
  "Face for variable names in the locals buffer.")

(defface pwdebug-locals-type-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for type hints like [table, N] or [function] in the locals buffer.")

(defface pwdebug-locals-divider-face
  '((t :foreground "gray40"))
  "Face for the ─── separator lines between frames.")

(defface pwdebug-locals-string-face
  '((t :inherit font-lock-string-face))
  "Face for string values in the locals tree.")

(defface pwdebug-locals-number-face
  '((t :inherit font-lock-constant-face))
  "Face for number values in the locals tree.")

(defface pwdebug-locals-keyword-face
  '((t :inherit font-lock-keyword-face))
  "Face for nil/true/false in the locals tree.")

(defface pwdebug-locals-function-face
  '((t :inherit font-lock-function-name-face))
  "Face for function values in the locals tree.")

(defface pwdebug-locals-table-face
  '((t :inherit default))
  "Face for table previews in the locals tree.")

(defface pwdebug-locals-marker-face
  '((t :inherit font-lock-comment-face))
  "Face for the ▸/▾ tree expansion markers.")

(defface pwdebug-locals-note-face
  '((t :inherit shadow :slant italic))
  "Face for notes like (loading…) / truncation hints.")

(defface pwdebug-locals-current-face
  '((t :inherit highlight))
  "Face used to highlight the currently selected tree row.")

(defface pwdebug-locals-button-face
  '((t :inherit mode-line-emphasis :weight bold :box (:line-width 1 :style released-button)))
  "Face for the toolbar buttons in the *pwdebug-locals* header line.")

(defface pwdebug-locals-button-key-face
  '((t :inherit mode-line-emphasis :foreground "yellow"))
  "Face for the key letter inside a toolbar button.")

(defface pwdebug-condition-face
  '((t :inherit font-lock-doc-face :slant italic
       :foreground "DeepSkyBlue"))
  "Face for the inline condition / expression line above an info-point.")

(defcustom pwdebug-locals-window-width 60
  "Width (columns) of the *pwdebug-locals* side window."
  :type 'integer)

;; Fringe bitmaps (used as the fringe indicator on point lines).
(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'pwdebug-bp-fringe
    [#b00111100 #b01111110 #b11111111 #b11111111
     #b11111111 #b11111111 #b01111110 #b00111100])
  (define-fringe-bitmap 'pwdebug-info-fringe
    [#b00011000 #b00111100 #b01111110 #b11111111
     #b11111111 #b01111110 #b00111100 #b00011000]))

;; ---------------------------------------------------------------------
;; Points file: parse + write
;; ---------------------------------------------------------------------

(defun pwdebug--read-config-value (key)
  "Pull a single string value KEY out of the pwdebug user config file."
  (when (file-readable-p pwdebug-config-file)
    (with-temp-buffer
      (insert-file-contents pwdebug-config-file)
      (goto-char (point-min))
      (when (re-search-forward
             (format "%s[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\"" key) nil t)
        (match-string 1)))))

(defun pwdebug-pwcore-root ()
  "Absolute path to the pwcore root, per the pwdebug user config."
  (let ((v (pwdebug--read-config-value "pwcore_root")))
    (when v (file-name-as-directory v))))

(defun pwdebug--lua-quote (s)
  "Quote string S as a Lua string literal."
  (concat "\""
          (replace-regexp-in-string
           "\"" "\\\\\""
           (replace-regexp-in-string "\\\\" "\\\\\\\\" s))
          "\""))

(defun pwdebug--read-points ()
  "Read the shared points file and return a list of plists."
  (let ((points '()))
    (when (file-readable-p pwdebug-points-file)
      (with-temp-buffer
        (insert-file-contents pwdebug-points-file)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "{file=\"\\([^\"]*\\)\","
                        "[[:space:]]*line=\\([0-9]+\\),"
                        "[[:space:]]*type=\"\\([^\"]*\\)\","
                        "[[:space:]]*expr=\\(nil\\|\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"\\),"
                        "[[:space:]]*enabled=\\(true\\|false\\)}")
                nil t)
          (let* ((file (match-string 1))
                 (line (string-to-number (match-string 2)))
                 (type (match-string 3))
                 (expr-raw (match-string 4))
                 (enabled (string= (match-string 5) "true"))
                 (expr (and (not (string= expr-raw "nil"))
                            (substring expr-raw 1 -1))))
            (push (list :file file :line line :type type
                        :expr expr :enabled enabled)
                  points)))))
    (nreverse points)))

(defun pwdebug--write-points (points)
  "Atomically rewrite the shared points file with POINTS."
  (let ((dir (file-name-directory pwdebug-points-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (let ((tmp (concat pwdebug-points-file ".tmp.emacs")))
    (with-temp-file tmp
      (insert "-- pwdebug breakpoints / info-points (managed by pwdebug + Emacs).\n"
              "return {\n")
      (dolist (p points)
        (insert (format "  {file=%s, line=%d, type=%s, expr=%s, enabled=%s},\n"
                        (pwdebug--lua-quote (plist-get p :file))
                        (plist-get p :line)
                        (pwdebug--lua-quote (plist-get p :type))
                        (if (plist-get p :expr)
                            (pwdebug--lua-quote (plist-get p :expr))
                          "nil")
                        (if (plist-get p :enabled) "true" "false"))))
      (insert "}\n"))
    (rename-file tmp pwdebug-points-file t)))

(defun pwdebug--find-point (points file line)
  "Find the point in POINTS that matches FILE and LINE, or nil."
  (cl-find-if (lambda (p) (and (string= (plist-get p :file) file)
                               (= (plist-get p :line) line)))
              points))

;; ---------------------------------------------------------------------
;; Overlay management (fringe markers + paused-line highlight)
;; ---------------------------------------------------------------------

(defvar-local pwdebug--point-overlays nil
  "Overlays placed by `pwdebug-mode' for fringe markers.")

(defvar pwdebug--paused-overlay nil
  "Single overlay marking the line currently paused on (any buffer).")

(defun pwdebug--clear-point-overlays ()
  "Delete every fringe / condition overlay this buffer has placed."
  (mapc #'delete-overlay pwdebug--point-overlays)
  (setq pwdebug--point-overlays nil))

(defun pwdebug--line-leading-whitespace ()
  "Return the leading whitespace of the line at point, as a string."
  (save-excursion
    (beginning-of-line)
    (let ((s (point)))
      (skip-chars-forward " \t")
      (buffer-substring-no-properties s (point)))))

(defun pwdebug--condition-line (expr point-type enabled point-line-pos)
  "Build the inline fake-line text for a point's EXPR.
POINT-TYPE is \"bp\" or \"info\".  ENABLED is the point's enabled
flag, used to dim the line when the point is disabled.
POINT-LINE-POS is the buffer position of the actual code line; we
match its leading whitespace so the fake line aligns with the code.
The line is prefixed with IF for conditional breakpoints, EXPR for
info-points; it ends with a newline so when used as part of a
`before-string' it renders as its own screen line above the code."
  (let* ((indent (save-excursion
                   (goto-char point-line-pos)
                   (pwdebug--line-leading-whitespace)))
         (face (if enabled 'pwdebug-condition-face 'pwdebug-disabled-face))
         (label (if (string= point-type "info") "EXPR " "IF ")))
    (concat indent
            (propertize "╎ " 'face face)
            (propertize label 'face face)
            (propertize expr 'face face)
            "\n")))

(defun pwdebug--refresh-fringe-this-buffer ()
  "Walk the points file and place fringe markers for this buffer's file.
For points with a non-empty `expr', the fake condition line is folded
into the SAME overlay's before-string (preceding the fringe \"x\") so
Emacs places the fringe display on the actual code line."
  (when (and pwdebug-mode buffer-file-name)
    (pwdebug--clear-point-overlays)
    (let ((file (file-truename buffer-file-name))
          (points (pwdebug--read-points)))
      (save-excursion
        (dolist (p points)
          (when (string= (file-truename (plist-get p :file)) file)
            (goto-char (point-min))
            (forward-line (1- (plist-get p :line)))
            (let* ((line-pos (line-beginning-position))
                   (enabled (plist-get p :enabled))
                   (expr (plist-get p :expr))
                   (type (plist-get p :type))
                   (face (cond
                          ((not enabled) 'pwdebug-disabled-face)
                          ((string= type "info") 'pwdebug-infopoint-face)
                          (t 'pwdebug-breakpoint-face)))
                   (bitmap (if (string= type "info")
                               'pwdebug-info-fringe
                             'pwdebug-bp-fringe))
                   (fringe-text (propertize "x" 'display
                                            `(left-fringe ,bitmap ,face)))
                   (cond-text (and expr (not (string-empty-p expr))
                                   (pwdebug--condition-line
                                    expr type enabled line-pos)))
                   (before (if cond-text (concat cond-text fringe-text)
                             fringe-text))
                   (ov (make-overlay line-pos line-pos)))
              (overlay-put ov 'before-string before)
              (overlay-put ov 'pwdebug-point t)
              (push ov pwdebug--point-overlays))))))))

(defun pwdebug--refresh-fringe-all-buffers ()
  "Re-place fringe markers in every buffer with `pwdebug-mode' on."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when pwdebug-mode (pwdebug--refresh-fringe-this-buffer)))))

;; ---------------------------------------------------------------------
;; Toggling
;; ---------------------------------------------------------------------

(defun pwdebug--toggle (kind &optional expr)
  "Toggle a point of KIND (\"bp\" or \"info\") at current line.
EXPR is the optional Lua expression.  For info-points it is the
value to display; for breakpoints it is the condition that gates
the pause \(only fires when truthy\)."
  (unless buffer-file-name (user-error "Buffer has no file"))
  (let* ((file (file-truename buffer-file-name))
         (line (line-number-at-pos))
         (points (pwdebug--read-points))
         (existing (pwdebug--find-point points file line)))
    (cond
     ;; Same kind + same expr already there → remove (true toggle).
     ((and existing
           (string= (plist-get existing :type) kind)
           (equal (plist-get existing :expr) expr))
      (setq points (cl-remove-if
                    (lambda (p) (and (string= (plist-get p :file) file)
                                     (= (plist-get p :line) line)))
                    points))
      (message "pwdebug: removed %s at %s:%d" kind
               (file-name-nondirectory file) line))
     ;; Existing point but different kind or different expr → update in place.
     (existing
      (setf (cl-getf existing :type) kind)
      (setf (cl-getf existing :expr) expr)
      (message "pwdebug: updated %s at %s:%d%s" kind
               (file-name-nondirectory file) line
               (if expr (format " {%s}" expr) "")))
     ;; Nothing there → add.
     (t
      (setq points (append points
                           (list (list :file file :line line
                                       :type kind :expr expr :enabled t))))
      (message "pwdebug: added %s at %s:%d%s" kind
               (file-name-nondirectory file) line
               (if expr (format " {%s}" expr) ""))))
    (pwdebug--write-points points)
    (pwdebug--refresh-fringe-all-buffers)))

;;;###autoload
(defun pwdebug-toggle-breakpoint (&optional with-condition)
  "Toggle an unconditional breakpoint at the current line.
With prefix arg WITH-CONDITION, prompt for a Lua condition — the
breakpoint then only pauses when that expression is truthy
\(looking up locals, upvalues, and globals at the breakpoint line\)."
  (interactive "P")
  (let ((expr (and with-condition
                   (let ((s (read-string "Pause when (Lua condition): ")))
                     (and (not (string-empty-p s)) s)))))
    (pwdebug--toggle "bp" expr)))

;;;###autoload
(defun pwdebug-set-conditional-breakpoint (expr)
  "Set or update a conditional breakpoint at the current line.
EXPR is the Lua condition; the breakpoint pauses only when EXPR is
truthy. If a point already exists at this line, its condition is
replaced — otherwise a new conditional bp is added."
  (interactive (list (read-string "Pause when (Lua condition): ")))
  (when (string-empty-p expr)
    (user-error "Empty condition; use C-c d b for an unconditional breakpoint"))
  (pwdebug--toggle "bp" expr))

;;;###autoload
(defun pwdebug-toggle-infopoint (&optional expr)
  "Toggle an info-point at the current line.
EXPR is an optional Lua expression that the runtime evaluates
when the point is hit; the value is captured into the snapshot
for display.  Interactively, you are prompted for it."
  (interactive
   (list (let ((s (read-string "Expression (empty for none): ")))
           (and (not (string-empty-p s)) s))))
  (pwdebug--toggle "info" expr))

(defun pwdebug-edit-expression ()
  "Edit the expression on the point at the current line.
Works on both info-points (display expression) and conditional
breakpoints (pause condition). Empty input clears the expression."
  (interactive)
  (let* ((file (file-truename (or buffer-file-name
                                  (user-error "No file"))))
         (line (line-number-at-pos))
         (points (pwdebug--read-points))
         (existing (pwdebug--find-point points file line)))
    (unless existing
      (user-error "No point at this line"))
    (let* ((kind (plist-get existing :type))
           (prompt (if (string= kind "info")
                       "Display expression: "
                     "Pause when (Lua condition): "))
           (new (read-string prompt (or (plist-get existing :expr) ""))))
      (setf (cl-getf existing :expr)
            (and (not (string-empty-p new)) new))
      (pwdebug--write-points points)
      (pwdebug--refresh-fringe-all-buffers))))

(defun pwdebug-clear-all ()
  "Remove every configured point."
  (interactive)
  (when (yes-or-no-p "Remove all pwdebug points? ")
    (pwdebug--write-points nil)
    (pwdebug--refresh-fringe-all-buffers)
    (message "pwdebug: cleared all points")))

;; ---------------------------------------------------------------------
;; List buffer
;; ---------------------------------------------------------------------

(defun pwdebug-list-points ()
  "Pop up a buffer listing every configured point."
  (interactive)
  (let ((buf (get-buffer-create "*pwdebug-points*"))
        (points (pwdebug--read-points)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%d point%s configured\n\n"
                        (length points)
                        (if (= (length points) 1) "" "s")))
        (dolist (p points)
          (insert (format " %s %-4s %s:%d%s\n"
                          (if (plist-get p :enabled) "●" "○")
                          (plist-get p :type)
                          (plist-get p :file)
                          (plist-get p :line)
                          (if (plist-get p :expr)
                              (format "  {%s}" (plist-get p :expr))
                            "")))))
      (special-mode))
    (display-buffer buf)))

;; ---------------------------------------------------------------------
;; Pause / resume
;; ---------------------------------------------------------------------

(defun pwdebug--write-cmd (cmd)
  "Write CMD into the runtime command file (creating its parent dir)."
  (let ((dir (file-name-directory pwdebug-cmd-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (with-temp-file pwdebug-cmd-file (insert cmd "\n")))

(defun pwdebug-continue ()
  "Tell the paused target to continue until the next breakpoint."
  (interactive)
  (pwdebug--write-cmd "continue")
  (message "pwdebug: continue"))

(defun pwdebug-step ()
  "Step into the next Lua line, descending into any nested function call."
  (interactive)
  (pwdebug--write-cmd "step_in")
  (message "pwdebug: step into"))

(defun pwdebug-next ()
  "Step over to the next line in the current function (skip nested frames)."
  (interactive)
  (pwdebug--write-cmd "step_over")
  (message "pwdebug: step over"))

(defun pwdebug-finish ()
  "Step out of the current function (resume until it has returned)."
  (interactive)
  (pwdebug--write-cmd "step_out")
  (message "pwdebug: step out"))

(defvar pwdebug--last-pause nil
  "Cons (FILE . LINE) of the last pause we reacted to.")

(defvar pwdebug--poll-timer nil)

;; ----- locals major mode -------------------------------------------
;;
;; The *pwdebug-locals* buffer renders a tree built from
;; /tmp/pwdebug/snapshot.json (written by dbg_runtime.lua on every pause
;; and every `expand <id>' response).  Tables are collapsible — RET / TAB
;; / + toggle.  Expanding a table that hasn't been captured yet sends
;; "expand <id>" via /tmp/pwdebug/cmd; the runtime appends to the JSON
;; and our poller picks up the rewrite.
;;
;; Tree expansion state lives in the buffer-local hash `pwdebug--expanded'
;; keyed by stable strings (frame index, category name, table id).  It
;; survives snapshot rewrites so the user's "open" choices stick when the
;; runtime delivers the deeper data.

(defvar-local pwdebug--snapshot nil
  "Parsed JSON snapshot (hash-table) for this buffer.")

(defvar-local pwdebug--expanded nil
  "Hash-table of expand-key → t for currently-open rows.")

(defvar-local pwdebug--snapshot-mtime 0
  "Mtime of the last snapshot JSON we loaded into this buffer.")

(defvar-local pwdebug--pending-expansions nil
  "Hash-table of table-id → t for awaiting `expand <id>' replies.")

(defvar pwdebug-locals-mode-map
  (let ((m (make-sparse-keymap)))
    ;; Tree navigation / expansion.
    (define-key m (kbd "TAB")     #'pwdebug-locals-toggle)
    (define-key m (kbd "RET")     #'pwdebug-locals-activate)
    (define-key m (kbd "+")       #'pwdebug-locals-expand)
    (define-key m (kbd "-")       #'pwdebug-locals-collapse)
    (define-key m (kbd "<right>") #'pwdebug-locals-expand)
    (define-key m (kbd "<left>")  #'pwdebug-locals-collapse-or-up)
    (define-key m (kbd "j")       #'pwdebug-locals-next-row)
    (define-key m (kbd "k")       #'pwdebug-locals-prev-row)
    (define-key m (kbd "<down>")  #'pwdebug-locals-next-row)
    (define-key m (kbd "<up>")    #'pwdebug-locals-prev-row)
    (define-key m (kbd "M-n")     #'pwdebug-locals-next-frame)
    (define-key m (kbd "M-p")     #'pwdebug-locals-prev-frame)
    ;; Pause control (debugger conventions: c/s/n/f).
    (define-key m (kbd "c")       #'pwdebug-continue)
    (define-key m (kbd "s")       #'pwdebug-step)
    (define-key m (kbd "n")       #'pwdebug-next)
    (define-key m (kbd "f")       #'pwdebug-finish)
    ;; Buffer.
    (define-key m (kbd "g")       #'pwdebug--update-locals-buffer)
    (define-key m (kbd "?")       #'pwdebug-help)
    (define-key m (kbd "q")       #'quit-window)
    (define-key m [mouse-1]       #'pwdebug-locals-mouse-toggle)
    m)
  "Keymap for `pwdebug-locals-mode'.")

(define-derived-mode pwdebug-locals-mode special-mode "pwdbg-locals"
  "Major mode for the *pwdebug-locals* buffer."
  (setq-local truncate-lines t)
  (setq-local cursor-in-non-selected-windows t)
  (setq-local pwdebug--snapshot nil)
  (setq-local pwdebug--expanded (make-hash-table :test 'equal))
  (setq-local pwdebug--pending-expansions (make-hash-table :test 'equal))
  (setq-local pwdebug--snapshot-mtime 0)
  (setq-local header-line-format '(:eval (pwdebug--locals-header-line))))

;; ----- snapshot loading -------------------------------------------------

(defun pwdebug--read-snapshot ()
  "Parse the JSON snapshot file and return a hash-table, or nil on failure."
  (when (and (file-readable-p pwdebug-snapshot-file)
             (> (file-attribute-size (file-attributes pwdebug-snapshot-file)) 0))
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents pwdebug-snapshot-file)
          (goto-char (point-min))
          (json-parse-buffer :object-type 'hash-table
                             :array-type 'list
                             :null-object nil
                             :false-object nil))
      (error nil))))

(defun pwdebug--snapshot-mtime ()
  "Return the snapshot file's mtime as a float, or nil if unreadable."
  (when (file-readable-p pwdebug-snapshot-file)
    (float-time (file-attribute-modification-time
                 (file-attributes pwdebug-snapshot-file)))))

;; ----- value-tree row construction --------------------------------------
;;
;; A row is a plist with: :kind (:frame|:category|:var|:note|:coroutine
;; |:divider|:header|:expr), :depth, :expandable, :expand-key, :table-id,
;; :name, :value (vref hash), :label, :file, :line, :frame-idx.

(defun pwdebug--row-expanded-p (row)
  "Return non-nil if ROW's expand-key is currently in the expanded set."
  (and (plist-get row :expand-key)
       (gethash (plist-get row :expand-key) pwdebug--expanded)))

(defun pwdebug--row-default-open-p (row)
  "Return non-nil if ROW should start expanded by default.
The innermost frame and its args/locals categories are open on
first render so the most relevant data is visible without input."
  (let ((k (plist-get row :kind)))
    (cond
     ((eq k :frame)    (= (plist-get row :frame-idx) 0))
     ((eq k :category) (and (= (plist-get row :frame-idx) 0)
                            (member (plist-get row :cat-key) '("args" "locals"))))
     (t nil))))

(defun pwdebug--row-open-p (row)
  "True if ROW is currently expanded (explicit state OR default)."
  (let* ((key (plist-get row :expand-key))
         (h   (and key (gethash key pwdebug--expanded 'unset))))
    (cond
     ((eq h 'unset) (pwdebug--row-default-open-p row))
     ((eq h nil)    nil)
     (t             t))))

(defun pwdebug--vref-table-id (vref)
  "Return the table id from value-ref hash VREF, or nil."
  (and (hash-table-p vref)
       (equal (gethash "type" vref) "table")
       (gethash "id" vref)))

(defun pwdebug--build-rows (snap)
  "Walk SNAP into a flat list of rows.
Recursion through table values is guarded by a visited-set keyed on
table id, so cycles (a table that contains itself, directly or via a
chain) terminate at the first revisit."
  (let ((rows '())
        (frames (gethash "frames" snap))
        (coros  (gethash "coroutines" snap))
        (tables (gethash "tables" snap))
        (visited (make-hash-table :test 'equal)))
    (cl-labels
        ((push-row (r) (push r rows))
         (emit-note
          (label depth)
          (push-row (list :kind :note :depth depth :label label)))
         (emit-table-entries
          (tbl-id depth)
          (cond
           ((gethash tbl-id visited)
            (emit-note "(cycle)" depth))
           (t
            (puthash tbl-id t visited)
            (let ((cap (and tables (gethash tbl-id tables))))
              (cond
               ((null cap)
                (emit-note "(loading…)" depth))
               (t
                (dolist (e (gethash "keys" cap))
                  (emit-var (gethash "key" e) (gethash "value" e) depth))
                (when (and (gethash "truncated" cap) (gethash "count" cap))
                  (let ((n (length (gethash "keys" cap)))
                        (m (gethash "count" cap)))
                    (emit-note (format "(showing first %d of %d entries)" n m)
                               depth))))))
            (remhash tbl-id visited))))
         (emit-var
          (name vref depth)
          (let* ((sub-id     (pwdebug--vref-table-id vref))
                 (already    (and sub-id (gethash sub-id visited)))
                 (expandable (and sub-id (not already)))
                 (key        (and sub-id
                                  (format "tbl:%s" sub-id)))
                 (row (list :kind :var :depth depth
                            :name name :value vref
                            :expandable expandable
                            :cycle already
                            :expand-key key
                            :table-id sub-id)))
            (push-row row)
            (when (and expandable (pwdebug--row-open-p row))
              (emit-table-entries sub-id (1+ depth))))))
      ;; --- header --------------------------------------------------------
      (let* ((p (gethash "paused_at" snap))
             (file (and p (gethash "file" p)))
             (line (and p (gethash "line" p)))
             (kind (and p (gethash "kind" p))))
        (push-row (list :kind :header :depth 0
                        :file file :line line :pause-kind kind)))
      (when (gethash "expr" snap)
        (let ((e (gethash "expr" snap)))
          (push-row (list :kind :expr :depth 0
                          :text (gethash "text" e)
                          :value (gethash "value" e)))))
      ;; --- frames --------------------------------------------------------
      (let ((idx 0))
        (dolist (fr frames)
          (let* ((is-c (gethash "is_c" fr))
                 (file (and (not is-c) (gethash "file" fr)))
                 (line (and (not is-c) (gethash "line" fr)))
                 (name (gethash "name" fr))
                 (frame-key (format "frame:%d" idx))
                 (frame-row (list :kind :frame :depth 0
                                  :frame-idx idx
                                  :is-c is-c
                                  :file file :line line
                                  :name name
                                  :expandable (not is-c)
                                  :expand-key frame-key)))
            (push-row frame-row)
            (when (and (not is-c) (pwdebug--row-open-p frame-row))
              (dolist (cat-key '("args" "locals" "upvalues"))
                (let* ((items (gethash cat-key fr))
                       (count (length items))
                       (cat-key-full (format "%s:%s" frame-key cat-key))
                       (cat-row (list :kind :category :depth 1
                                      :frame-idx idx
                                      :cat-key cat-key
                                      :label cat-key
                                      :count count
                                      :expandable (> count 0)
                                      :expand-key cat-key-full)))
                  (push-row cat-row)
                  (when (and (> count 0) (pwdebug--row-open-p cat-row))
                    (dolist (it items)
                      (emit-var (gethash "name" it) (gethash "value" it) 2)))))
              ;; ENV: per-function global table.
              (when-let ((env-id (gethash "env_id" fr)))
                (let* ((env-count (or (gethash "env_count" fr) 0))
                       (cat-key-full (format "%s:env" frame-key))
                       (cat-row (list :kind :category :depth 1
                                      :frame-idx idx
                                      :cat-key "env"
                                      :label (format "env (file globals)")
                                      :count env-count
                                      :expandable t
                                      :expand-key cat-key-full
                                      :table-id env-id)))
                  (push-row cat-row)
                  (when (pwdebug--row-open-p cat-row)
                    (emit-table-entries env-id 2))))
              ;; _G: only emit on the innermost frame so we don't drown the user.
              (when (and (= idx 0) (gethash "globals_id" snap))
                (let* ((gid (gethash "globals_id" snap))
                       (cap (and tables (gethash gid tables)))
                       (count (or (and cap (gethash "count" cap)) 0))
                       (cat-key-full (format "%s:globals" frame-key))
                       (cat-row (list :kind :category :depth 1
                                      :frame-idx idx
                                      :cat-key "globals"
                                      :label "_G (globals)"
                                      :count count
                                      :expandable t
                                      :expand-key cat-key-full
                                      :table-id gid)))
                  (push-row cat-row)
                  (when (pwdebug--row-open-p cat-row)
                    (emit-table-entries gid 2))))))
          (setq idx (1+ idx))))
      ;; --- coroutines (compact list at bottom) --------------------------
      (when (and coros (not (null coros)))
        (push-row (list :kind :divider :depth 0))
        (let ((cidx 0))
          (dolist (co coros)
            (let* ((status (gethash "status" co))
                   (where  (gethash "created_at" co))
                   (frames (gethash "frames" co))
                   (key    (format "coro:%d" cidx))
                   (row    (list :kind :coroutine :depth 0
                                 :coro-idx cidx
                                 :status status
                                 :created-at where
                                 :frames frames
                                 :expandable (and frames (> (length frames) 0))
                                 :expand-key key)))
              (push-row row)
              (when (pwdebug--row-open-p row)
                (let ((fidx 0))
                  (dolist (fr frames)
                    (let ((is-c (gethash "is_c" fr)))
                      (push-row (list :kind :coroutine-frame :depth 1
                                      :is-c is-c
                                      :file (and (not is-c) (gethash "file" fr))
                                      :line (and (not is-c) (gethash "line" fr))
                                      :name (gethash "name" fr)
                                      :coro-idx cidx
                                      :frame-idx fidx))
                      (setq fidx (1+ fidx))))))
              (setq cidx (1+ cidx)))))))
    (nreverse rows)))

;; ----- value rendering --------------------------------------------------

(defun pwdebug--render-vref (vref)
  "Render value-ref hash VREF as a propertized string."
  (let* ((type (gethash "type" vref))
         (repr (or (gethash "repr" vref) "?"))
         (count (gethash "count" vref))
         (truncated (gethash "truncated" vref)))
    (concat
     (cond
      ((equal type "string")
       (propertize repr 'face 'pwdebug-locals-string-face))
      ((equal type "number")
       (propertize repr 'face 'pwdebug-locals-number-face))
      ((member type '("boolean" "nil"))
       (propertize repr 'face 'pwdebug-locals-keyword-face))
      ((equal type "function")
       (propertize repr 'face 'pwdebug-locals-function-face))
      ((equal type "table")
       (propertize repr 'face 'pwdebug-locals-table-face))
      (t (propertize repr 'face 'pwdebug-locals-type-face)))
     (cond
      ((equal type "table")
       (propertize (format "  [%d%s]" (or count 0) (if truncated "+" ""))
                   'face 'pwdebug-locals-type-face))
      ((member type '("string" "number" "boolean" "nil" "table")) "")
      (t (propertize (format "  [%s]" type) 'face 'pwdebug-locals-type-face))))))

(defun pwdebug--render-name (name)
  "Render variable NAME (un-quote string keys; bracket non-identifier keys)."
  (cond
   ((null name) "?")
   ((and (stringp name)
         (string-match "\\`\"\\(.*\\)\"\\'" name))
    (let ((inner (match-string 1 name)))
      (if (string-match "\\`[A-Za-z_][A-Za-z0-9_]*\\'" inner)
          (propertize inner 'face 'pwdebug-locals-name-face)
        (propertize (format "[%s]" name)
                    'face 'pwdebug-locals-name-face))))
   ((stringp name)
    (propertize name 'face 'pwdebug-locals-name-face))
   (t (propertize (format "%s" name) 'face 'pwdebug-locals-name-face))))

(defun pwdebug--row-marker (row)
  "Tree marker for ROW: ▾ open, ▸ closed, · leaf, ↺ cycle, ↳ note."
  (cond
   ((eq (plist-get row :kind) :note) "  ")
   ((eq (plist-get row :kind) :divider) "  ")
   ((plist-get row :cycle)
    (propertize "↺ " 'face 'pwdebug-locals-marker-face))
   ((not (plist-get row :expandable))
    (propertize "· " 'face 'pwdebug-locals-marker-face))
   ((pwdebug--row-open-p row)
    (propertize "▾ " 'face 'pwdebug-locals-marker-face))
   (t (propertize "▸ " 'face 'pwdebug-locals-marker-face))))

(defun pwdebug--render-row (row)
  "Render ROW into a single line (no trailing newline)."
  (let* ((kind (plist-get row :kind))
         (depth (or (plist-get row :depth) 0))
         (indent (make-string (* depth 2) ?\s))
         (marker (pwdebug--row-marker row))
         (body
          (pcase kind
            (:header
             (let ((file (plist-get row :file))
                   (line (plist-get row :line))
                   (kind (plist-get row :pause-kind)))
               (propertize
                (format "PAUSED  %s:%d  (%s)  %s"
                        (or (and file (file-name-nondirectory file)) "?")
                        (or line 0)
                        (or kind "?")
                        (format-time-string "%H:%M:%S"))
                'face 'pwdebug-locals-header-face)))
            (:expr
             (concat (propertize "EXPR  " 'face 'pwdebug-locals-section-face)
                     (propertize (or (plist-get row :text) "?")
                                 'face 'pwdebug-locals-name-face)
                     "  =  "
                     (propertize (or (plist-get row :value) "?")
                                 'face 'pwdebug-locals-string-face)))
            (:divider
             (propertize (make-string 50 ?─) 'face 'pwdebug-locals-divider-face))
            (:frame
             (let* ((idx  (plist-get row :frame-idx))
                    (file (plist-get row :file))
                    (line (plist-get row :line))
                    (name (plist-get row :name))
                    (is-c (plist-get row :is-c))
                    (loc  (if is-c (format "[C] %s" (or name "?"))
                            (format "%s:%d  %s"
                                    (or (and file (pwdebug--frame-path-display file)) "?")
                                    (or line 0)
                                    (or name "?")))))
               (propertize (format "#%d  %s" idx loc)
                           'face 'pwdebug-locals-frame-face)))
            (:category
             (let ((label (plist-get row :label))
                   (count (plist-get row :count)))
               (concat (propertize label 'face 'pwdebug-locals-section-face)
                       (when count
                         (propertize (format "  (%d)" count)
                                     'face 'pwdebug-locals-type-face)))))
            (:var
             (concat (pwdebug--render-name (plist-get row :name))
                     " = "
                     (pwdebug--render-vref (plist-get row :value))))
            (:note
             (propertize (plist-get row :label)
                         'face 'pwdebug-locals-note-face))
            (:coroutine
             (propertize
              (format "coroutine #%d  %s  created %s"
                      (plist-get row :coro-idx)
                      (or (plist-get row :status) "?")
                      (or (plist-get row :created-at) "?"))
              'face 'pwdebug-locals-frame-face))
            (:coroutine-frame
             (let ((file (plist-get row :file))
                   (line (plist-get row :line))
                   (name (plist-get row :name))
                   (is-c (plist-get row :is-c)))
               (propertize
                (if is-c (format "[C] %s" (or name "?"))
                  (format "%s:%d  %s"
                          (or (and file (pwdebug--frame-path-display file)) "?")
                          (or line 0)
                          (or name "?")))
                'face 'pwdebug-locals-name-face)))
            (_ ""))))
    (concat indent marker body)))

(defun pwdebug--frame-path-display (file)
  "Trim a FILE path for display: keep the last 2 components when long."
  (if (and file (> (length file) 50))
      (let ((parts (split-string file "/" t)))
        (if (>= (length parts) 2)
            (concat ".../" (mapconcat #'identity (last parts 2) "/"))
          file))
    file))

;; ----- toolbar header line ---------------------------------------------

(defun pwdebug--button (key label cmd)
  "Render a single header-line toolbar button.
KEY is the keyboard shortcut text shown in brackets, LABEL is the
button caption, CMD is the interactive function invoked on click."
  (let ((s (format " [%s] %s " key label)))
    (propertize
     s
     'face 'pwdebug-locals-button-face
     'mouse-face 'mode-line-highlight
     'help-echo (format "%s — bound to %s" label key)
     'keymap
     (let ((m (make-sparse-keymap)))
       (define-key m [header-line mouse-1]
                   (lambda () (interactive) (call-interactively cmd)))
       m))))

(defun pwdebug--locals-header-line ()
  "Build the toolbar header-line for *pwdebug-locals*."
  (concat
   (pwdebug--button "c" "cont"  #'pwdebug-continue)  " "
   (pwdebug--button "s" "step"  #'pwdebug-step)      " "
   (pwdebug--button "n" "next"  #'pwdebug-next)      " "
   (pwdebug--button "f" "finish" #'pwdebug-finish)   "  "
   (pwdebug--button "g" "↻"     #'pwdebug--update-locals-buffer) " "
   (pwdebug--button "?" "help"  #'pwdebug-help)      " "
   (pwdebug--button "q" "hide"  #'quit-window)))

;; ----- buffer rendering & navigation ------------------------------------

(defun pwdebug--render-tree ()
  "Re-render the tree from `pwdebug--snapshot' into the current buffer.
Preserves point on the same expand-key when possible."
  (let* ((snap pwdebug--snapshot)
         (saved-key (pwdebug--row-key-at-point))
         (rows (and snap (pwdebug--build-rows snap)))
         (inhibit-read-only t))
    (erase-buffer)
    (cond
     ((null snap)
      (insert (propertize "(no snapshot — target not paused)\n"
                          'face 'pwdebug-locals-note-face)))
     (t
      (dolist (row rows)
        (let* ((line (pwdebug--render-row row))
               (start (point)))
          (insert line "\n")
          (put-text-property start (point) 'pwdebug-row row)))))
    (goto-char (point-min))
    (when saved-key
      (pwdebug--goto-row-key saved-key))))

(defun pwdebug--row-at-point ()
  "Return the rendered tree row plist at point, or nil."
  (get-text-property (line-beginning-position) 'pwdebug-row))

(defun pwdebug--row-key-at-point ()
  "Return the expand-key of the row at point, or nil."
  (let ((row (pwdebug--row-at-point)))
    (and row (plist-get row :expand-key))))

(defun pwdebug--goto-row-key (key)
  "Move point to the row whose expand-key is KEY.  Return t on success."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (let ((row (pwdebug--row-at-point)))
        (if (and row (equal (plist-get row :expand-key) key))
            (setq found t)
          (forward-line 1))))
    found))

(defun pwdebug-locals-next-row ()
  "Move to the next interactive row."
  (interactive)
  (let ((start (line-beginning-position)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (pwdebug--row-at-point)))
      (forward-line 1))
    (when (eobp) (goto-char start))))

(defun pwdebug-locals-prev-row ()
  "Move to the previous interactive row."
  (interactive)
  (let ((start (line-beginning-position)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (pwdebug--row-at-point)))
      (forward-line -1))
    (unless (pwdebug--row-at-point)
      (goto-char start))))

(defun pwdebug-locals-next-frame ()
  "Move to the next :frame row."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (eq (plist-get (pwdebug--row-at-point) :kind) :frame)))
      (forward-line 1))
    (when (eobp) (goto-char start))))

(defun pwdebug-locals-prev-frame ()
  "Move to the previous :frame row."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (eq (plist-get (pwdebug--row-at-point) :kind) :frame)))
      (forward-line -1))
    (unless (eq (plist-get (pwdebug--row-at-point) :kind) :frame)
      (goto-char start))))

(defun pwdebug-locals-toggle ()
  "Toggle expansion of the row at point."
  (interactive)
  (let ((row (pwdebug--row-at-point)))
    (when (and row (plist-get row :expandable))
      (let* ((key (plist-get row :expand-key))
             (open (pwdebug--row-open-p row)))
        (puthash key (not open) pwdebug--expanded)
        ;; If we are opening a table for the first time, ask the runtime
        ;; for its contents.
        (when (and (not open) (plist-get row :table-id))
          (pwdebug--maybe-request-expand (plist-get row :table-id)))
        (pwdebug--render-tree)))))

(defun pwdebug-locals-expand ()
  "Expand the row at point (no-op if already expanded)."
  (interactive)
  (let ((row (pwdebug--row-at-point)))
    (when (and row (plist-get row :expandable)
               (not (pwdebug--row-open-p row)))
      (pwdebug-locals-toggle))))

(defun pwdebug-locals-collapse ()
  "Collapse the row at point (no-op if already collapsed)."
  (interactive)
  (let ((row (pwdebug--row-at-point)))
    (when (and row (plist-get row :expandable)
               (pwdebug--row-open-p row))
      (pwdebug-locals-toggle))))

(defun pwdebug-locals-collapse-or-up ()
  "Collapse the current row, or jump to its parent."
  (interactive)
  (let ((row (pwdebug--row-at-point)))
    (cond
     ((and row (plist-get row :expandable) (pwdebug--row-open-p row))
      (pwdebug-locals-collapse))
     (t
      (let ((cur-depth (or (and row (plist-get row :depth)) 0))
            (start (point)))
        (forward-line -1)
        (while (and (not (bobp))
                    (let ((r (pwdebug--row-at-point)))
                      (or (null r) (>= (or (plist-get r :depth) 0) cur-depth))))
          (forward-line -1))
        (unless (pwdebug--row-at-point)
          (goto-char start)))))))

(defun pwdebug-locals-activate ()
  "RET: toggle row, and for frame rows also jump to source."
  (interactive)
  (let ((row (pwdebug--row-at-point)))
    (cond
     ((null row))
     ((eq (plist-get row :kind) :frame)
      (let ((file (plist-get row :file))
            (line (plist-get row :line)))
        (when (and file line) (pwdebug--show-source file line)))
      (when (plist-get row :expandable) (pwdebug-locals-toggle)))
     ((eq (plist-get row :kind) :coroutine-frame)
      (let ((file (plist-get row :file))
            (line (plist-get row :line)))
        (when (and file line) (pwdebug--show-source file line))))
     ((eq (plist-get row :kind) :header)
      (let ((file (plist-get row :file))
            (line (plist-get row :line)))
        (when (and file line) (pwdebug--show-source file line))))
     ((plist-get row :expandable)
      (pwdebug-locals-toggle)))))

(defun pwdebug-locals-mouse-toggle (event)
  "Mouse click handler: jump to EVENT's position and toggle the row there."
  (interactive "e")
  (mouse-set-point event)
  (pwdebug-locals-activate))

(defun pwdebug--maybe-request-expand (table-id)
  "Send `expand <id>' if we don't yet have TABLE-ID's contents."
  (when (and table-id pwdebug--snapshot)
    (let* ((tables (gethash "tables" pwdebug--snapshot))
           (cap    (and tables (gethash table-id tables))))
      (unless cap
        (puthash table-id t pwdebug--pending-expansions)
        (pwdebug--write-cmd (concat "expand " table-id))))))

(defun pwdebug--update-locals-buffer ()
  "Refresh *pwdebug-locals* from the JSON snapshot."
  (interactive)
  (let* ((mtime (pwdebug--snapshot-mtime))
         (buf (get-buffer-create "*pwdebug-locals*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'pwdebug-locals-mode)
        (pwdebug-locals-mode))
      (when (or (null mtime)
                (not (equal mtime pwdebug--snapshot-mtime))
                (called-interactively-p 'any))
        (let ((snap (pwdebug--read-snapshot)))
          (when snap
            (setq pwdebug--snapshot snap
                  pwdebug--snapshot-mtime mtime)
            ;; A pause refresh: clear pending expansions that are now
            ;; resolved (their tables appeared in `tables').
            (let ((tables (gethash "tables" snap)))
              (when (hash-table-p pwdebug--pending-expansions)
                (maphash
                 (lambda (id _)
                   (when (and tables (gethash id tables))
                     (remhash id pwdebug--pending-expansions)))
                 pwdebug--pending-expansions)))
            (pwdebug--render-tree)))))
    buf))

;; ----- help popup ------------------------------------------------------

(defvar pwdebug--help-text
  "pwdebug — keys
─────────────────────────────────────────────────────────────

In any pwdebug-mode buffer (your Lua source files):
  C-c d b      Toggle plain breakpoint at this line
  C-u C-c d b  Toggle CONDITIONAL breakpoint (prompts for Lua expr)
  C-c d B      Set/replace the condition on this line
  C-c d i      Toggle info-point (prompts for display expression)
  C-c d e      Edit the expression on the point at this line
  C-c d l      Pop up the list of all configured points
  C-c d C      Clear ALL points
  C-c d ?      Show this help

A breakpoint is unconditional by default and pauses every time it
is hit. With a condition, the runtime evaluates the Lua expression
against the current locals/upvalues/globals and only pauses when
the result is truthy. Info-points never pause; they capture a
snapshot and write the value of `expr' into the locals view.

When the target is paused (focus on *pwdebug-locals*):
  RET / TAB    Expand / collapse the row at point (or jump to
               source for frame rows)
  +  / →       Expand only
  -  / ←       Collapse only / step up to parent
  j / ↓        Next row
  k / ↑        Previous row
  M-n / M-p    Next / previous stack frame

  c            Continue
  s            Step into (next Lua line, follows calls)
  n            Step over (next line in current function)
  f            Finish / step out (run until current function returns)

  g            Refresh from the snapshot file
  q            Hide the locals window

The fringe shows ● for breakpoints, ◆ for info-points (gray when
disabled). Lines with an expression render the condition above the
code line: `╎ IF user.id == 5' for conditional bps, `╎ EXPR ...'
for info-points.
")

(defun pwdebug-help ()
  "Pop up a help buffer summarising every pwdebug binding."
  (interactive)
  (let ((buf (get-buffer-create "*pwdebug-help*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert pwdebug--help-text))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

(defun pwdebug--clear-paused-overlay ()
  "Remove the highlight on the previously-paused source line."
  (when (and pwdebug--paused-overlay (overlay-buffer pwdebug--paused-overlay))
    (delete-overlay pwdebug--paused-overlay))
  (setq pwdebug--paused-overlay nil))

;; ----- window management -------------------------------------------
;;
;; We pin the source code to a single dedicated window: when the paused
;; line moves to a different file we *replace the buffer in that same
;; window* instead of letting `display-buffer' open a new one.  The
;; locals buffer lives in a side window on the right.

(defvar pwdebug--source-window nil
  "The window pwdebug uses to display the paused-source buffer.")

(defun pwdebug--source-window-live-p ()
  "Return non-nil if the dedicated source window still exists."
  (and pwdebug--source-window
       (window-live-p pwdebug--source-window)))

(defun pwdebug--show-source (file line)
  "Visit FILE at LINE in the dedicated pwdebug source window."
  (let ((buf (or (find-buffer-visiting file)
                 (and (file-readable-p file) (find-file-noselect file)))))
    (unless buf (user-error "Cannot open %s" file))
    ;; Pick / reuse the source window.
    (unless (pwdebug--source-window-live-p)
      (setq pwdebug--source-window
            (or (get-buffer-window buf)
                (selected-window))))
    (set-window-buffer pwdebug--source-window buf)
    (with-selected-window pwdebug--source-window
      (goto-char (point-min))
      (forward-line (1- line))
      (recenter))
    ;; Highlight the paused line.
    (with-current-buffer buf
      (pwdebug--clear-paused-overlay)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (setq pwdebug--paused-overlay
              (make-overlay (line-beginning-position)
                            (line-beginning-position 2))))
      (overlay-put pwdebug--paused-overlay 'face 'pwdebug-paused-face)
      (overlay-put pwdebug--paused-overlay 'priority 100))))

(defun pwdebug--show-locals-side-window (lbuf)
  "Display LBUF in a dedicated right-side window (or reuse it)."
  (let ((win (get-buffer-window lbuf)))
    (if win
        win
      (display-buffer-in-side-window
       lbuf
       `((side          . right)
         (window-width  . ,pwdebug-locals-window-width)
         (slot          . 0))))))

(defun pwdebug--show-paused (file line)
  "Pause UI: source window jumps to FILE:LINE, locals buffer pops up."
  (pwdebug--show-source file line)
  (let ((lbuf (pwdebug--update-locals-buffer)))
    (when lbuf (pwdebug--show-locals-side-window lbuf))))

(defun pwdebug--poll ()
  "Read the runtime state file and react to pause transitions."
  (when (file-readable-p pwdebug-state-file)
    (with-temp-buffer
      (insert-file-contents pwdebug-state-file)
      (goto-char (point-min))
      (cond
       ((looking-at "paused\n\\(.*\\)\n\\([0-9]+\\)")
        (let ((file (match-string 1))
              (line (string-to-number (match-string 2))))
          (unless (equal pwdebug--last-pause (cons file line))
            (setq pwdebug--last-pause (cons file line))
            (pwdebug--show-paused file line))))
       ((looking-at "running")
        (when pwdebug--last-pause
          (setq pwdebug--last-pause nil)
          (pwdebug--clear-paused-overlay)))
       ((looking-at "exited")
        (when pwdebug--last-pause
          (setq pwdebug--last-pause nil)
          (pwdebug--clear-paused-overlay)))))))

(defun pwdebug-start-polling ()
  "Begin polling the runtime state file."
  (interactive)
  (unless pwdebug--poll-timer
    (setq pwdebug--poll-timer
          (run-with-timer pwdebug-poll-interval
                          pwdebug-poll-interval
                          #'pwdebug--poll))
    (message "pwdebug: polling started")))

(defun pwdebug-stop-polling ()
  "Stop polling."
  (interactive)
  (when pwdebug--poll-timer
    (cancel-timer pwdebug--poll-timer)
    (setq pwdebug--poll-timer nil)
    (message "pwdebug: polling stopped")))

;; ---------------------------------------------------------------------
;; Minor mode + keymap
;; ---------------------------------------------------------------------

(defvar pwdebug-prefix-map
  (let ((p (make-sparse-keymap)))
    ;; Points.
    (define-key p (kbd "b") #'pwdebug-toggle-breakpoint)
    (define-key p (kbd "B") #'pwdebug-set-conditional-breakpoint)
    (define-key p (kbd "i") #'pwdebug-toggle-infopoint)
    (define-key p (kbd "e") #'pwdebug-edit-expression)
    (define-key p (kbd "l") #'pwdebug-list-points)
    (define-key p (kbd "C") #'pwdebug-clear-all)
    ;; Pause control.
    (define-key p (kbd "c") #'pwdebug-continue)
    (define-key p (kbd "s") #'pwdebug-step)
    (define-key p (kbd "n") #'pwdebug-next)
    (define-key p (kbd "f") #'pwdebug-finish)
    ;; Help.
    (define-key p (kbd "?") #'pwdebug-help)
    (define-key p (kbd "h") #'pwdebug-help)
    p)
  "Prefix keymap for `pwdebug-mode'.
This is intentionally not bound to anything by default — Emacs
reserves `C-c LETTER' sequences for user customisations, so the
package cannot ship one.  Bind it from your config, for example:

  (global-set-key (kbd \"C-c d\") pwdebug-prefix-map)")

(defvar pwdebug-mode-map
  (make-sparse-keymap)
  "Keymap for `pwdebug-mode'.
Empty by default; bind `pwdebug-prefix-map' to a key of your
choice (see its docstring) or add commands here directly.")

;;;###autoload
(define-minor-mode pwdebug-mode
  "Minor mode that lets you set pwdebug breakpoints from this buffer."
  :lighter " pwdbg"
  :keymap pwdebug-mode-map
  (if pwdebug-mode
      (progn
        (pwdebug--refresh-fringe-this-buffer)
        (pwdebug-start-polling))
    (pwdebug--clear-point-overlays)))

;;;###autoload
(defun pwdebug-enable-here ()
  "Convenience: enable `pwdebug-mode' in the current buffer.
Intended to be added to `lua-mode-hook' for files under pwcore."
  (let ((root (pwdebug-pwcore-root)))
    (when (and root buffer-file-name
               (string-prefix-p (expand-file-name root)
                                (expand-file-name buffer-file-name)))
      (pwdebug-mode 1))))

(provide 'pwdebug)

;;; pwdebug.el ends here
