;;; luaprobe.el --- Emacs front-end for the LuaProbe Lua debugger -*- lexical-binding: t; -*-

;; Copyright (C) 2026  António Cardoso

;; Author: António Cardoso <finance@plugwise.com>
;; Maintainer: António Cardoso <finance@plugwise.com>
;; URL: https://github.com/PlugwiseBV/LuaProbe.el
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

;; luaprobe.el drives the LuaProbe Lua debugger
;; (https://github.com/PlugwiseBV/LuaProbe) from inside Emacs.  It
;; manages a persistent list of breakpoints (plain, log-only,
;; conditional), draws fringe markers in source buffers, and launches
;; a Lua program under LuaProbe in a comint buffer with the
;; breakpoints already wired up.  When the target pauses, the source
;; window auto-jumps to the location.

;; Quick start:
;;   1. M-x luaprobe-install   -- clones the LuaProbe repo (one-time).
;;   2. Open your Lua source files; turn on `luaprobe-mode'.
;;      C-c d b   toggles a plain breakpoint.
;;      C-u C-c d b   prompts for a condition (conditional bp).
;;      C-c d L   toggles "log-only" on the point at point.
;;      C-c d ?   shows the full key map.
;;   3. M-x luaprobe-launch   -- runs the current buffer's file under
;;      LuaProbe.  Type `c', `s', `n', `f' at the (luaprobe) prompt
;;      for continue / step / next / finish.

;; Breakpoint storage: a Lua table at
;; ~/.config/luaprobe/breakpoints.lua with one entry per point.  At
;; launch time these are formatted into LuaProbe's spec syntax
;; (`FILE:LINE[!] [if EXPR]', one per line) and passed via
;; `LUAPROBE_BREAKPOINTS' (or `-b' flags to bin/luaprobe).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'comint)

(defvar luaprobe-mode)  ; forward declaration; defined at the bottom.

;; ---------------------------------------------------------------------
;; User options
;; ---------------------------------------------------------------------

(defgroup luaprobe nil
  "Front-end for the LuaProbe Lua debugger."
  :group 'tools
  :prefix "luaprobe-")

(defcustom luaprobe-points-file
  (expand-file-name "~/.config/luaprobe/breakpoints.lua")
  "File where breakpoints are persisted between sessions."
  :type 'file)

(defcustom luaprobe-install-dir
  (expand-file-name "~/.local/share/luaprobe")
  "Directory where `luaprobe-install' clones the LuaProbe repo."
  :type 'directory)

(defcustom luaprobe-repo-url
  "https://github.com/PlugwiseBV/LuaProbe"
  "Git URL `luaprobe-install' clones from."
  :type 'string)

(defcustom luaprobe-lua-program "lua5.1"
  "Lua interpreter used to run the target program under the debugger."
  :type 'string)

(defcustom luaprobe-source-dirs '(".")
  "Directories LuaProbe searches when resolving source files for display.
Each is passed as `-s DIR' to bin/luaprobe."
  :type '(repeat directory))

(defcustom luaprobe-jump-on-pause t
  "If non-nil, jump the source window to the line LuaProbe paused on."
  :type 'boolean)

;; ---------------------------------------------------------------------
;; Faces
;; ---------------------------------------------------------------------

(defface luaprobe-breakpoint-face
  '((t :foreground "red" :weight bold))
  "Face for stop-breakpoint markers in the fringe.")

(defface luaprobe-log-face
  '((t :foreground "DeepSkyBlue" :weight bold))
  "Face for log-only breakpoint markers in the fringe.")

(defface luaprobe-disabled-face
  '((t :foreground "gray50"))
  "Face for disabled point markers.")

(defface luaprobe-paused-face
  '((t :background "khaki" :extend t))
  "Face for the line where execution is currently paused.")

(defface luaprobe-condition-face
  '((t :inherit font-lock-doc-face :slant italic
       :foreground "DeepSkyBlue"))
  "Face for the inline condition / log-spec line above a point.")

(defface luaprobe-locals-header-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the PAUSED header in the *luaprobe-locals* buffer.")

(defface luaprobe-locals-section-face
  '((t :inherit font-lock-type-face :weight bold))
  "Face for `frames' / `locals' / `upvalues' / `entry' section labels.")

(defface luaprobe-locals-frame-face
  '((t :inherit font-lock-function-name-face))
  "Face for stack frame entries in the *luaprobe-locals* buffer.")

(defface luaprobe-locals-name-face
  '((t :inherit font-lock-variable-name-face))
  "Face for variable names in the *luaprobe-locals* buffer.")

(defface luaprobe-locals-current-face
  '((t :inherit font-lock-function-name-face :weight bold
       :underline t))
  "Face for the currently-selected frame in the *luaprobe-locals* buffer.")

(defface luaprobe-locals-button-face
  '((t :inherit mode-line-emphasis :weight bold
       :box (:line-width 1 :style released-button)))
  "Face for header-line toolbar buttons in *luaprobe-locals*.")

(defcustom luaprobe-locals-window-width 60
  "Width in columns of the *luaprobe-locals* side window."
  :type 'integer)

;; Fringe bitmaps.
(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'luaprobe-bp-fringe
    [#b00111100 #b01111110 #b11111111 #b11111111
     #b11111111 #b11111111 #b01111110 #b00111100])
  (define-fringe-bitmap 'luaprobe-log-fringe
    [#b00011000 #b00111100 #b01111110 #b11111111
     #b11111111 #b01111110 #b00111100 #b00011000]))

;; ---------------------------------------------------------------------
;; Breakpoint persistence
;; ---------------------------------------------------------------------
;;
;; Each point is a plist with keys :file, :line, :kind, :cond, :enabled.
;;   :kind is "bp" (stop) or "log" (log-only, the LuaProbe `!' suffix).
;;   :cond is the optional Lua condition expression, or nil.
;; Stored on disk as a `return {...}' Lua module so the LuaProbe TUI
;; (or any other Lua tool) could read it too.

(defun luaprobe--lua-quote (s)
  "Quote string S as a Lua string literal."
  (concat "\""
          (replace-regexp-in-string
           "\"" "\\\\\""
           (replace-regexp-in-string "\\\\" "\\\\\\\\" s))
          "\""))

(defun luaprobe--read-points ()
  "Parse the persistent points file into a list of plists."
  (let ((points '()))
    (when (file-readable-p luaprobe-points-file)
      (with-temp-buffer
        (insert-file-contents luaprobe-points-file)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "{file=\"\\([^\"]*\\)\","
                        "[[:space:]]*line=\\([0-9]+\\),"
                        "[[:space:]]*kind=\"\\([^\"]*\\)\","
                        "[[:space:]]*cond=\\(nil\\|\"\\(?:[^\"\\\\]\\|\\\\.\\)*\"\\),"
                        "[[:space:]]*enabled=\\(true\\|false\\)}")
                nil t)
          (let* ((file (match-string 1))
                 (line (string-to-number (match-string 2)))
                 (kind (match-string 3))
                 (cond-raw (match-string 4))
                 (enabled (string= (match-string 5) "true"))
                 (cond-val (and (not (string= cond-raw "nil"))
                                (substring cond-raw 1 -1))))
            (push (list :file file :line line :kind kind
                        :cond cond-val :enabled enabled)
                  points)))))
    (nreverse points)))

(defun luaprobe--write-points (points)
  "Atomically rewrite the persistent points file with POINTS."
  (let ((dir (file-name-directory luaprobe-points-file)))
    (unless (file-directory-p dir) (make-directory dir t)))
  (let ((tmp (concat luaprobe-points-file ".tmp.emacs")))
    (with-temp-file tmp
      (insert "-- luaprobe breakpoints (managed by luaprobe.el).\n"
              "return {\n")
      (dolist (p points)
        (insert (format "  {file=%s, line=%d, kind=%s, cond=%s, enabled=%s},\n"
                        (luaprobe--lua-quote (plist-get p :file))
                        (plist-get p :line)
                        (luaprobe--lua-quote (or (plist-get p :kind) "bp"))
                        (if (plist-get p :cond)
                            (luaprobe--lua-quote (plist-get p :cond))
                          "nil")
                        (if (plist-get p :enabled) "true" "false"))))
      (insert "}\n"))
    (rename-file tmp luaprobe-points-file t)))

(defun luaprobe--find-point (points file line)
  "Find the entry in POINTS that matches FILE and LINE, or nil."
  (cl-find-if (lambda (p) (and (string= (plist-get p :file) file)
                               (= (plist-get p :line) line)))
              points))

(defun luaprobe--point-to-spec (p)
  "Format point P as a LuaProbe spec string (FILE:LINE[!] [if EXPR])."
  (concat (plist-get p :file)
          ":" (number-to-string (plist-get p :line))
          (if (string= (plist-get p :kind) "log") "!" "")
          (if (plist-get p :cond)
              (concat " if " (plist-get p :cond))
            "")))

;; ---------------------------------------------------------------------
;; Fringe overlays + condition fake-line
;; ---------------------------------------------------------------------

(defvar-local luaprobe--point-overlays nil
  "Overlays placed by `luaprobe-mode' for fringe markers.")

(defvar luaprobe--paused-overlay nil
  "Single overlay marking the line currently paused on (any buffer).")

(defun luaprobe--clear-point-overlays ()
  "Delete every fringe / condition overlay this buffer has placed."
  (mapc #'delete-overlay luaprobe--point-overlays)
  (setq luaprobe--point-overlays nil))

(defun luaprobe--line-leading-whitespace ()
  "Return the leading whitespace of the line at point, as a string."
  (save-excursion
    (beginning-of-line)
    (let ((s (point)))
      (skip-chars-forward " \t")
      (buffer-substring-no-properties s (point)))))

(defun luaprobe--annotation-line (point enabled-face)
  "Build the inline annotation text for POINT, or nil if there is nothing to show.
Conditional points get `╎ IF <expr>'; log-only points get
`╎ LOG'.  ENABLED-FACE is used so disabled points render dim."
  (let ((cond (plist-get point :cond))
        (kind (plist-get point :kind)))
    (when (or cond (string= kind "log"))
      (let* ((indent (luaprobe--line-leading-whitespace))
             (label (cond
                     (cond (concat "IF " cond))
                     ((string= kind "log") "LOG")
                     (t nil))))
        (concat indent
                (propertize "╎ " 'face enabled-face)
                (propertize label 'face enabled-face)
                "\n")))))

(defun luaprobe--refresh-fringe-this-buffer ()
  "Walk the points file and place fringe markers in this buffer."
  (when (and luaprobe-mode buffer-file-name)
    (luaprobe--clear-point-overlays)
    (let ((file (file-truename buffer-file-name))
          (points (luaprobe--read-points)))
      (save-excursion
        (dolist (p points)
          (when (string= (file-truename (plist-get p :file)) file)
            (goto-char (point-min))
            (forward-line (1- (plist-get p :line)))
            (let* ((line-pos (line-beginning-position))
                   (enabled (plist-get p :enabled))
                   (kind (plist-get p :kind))
                   (face (cond
                          ((not enabled) 'luaprobe-disabled-face)
                          ((string= kind "log") 'luaprobe-log-face)
                          (t 'luaprobe-breakpoint-face)))
                   (cond-face (if enabled 'luaprobe-condition-face
                                'luaprobe-disabled-face))
                   (bitmap (if (string= kind "log")
                               'luaprobe-log-fringe
                             'luaprobe-bp-fringe))
                   (fringe-text (propertize "x" 'display
                                            `(left-fringe ,bitmap ,face)))
                   (annot (luaprobe--annotation-line p cond-face))
                   (before (if annot (concat annot fringe-text) fringe-text))
                   (ov (make-overlay line-pos line-pos)))
              (overlay-put ov 'before-string before)
              (overlay-put ov 'luaprobe-point t)
              (push ov luaprobe--point-overlays))))))))

(defun luaprobe--refresh-fringe-all-buffers ()
  "Re-place fringe markers in every buffer with `luaprobe-mode' on."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when luaprobe-mode (luaprobe--refresh-fringe-this-buffer)))))

;; ---------------------------------------------------------------------
;; Toggle commands (operate on the source buffer)
;; ---------------------------------------------------------------------

(defun luaprobe--toggle (kind &optional cond)
  "Toggle a point of KIND (\"bp\" or \"log\") at the current line.
COND is the optional Lua condition expression.  When the same
kind+cond combination already exists at this line we remove it;
otherwise we add or replace whatever was there."
  (unless buffer-file-name (user-error "Buffer has no file"))
  (let* ((file (file-truename buffer-file-name))
         (line (line-number-at-pos))
         (points (luaprobe--read-points))
         (existing (luaprobe--find-point points file line)))
    (cond
     ;; Same kind + same cond → remove (true toggle).
     ((and existing
           (string= (plist-get existing :kind) kind)
           (equal (plist-get existing :cond) cond))
      (setq points (cl-remove-if
                    (lambda (p) (and (string= (plist-get p :file) file)
                                     (= (plist-get p :line) line)))
                    points))
      (message "luaprobe: removed %s at %s:%d" kind
               (file-name-nondirectory file) line))
     ;; Existing point → update in place.
     (existing
      (setf (cl-getf existing :kind) kind)
      (setf (cl-getf existing :cond) cond)
      (message "luaprobe: updated %s at %s:%d%s" kind
               (file-name-nondirectory file) line
               (if cond (format " if %s" cond) "")))
     ;; Nothing there → add.
     (t
      (setq points (append points
                           (list (list :file file :line line
                                       :kind kind :cond cond :enabled t))))
      (message "luaprobe: added %s at %s:%d%s" kind
               (file-name-nondirectory file) line
               (if cond (format " if %s" cond) ""))))
    (luaprobe--write-points points)
    (luaprobe--refresh-fringe-all-buffers)
    (luaprobe--push-points-to-running-session)))

;;;###autoload
(defun luaprobe-toggle-breakpoint (&optional with-condition)
  "Toggle a stop breakpoint at the current line.
With prefix arg WITH-CONDITION, prompt for a Lua condition; the
breakpoint then only pauses when that expression is truthy at hit
time \(locals + upvalues + _G are in scope\)."
  (interactive "P")
  (let ((cond (and with-condition
                   (let ((s (read-string "Pause when (Lua condition): ")))
                     (and (not (string-empty-p s)) s)))))
    (luaprobe--toggle "bp" cond)))

;;;###autoload
(defun luaprobe-set-conditional-breakpoint (cond)
  "Set or update a conditional breakpoint at the current line.
COND is the Lua condition; the breakpoint pauses only when it
evaluates truthy.  Empty input is rejected — use
`luaprobe-toggle-breakpoint' for an unconditional one."
  (interactive (list (read-string "Pause when (Lua condition): ")))
  (when (string-empty-p cond)
    (user-error "Empty condition; use C-c d b for an unconditional breakpoint"))
  (luaprobe--toggle "bp" cond))

;;;###autoload
(defun luaprobe-toggle-log (&optional with-condition)
  "Toggle a log-only breakpoint at the current line.
Log breakpoints don't pause the target — LuaProbe writes the
break event to its log and the program keeps running.  With
prefix arg WITH-CONDITION, prompt for a Lua condition."
  (interactive "P")
  (let ((cond (and with-condition
                   (let ((s (read-string "Log when (Lua condition): ")))
                     (and (not (string-empty-p s)) s)))))
    (luaprobe--toggle "log" cond)))

(defun luaprobe-edit-condition ()
  "Edit (or clear) the condition on the point at the current line."
  (interactive)
  (let* ((file (file-truename (or buffer-file-name
                                  (user-error "No file"))))
         (line (line-number-at-pos))
         (points (luaprobe--read-points))
         (existing (luaprobe--find-point points file line)))
    (unless existing
      (user-error "No point at this line"))
    (let ((new (read-string "Condition (empty to clear): "
                            (or (plist-get existing :cond) ""))))
      (setf (cl-getf existing :cond)
            (and (not (string-empty-p new)) new))
      (luaprobe--write-points points)
      (luaprobe--refresh-fringe-all-buffers)
      (luaprobe--push-points-to-running-session))))

(defun luaprobe-toggle-enabled ()
  "Toggle the enabled flag on the point at the current line."
  (interactive)
  (let* ((file (file-truename (or buffer-file-name (user-error "No file"))))
         (line (line-number-at-pos))
         (points (luaprobe--read-points))
         (existing (luaprobe--find-point points file line)))
    (unless existing (user-error "No point at this line"))
    (setf (cl-getf existing :enabled) (not (plist-get existing :enabled)))
    (luaprobe--write-points points)
    (luaprobe--refresh-fringe-all-buffers)
    (luaprobe--push-points-to-running-session)
    (message "luaprobe: %s point at %s:%d"
             (if (plist-get existing :enabled) "enabled" "disabled")
             (file-name-nondirectory file) line)))

(defun luaprobe-clear-all ()
  "Remove every configured point (after confirmation)."
  (interactive)
  (when (yes-or-no-p "Remove all luaprobe breakpoints? ")
    (luaprobe--write-points nil)
    (luaprobe--refresh-fringe-all-buffers)
    (luaprobe--push-points-to-running-session)
    (message "luaprobe: cleared all points")))

;; ---------------------------------------------------------------------
;; List buffer
;; ---------------------------------------------------------------------

(defun luaprobe-list-points ()
  "Pop up a buffer listing every configured point."
  (interactive)
  (let ((buf (get-buffer-create "*luaprobe-points*"))
        (points (luaprobe--read-points)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%d point%s configured\n\n"
                        (length points)
                        (if (= (length points) 1) "" "s")))
        (dolist (p points)
          (insert (format " %s %-3s %s:%d%s%s\n"
                          (if (plist-get p :enabled) "●" "○")
                          (plist-get p :kind)
                          (plist-get p :file)
                          (plist-get p :line)
                          (if (plist-get p :cond)
                              (format "  if %s" (plist-get p :cond))
                            "")
                          ""))))
      (special-mode))
    (display-buffer buf)))

;; ---------------------------------------------------------------------
;; Install command
;; ---------------------------------------------------------------------

(defun luaprobe--install-dir-valid-p ()
  "Return non-nil if `luaprobe-install-dir' is a usable LuaProbe checkout."
  (and (file-directory-p luaprobe-install-dir)
       (file-readable-p (expand-file-name "luaprobe.lua" luaprobe-install-dir))
       (file-readable-p (expand-file-name "luaprobe_stub.lua" luaprobe-install-dir))
       (file-executable-p (expand-file-name "bin/luaprobe" luaprobe-install-dir))))

;;;###autoload
(defun luaprobe-install (&optional update)
  "Clone the LuaProbe Lua repo into `luaprobe-install-dir'.
With prefix arg UPDATE, run `git pull' if the directory is
already a clone."
  (interactive "P")
  (let ((dir luaprobe-install-dir))
    (cond
     ((and (file-directory-p dir) update)
      (let ((default-directory dir))
        (message "luaprobe: updating %s ..." dir)
        (let ((rc (call-process "git" nil "*luaprobe-install*" t "pull" "--ff-only")))
          (if (zerop rc)
              (message "luaprobe: updated.")
            (display-buffer "*luaprobe-install*")
            (user-error "Git pull failed (exit %d) — see *luaprobe-install*" rc)))))
     ((file-directory-p dir)
      (if (luaprobe--install-dir-valid-p)
          (message "luaprobe: already installed at %s (use C-u to update)" dir)
        (user-error "%s exists but doesn't look like a LuaProbe checkout" dir)))
     (t
      (make-directory (file-name-directory (directory-file-name dir)) t)
      (message "luaprobe: cloning %s ..." luaprobe-repo-url)
      (let ((rc (call-process "git" nil "*luaprobe-install*" t
                              "clone" luaprobe-repo-url dir)))
        (if (zerop rc)
            (message "luaprobe: installed at %s" dir)
          (display-buffer "*luaprobe-install*")
          (user-error "Git clone failed (exit %d) — see *luaprobe-install*" rc)))))))

;; ---------------------------------------------------------------------
;; Launch command (comint)
;; ---------------------------------------------------------------------

(defvar luaprobe--session-buffer nil
  "The currently-running *luaprobe* comint buffer, if any.")

(defun luaprobe--enabled-points ()
  "Return the list of enabled points read from the persisted file."
  (cl-remove-if-not (lambda (p) (plist-get p :enabled))
                    (luaprobe--read-points)))

(defun luaprobe--bp-args (points)
  "Convert POINTS into the `-b SPEC' argv pairs for bin/luaprobe."
  (let (out)
    (dolist (p points (nreverse out))
      (push "-b" out)
      (push (luaprobe--point-to-spec p) out))))

(defun luaprobe--source-args ()
  "Convert `luaprobe-source-dirs' into the `-s DIR' argv pairs."
  (let (out)
    (dolist (d luaprobe-source-dirs (nreverse out))
      (push "-s" out)
      (push (expand-file-name d) out))))

(defun luaprobe--bin-luaprobe ()
  "Absolute path to bin/luaprobe inside the install dir.
Signals if the install dir is missing or incomplete."
  (unless (luaprobe--install-dir-valid-p)
    (user-error "LuaProbe is not installed; run M-x luaprobe-install"))
  (expand-file-name "bin/luaprobe" luaprobe-install-dir))

(defun luaprobe--cleanup-session ()
  "Tear down any previous session, ready for a fresh launch.
Kills the `*luaprobe*' comint buffer, the `*luaprobe-locals*'
side buffer, and removes the paused-line overlay."
  (let ((kill-buffer-query-functions nil))
    (when (and luaprobe--session-buffer
               (buffer-live-p luaprobe--session-buffer))
      (let ((proc (get-buffer-process luaprobe--session-buffer)))
        (when (process-live-p proc)
          (set-process-query-on-exit-flag proc nil)))
      (kill-buffer luaprobe--session-buffer))
    (setq luaprobe--session-buffer nil)
    (when (get-buffer "*luaprobe-locals*")
      (kill-buffer "*luaprobe-locals*")))
  (luaprobe--clear-paused-overlay))

;;;###autoload
(defun luaprobe-launch (target &optional args)
  "Run TARGET (a Lua file) under LuaProbe.
ARGS is a string of extra CLI args passed to the target.
Interactively, defaults TARGET to the current buffer's file.

The `*luaprobe*' comint buffer is created but kept hidden — all
debugger state surfaces in the `*luaprobe-locals*' side window
that pops up when the target pauses.  Use
`\\[luaprobe-show-session]' (`o' in the locals buffer) if you ever
need raw access to the bin/luaprobe REPL."
  (interactive
   (list (read-file-name "Lua file: " nil
                         (and buffer-file-name buffer-file-name)
                         t
                         (and buffer-file-name (file-name-nondirectory buffer-file-name)))
         (read-string "Target args: " "")))
  (let* ((bin     (luaprobe--bin-luaprobe))
         (target  (expand-file-name target))
         (target-dir (file-name-directory target))
         (points  (luaprobe--enabled-points))
         (argv    (append
                   (luaprobe--bp-args points)
                   (luaprobe--source-args)
                   (list "-i" luaprobe-lua-program target)
                   (and args (not (string-empty-p args))
                        (split-string-and-unquote args))))
         (buf-name "*luaprobe*"))
    (luaprobe--cleanup-session)
    (let ((default-directory target-dir))
      (setq luaprobe--session-buffer
            (apply #'make-comint-in-buffer "luaprobe" buf-name
                   bin nil argv)))
    (with-current-buffer luaprobe--session-buffer
      (luaprobe-comint-mode))
    (message "luaprobe: launched %s (output is hidden; press `o' in *luaprobe-locals* to show it)"
             (file-name-nondirectory target))))

(defun luaprobe-show-session ()
  "Pop up the hidden `*luaprobe*' comint buffer.
Useful when you want to drive bin/luaprobe directly — type `p NAME'
to deep-inspect a variable, `e EXPR' to evaluate, `bps' to list
breakpoints, etc.  Bury the buffer again with `q'."
  (interactive)
  (unless (and luaprobe--session-buffer
               (buffer-live-p luaprobe--session-buffer))
    (user-error "No luaprobe session running"))
  (display-buffer luaprobe--session-buffer
                  '((display-buffer-reuse-window
                     display-buffer-pop-up-window))))

(defun luaprobe--push-points-to-running-session ()
  "Push the persisted point list to the live LuaProbe session, if any.
We send `b' / `d' commands matching LuaProbe's REPL syntax.  If
no session is running, this is a no-op.  We compare against a
buffer-local cache to only send diffs."
  ;; Note: implemented as a no-op stub for v0.1.0. The current
  ;; comint REPL doesn't expose a clean diff interface, and pushing
  ;; full state on every toggle would be noisy. Users edit points
  ;; before launching, or use the REPL's `b' / `d' commands during
  ;; a session for runtime changes.
  nil)

;; ---------------------------------------------------------------------
;; Comint mode for the *luaprobe* buffer (auto-jump on pause)
;; ---------------------------------------------------------------------

(defvar luaprobe-comint-prompt-regexp "^(luaprobe) "
  "Prompt regexp emitted by bin/luaprobe.")

;; ----- output accumulator + parser ------------------------------------
;;
;; bin/luaprobe prints break events as a fixed-shape text block:
;;
;;   *** BREAK at FILE:LINE  [thread]  (reason=stop)
;;   [    coroutine created at FILE:LINE]    (optional, indented 4 sp.)
;;   * #1  NAME                       FILE:LINE      (frames; * = current)
;;     #2  …
;;
;;   locals:                                          (any of these may
;;     name = value                                    be absent)
;;   upvalues:
;;     name = value
;;   entry (values at function entry):
;;     name = value
;;   (luaprobe)
;;
;; We keep a buffer-local accumulator of comint stdout, and whenever
;; we see a `*** BREAK' followed by the next `(luaprobe)' prompt, we
;; parse the chunk into a plist and re-render *luaprobe-locals*.

(defvar-local luaprobe--accum ""
  "Comint output accumulator for the *luaprobe* buffer.")

(defun luaprobe--comint-output-filter (output)
  "Comint preoutput filter: detect break events in OUTPUT.
Always returns OUTPUT unchanged."
  (when (stringp output)
    (setq luaprobe--accum (concat luaprobe--accum output))
    ;; Process every complete `*** BREAK ... (luaprobe)' block in the
    ;; accumulator; advance past each one as we consume it.
    (let (continue)
      (setq continue t)
      (while continue
        (setq continue nil)
        (let ((break-start (string-match "^\\*\\*\\* BREAK at "
                                         luaprobe--accum)))
          (when break-start
            (let ((prompt-pos (string-match "^(luaprobe) "
                                            luaprobe--accum break-start)))
              (when prompt-pos
                (let* ((chunk (substring luaprobe--accum
                                         break-start prompt-pos))
                       (event (luaprobe--parse-break chunk)))
                  (when event
                    (run-at-time 0 nil #'luaprobe--render-break event)
                    (when luaprobe-jump-on-pause
                      (run-at-time
                       0 nil #'luaprobe--show-paused
                       (plist-get event :file)
                       (plist-get event :line)))))
                (setq luaprobe--accum
                      (substring luaprobe--accum prompt-pos))
                (setq continue t)))))))
    ;; Keep the accumulator bounded.
    (when (> (length luaprobe--accum) 65536)
      (setq luaprobe--accum (substring luaprobe--accum -32768))))
  output)

(defun luaprobe--parse-break (text)
  "Parse a *** BREAK ... block TEXT into a plist."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (event frames)
      (when (re-search-forward
             (concat "^\\*\\*\\* BREAK at \\(.+?\\):\\([0-9]+\\)"
                     "  \\[\\(.+?\\)\\]"
                     "  (reason=\\(.+?\\))$")
             nil t)
        (setq event (list :file   (match-string 1)
                          :line   (string-to-number (match-string 2))
                          :thread (match-string 3)
                          :reason (match-string 4))))
      (goto-char (point-min))
      (when (re-search-forward
             "^    coroutine created at \\(.+?\\):\\([0-9]+\\)" nil t)
        (setq event (plist-put event :created-src  (match-string 1)))
        (setq event (plist-put event :created-line
                               (string-to-number (match-string 2)))))
      (goto-char (point-min))
      (while (re-search-forward
              (concat "^\\([* ]\\) #\\([0-9]+\\)  "
                      "\\(.+?\\)  +"
                      "\\(.+?\\):\\(-?[0-9]+\\)\\s-*$")
              nil t)
        (push (list :idx     (string-to-number (match-string 2))
                    :name    (string-trim (match-string 3))
                    :file    (match-string 4)
                    :line    (string-to-number (match-string 5))
                    :current (string= (match-string 1) "*"))
              frames))
      (when event (setq event (plist-put event :frames (nreverse frames))))
      ;; Sections.
      (dolist (kv '((:locals   . "^locals:$")
                    (:upvalues . "^upvalues:$")
                    (:entry    . "^entry[^:]*:$")))
        (goto-char (point-min))
        (when (re-search-forward (cdr kv) nil t)
          (forward-line 1)
          (let (vars)
            (while (looking-at "^  \\(.+?\\) = \\(.*\\)$")
              (push (list :name (match-string 1)
                          :value (match-string 2))
                    vars)
              (forward-line 1))
            (when event
              (setq event (plist-put event (car kv) (nreverse vars)))))))
      event)))

;; ----- *luaprobe-locals* buffer ---------------------------------------

(defvar-local luaprobe--current-event nil
  "Last parsed break event rendered in this buffer.")

(defun luaprobe--send (cmd)
  "Send CMD as a line to the running *luaprobe* comint process.
Uses `process-send-string' rather than `comint-send-input' so the
write works whether or not the *luaprobe* buffer is currently
displayed.  Also echoes CMD into the comint buffer so the input
shows up if the user later pops it open with `o'."
  (let ((proc (and (bufferp luaprobe--session-buffer)
                   (buffer-live-p luaprobe--session-buffer)
                   (get-buffer-process luaprobe--session-buffer))))
    (cond
     ((not (and proc (process-live-p proc)))
      (user-error "No running luaprobe session"))
     (t
      ;; Echo the input into the buffer for history.
      (with-current-buffer luaprobe--session-buffer
        (let ((inhibit-read-only t))
          (goto-char (process-mark proc))
          (insert cmd "\n")
          (set-marker (process-mark proc) (point))))
      ;; Actually send to the process.
      (process-send-string proc (concat cmd "\n"))))))

(defun luaprobe-locals-continue () "Resume target." (interactive) (luaprobe--send "c"))
(defun luaprobe-locals-step ()     "Step into."    (interactive) (luaprobe--send "s"))
(defun luaprobe-locals-next ()     "Step over."    (interactive) (luaprobe--send "n"))
(defun luaprobe-locals-finish ()   "Step out."     (interactive) (luaprobe--send "f"))
(defun luaprobe-locals-bt ()       "Backtrace."    (interactive) (luaprobe--send "bt"))
(defun luaprobe-locals-quit-target () "Kill target." (interactive)
       (when (yes-or-no-p "Kill the running luaprobe target? ")
         (luaprobe--send "q")))

(defun luaprobe-locals-jump-to-frame ()
  "RET on a frame line: select that frame and jump to its source.
Sends `frame N' to the comint so subsequent `locals'/`p'/`e'
commands run in that frame."
  (interactive)
  (let ((frame (get-text-property (line-beginning-position) 'luaprobe-frame)))
    (cond
     ((null frame) (user-error "Not on a frame"))
     ((string-prefix-p "=[C]" (or (plist-get frame :file) ""))
      (user-error "C frame — no source available"))
     (t
      (luaprobe--show-paused (plist-get frame :file) (plist-get frame :line))
      (luaprobe--send (format "frame %d" (plist-get frame :idx)))))))

(defun luaprobe-locals-next-frame ()
  "Move point to the next frame line."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (get-text-property (line-beginning-position)
                                        'luaprobe-frame)))
      (forward-line 1))
    (unless (get-text-property (line-beginning-position) 'luaprobe-frame)
      (goto-char start))))

(defun luaprobe-locals-prev-frame ()
  "Move point to the previous frame line."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (line-beginning-position)
                                        'luaprobe-frame)))
      (forward-line -1))
    (unless (get-text-property (line-beginning-position) 'luaprobe-frame)
      (goto-char start))))

(defun luaprobe-locals-mouse-jump (event)
  "Mouse-1: jump to the frame at click position EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when (get-text-property (line-beginning-position) 'luaprobe-frame)
    (luaprobe-locals-jump-to-frame)))

(defvar luaprobe-locals-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")     #'luaprobe-locals-jump-to-frame)
    (define-key m (kbd "TAB")     #'luaprobe-locals-jump-to-frame)
    (define-key m (kbd "n")       #'luaprobe-locals-next-frame)
    (define-key m (kbd "p")       #'luaprobe-locals-prev-frame)
    (define-key m (kbd "<down>")  #'luaprobe-locals-next-frame)
    (define-key m (kbd "<up>")    #'luaprobe-locals-prev-frame)
    (define-key m (kbd "c")       #'luaprobe-locals-continue)
    (define-key m (kbd "s")       #'luaprobe-locals-step)
    (define-key m (kbd "N")       #'luaprobe-locals-next)
    (define-key m (kbd "f")       #'luaprobe-locals-finish)
    (define-key m (kbd "o")       #'luaprobe-show-session)
    (define-key m (kbd "?")       #'luaprobe-help)
    (define-key m (kbd "q")       #'quit-window)
    (define-key m [mouse-1]       #'luaprobe-locals-mouse-jump)
    m)
  "Keymap for `luaprobe-locals-mode'.")

(defun luaprobe--button (key label cmd)
  "Render a header-line toolbar button.
KEY is the keyboard letter, LABEL the caption, CMD the command."
  (let ((s (format " [%s] %s " key label)))
    (propertize
     s
     'face 'luaprobe-locals-button-face
     'mouse-face 'mode-line-highlight
     'help-echo (format "%s — bound to %s" label key)
     'keymap (let ((m (make-sparse-keymap)))
               (define-key m [header-line mouse-1]
                 (lambda () (interactive) (call-interactively cmd)))
               m))))

(defun luaprobe--locals-header-line ()
  "Toolbar header-line for *luaprobe-locals*."
  (concat
   (luaprobe--button "c" "cont"   #'luaprobe-locals-continue)   " "
   (luaprobe--button "s" "step"   #'luaprobe-locals-step)       " "
   (luaprobe--button "N" "next"   #'luaprobe-locals-next)       " "
   (luaprobe--button "f" "finish" #'luaprobe-locals-finish)     "  "
   (luaprobe--button "?" "help"   #'luaprobe-help)              " "
   (luaprobe--button "q" "hide"   #'quit-window)))

(define-derived-mode luaprobe-locals-mode special-mode "luaprobe-locals"
  "Major mode for the *luaprobe-locals* buffer."
  (setq-local truncate-lines t)
  (setq-local cursor-in-non-selected-windows t)
  (setq-local header-line-format '(:eval (luaprobe--locals-header-line))))

(defun luaprobe--render-break (event)
  "Render parsed break EVENT into the *luaprobe-locals* buffer."
  (let ((buf (get-buffer-create "*luaprobe-locals*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'luaprobe-locals-mode)
        (luaprobe-locals-mode))
      (setq luaprobe--current-event event)
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Pause banner.
        (insert (propertize
                 (format "PAUSED  %s:%d  (%s)"
                         (or (and (plist-get event :file)
                                  (file-name-nondirectory
                                   (plist-get event :file)))
                             "?")
                         (or (plist-get event :line) 0)
                         (or (plist-get event :reason) "?"))
                 'face 'luaprobe-locals-header-face))
        (insert "\n")
        ;; Thread / coroutine section.
        (let ((thread (plist-get event :thread)))
          (cond
           ((and thread (string= thread "main"))
            (insert (propertize "  thread:    main" 'face 'shadow) "\n"))
           (thread
            (insert (propertize "  thread:    " 'face 'shadow)
                    (propertize (concat "coroutine " thread)
                                'face 'luaprobe-locals-section-face)
                    "\n"))))
        (when (plist-get event :created-src)
          (insert (propertize "  created:   " 'face 'shadow)
                  (propertize
                   (format "%s:%d"
                           (plist-get event :created-src)
                           (plist-get event :created-line))
                   'face 'luaprobe-locals-section-face)
                  "\n"))
        (insert "\n")
        ;; Frames.
        (insert (propertize "frames" 'face 'luaprobe-locals-section-face)
                "  "
                (propertize "(RET to jump / select frame)"
                            'face 'shadow)
                "\n")
        (dolist (f (plist-get event :frames))
          (let* ((cur   (plist-get f :current))
                 (face  (if cur 'luaprobe-locals-current-face
                          'luaprobe-locals-frame-face))
                 (line  (format "  %s#%-2d  %-26s %s:%d"
                                (if cur "▸ " "  ")
                                (plist-get f :idx)
                                (plist-get f :name)
                                (plist-get f :file)
                                (plist-get f :line))))
            (insert (propertize line
                                'face face
                                'luaprobe-frame f
                                'mouse-face 'highlight))
            (insert "\n")))
        (insert "\n")
        ;; Coroutines visible in the current frame.  LuaProbe's
        ;; wire protocol opaquifies coroutine values to "<thread>",
        ;; so we can only point at where they live in scope; query
        ;; live status with `e coroutine.status(NAME)' in the REPL.
        (let (coros)
          (dolist (kv '((:locals . "local")
                        (:upvalues . "upvalue")
                        (:entry . "entry")))
            (dolist (v (plist-get event (car kv)))
              (when (and (plist-get v :value)
                         (string-match-p "\"<thread>\""
                                         (plist-get v :value)))
                (push (list :name (plist-get v :name) :kind (cdr kv))
                      coros))))
          (when coros
            (insert (propertize "coroutines in scope"
                                'face 'luaprobe-locals-section-face)
                    "  "
                    (propertize "(`o' then `e coroutine.status(NAME)')"
                                'face 'shadow)
                    "\n")
            (dolist (c (nreverse coros))
              (insert (format "  %s   %s\n"
                              (propertize (plist-get c :name)
                                          'face 'luaprobe-locals-name-face)
                              (propertize (concat "(" (plist-get c :kind) ")")
                                          'face 'shadow))))
            (insert "\n")))
        ;; Variable sections.
        (dolist (kv '((:locals   . "locals")
                      (:upvalues . "upvalues")
                      (:entry    . "entry (at function entry)")))
          (let ((vars (plist-get event (car kv))))
            (when (and vars (> (length vars) 0))
              (insert (propertize (cdr kv)
                                  'face 'luaprobe-locals-section-face)
                      "\n")
              (dolist (v vars)
                (insert "  "
                        (propertize (plist-get v :name)
                                    'face 'luaprobe-locals-name-face)
                        " = "
                        (or (plist-get v :value) "")
                        "\n"))
              (insert "\n"))))
        (goto-char (point-min)))
      (display-buffer buf
                      `((display-buffer-reuse-window
                         display-buffer-in-side-window)
                        (side . right)
                        (window-width . ,luaprobe-locals-window-width)
                        (slot . 0))))))

(defun luaprobe--clear-paused-overlay ()
  "Remove the highlight on the previously-paused source line."
  (when (and luaprobe--paused-overlay (overlay-buffer luaprobe--paused-overlay))
    (delete-overlay luaprobe--paused-overlay))
  (setq luaprobe--paused-overlay nil))

(defun luaprobe--resolve-source (file)
  "Return an absolute path for FILE, searching `luaprobe-source-dirs'.
Falls back to FILE as-is if nothing matches."
  (cond
   ((file-name-absolute-p file)
    (and (file-readable-p file) file))
   (t
    (or (cl-some (lambda (d)
                   (let ((p (expand-file-name file (expand-file-name d))))
                     (and (file-readable-p p) p)))
                 (cons "." luaprobe-source-dirs))
        file))))

(defun luaprobe--show-paused (file line)
  "Display FILE at LINE and highlight the paused line.
Reuses an existing window already showing the buffer instead of
opening a duplicate."
  (let* ((resolved (luaprobe--resolve-source file))
         (buf (and resolved (find-file-noselect resolved))))
    (unless buf (user-error "Cannot open %s" file))
    (let ((win (or (get-buffer-window buf 'visible)
                   (display-buffer
                    buf
                    '((display-buffer-reuse-window
                       display-buffer-use-some-window)
                      (inhibit-same-window . t)
                      (reusable-frames . visible))))))
      (when win
        (with-selected-window win
          (goto-char (point-min))
          (forward-line (1- line))
          (recenter))))
    (with-current-buffer buf
      (luaprobe--clear-paused-overlay)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (setq luaprobe--paused-overlay
              (make-overlay (line-beginning-position)
                            (line-beginning-position 2))))
      (overlay-put luaprobe--paused-overlay 'face 'luaprobe-paused-face)
      (overlay-put luaprobe--paused-overlay 'priority 100))))

(define-derived-mode luaprobe-comint-mode comint-mode "luaprobe"
  "Comint mode for the *luaprobe* session buffer.
Adds an output filter that parses break events and renders them
into the *luaprobe-locals* side buffer."
  (setq-local comint-prompt-regexp luaprobe-comint-prompt-regexp)
  (setq-local comint-prompt-read-only nil)
  (setq-local luaprobe--accum "")
  (add-hook 'comint-preoutput-filter-functions
            #'luaprobe--comint-output-filter nil t))

;; ---------------------------------------------------------------------
;; Help popup
;; ---------------------------------------------------------------------

(defvar luaprobe--help-text
  "luaprobe — keys
─────────────────────────────────────────────────────────────

In any luaprobe-mode buffer (your Lua source files):
  C-c d b      Toggle plain breakpoint at this line
  C-u C-c d b  Toggle CONDITIONAL breakpoint (prompts for Lua expr)
  C-c d B      Set/replace the condition on this line
  C-c d L      Toggle log-only breakpoint at this line
  C-c d e      Edit the condition on the point at this line
  C-c d t      Toggle enabled / disabled
  C-c d l      List all configured points
  C-c d C      Clear ALL points
  C-c d ?      Show this help

Sessions:
  M-x luaprobe-install        One-time clone of the LuaProbe repo
  M-x luaprobe-launch         Run a Lua file under the debugger
  M-x luaprobe-show-session   Pop up the (hidden) *luaprobe* REPL

When the target pauses, *luaprobe-locals* opens on the right with
the toolbar [c] cont [s] step [N] next [f] finish.  RET / TAB on a
frame jumps the source window AND selects that frame in the
debugger so the next `locals'/`p'/`e' commands run there.

Inside *luaprobe* (only opened on demand via `o' / M-x luaprobe-show-session):
  c   continue                 b FILE:L     add breakpoint
  s   step into                d FILE:L     delete breakpoint
  n   step over                bps          list breakpoints
  f   finish (step out)        bt           backtrace
  l   list source              locals       show locals + upvalues
  p NAME       deep-inspect a local/upvalue
  e EXPR       evaluate Lua expression in the current frame
  frame N      select frame N
  q            quit (kills the target)

When the target pauses, the source window auto-jumps to the
location and highlights the line.

Breakpoints are persisted in `luaprobe-points-file' and converted
to LuaProbe spec format on launch (FILE:LINE[!] [if EXPR]).
")

(defun luaprobe-help ()
  "Pop up a help buffer summarising every luaprobe binding."
  (interactive)
  (let ((buf (get-buffer-create "*luaprobe-help*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert luaprobe--help-text))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

;; ---------------------------------------------------------------------
;; Minor mode + keymap
;; ---------------------------------------------------------------------

(defvar luaprobe-prefix-map
  (let ((p (make-sparse-keymap)))
    ;; Points.
    (define-key p (kbd "b") #'luaprobe-toggle-breakpoint)
    (define-key p (kbd "B") #'luaprobe-set-conditional-breakpoint)
    (define-key p (kbd "L") #'luaprobe-toggle-log)
    (define-key p (kbd "e") #'luaprobe-edit-condition)
    (define-key p (kbd "t") #'luaprobe-toggle-enabled)
    (define-key p (kbd "l") #'luaprobe-list-points)
    (define-key p (kbd "C") #'luaprobe-clear-all)
    ;; Sessions.
    (define-key p (kbd "r") #'luaprobe-launch)
    (define-key p (kbd "o") #'luaprobe-show-session)
    (define-key p (kbd "I") #'luaprobe-install)
    ;; Help.
    (define-key p (kbd "?") #'luaprobe-help)
    (define-key p (kbd "h") #'luaprobe-help)
    p)
  "Prefix keymap for `luaprobe-mode'.
Not bound globally by default — Emacs reserves `C-c LETTER'
sequences for users.  Bind it from your config, for example:

  (global-set-key (kbd \"C-c d\") luaprobe-prefix-map)")

(defvar luaprobe-mode-map
  (make-sparse-keymap)
  "Keymap for `luaprobe-mode'.
Empty by default; bind `luaprobe-prefix-map' to a key of your
choice (see its docstring) or add commands here directly.")

;;;###autoload
(define-minor-mode luaprobe-mode
  "Minor mode that lets you set LuaProbe breakpoints from this buffer."
  :lighter " luaprobe"
  :keymap luaprobe-mode-map
  (if luaprobe-mode
      (luaprobe--refresh-fringe-this-buffer)
    (luaprobe--clear-point-overlays)))

(provide 'luaprobe)

;;; luaprobe.el ends here
