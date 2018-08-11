;;; polymode-test.el --- Test utilities for polymode -*- lexical-binding: t -*-
;;
;; Copyright (C) 2018, Vitalie Spinu
;; Author: Vitalie Spinu
;; URL: https://github.com/vspinu/polymode
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This file is *NOT* part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Code:

(require 'ert)
(require 'polymode)

(setq ert-batch-backtrace-right-margin 130)
(setq pm-verbose (getenv "PM_VERBOSE"))
(setq poly-lock-verbose (getenv "PM_VERBOSE"))

(defvar pm-test-current-change-set nil)

(defvar pm-test-input-dir
  (expand-file-name
   "tests/input"
   (file-name-directory
    (or load-file-name buffer-file-name))))

(defun pm-test-matcher (string span-alist matcher &optional dry-run)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let (prev-span)
      (when dry-run
        (message "("))
      (while (not (eobp))
        (if dry-run
            (let ((span (funcall matcher)))
              (unless (equal prev-span span)
                (setq prev-span span)
                (message " (%d . %S)" (nth 1 span) span)))
          (let* ((span (funcall matcher))
                 (sbeg (nth 1 span))
                 (ref-span (alist-get sbeg span-alist)))
            (unless (equal span ref-span)
              (ert-fail (list :pos (point) :span span :ref-span ref-span)))))
        (forward-char 1))
      (when dry-run
        (message ")")))))

(defmacro pm-test-run-on-string (mode string &rest body)
  "Run BODY in a temporary buffer containing STRING in MODE."
  (declare (indent 2)
           (debug (form form body)))
  `(let ((buf "*pm-test-string-buffer*"))
     (when (get-buffer buf)
       (kill-buffer buf))
     (with-current-buffer (get-buffer-create buf)
       (insert (substring-no-properties ,string))
       (funcall ,mode)
       (setq-default indent-tabs-mode nil)
       (goto-char (point-min))
       (font-lock-ensure)
       ,@body
       (current-buffer))))

(defmacro pm-test-run-on-file (mode file &rest body)
  "Run BODY in a temporary buffer with the content of FILE in MODE."
  (declare (indent 2) (debug (sexp sexp body)))
  `(let ((poly-lock-allow-background-adjustment nil)
         (file (expand-file-name ,file pm-test-input-dir))
         (pm-extra-span-info nil)
         (buf "*pm-test-file-buffer*"))
     (when (get-buffer buf)
       (kill-buffer buf))
     (with-current-buffer (get-buffer-create buf)
       (when pm-verbose
         (message "\n===================  testing %s =======================" file))
       (switch-to-buffer buf)
       (insert-file-contents file)
       (let ((inhibit-message t))
         (funcall-interactively ',mode))
       (goto-char (point-min))
       (font-lock-ensure)
       (goto-char (point-min))
       (save-excursion
         (pm-map-over-spans
          (lambda ()
            (setq font-lock-mode t)
            ;; font-lock is not activated in batch mode
            (poly-lock-mode t)
            ;; redisplay is not triggered in batch and often it doesn't trigger
            ;; fontification in X either (waf?)
            (add-hook 'after-change-functions #'pm-test-invoke-fontification t t))
          (point-min) (point-max)))
       (font-lock-ensure)
       ,@body
       (current-buffer))))

(defun pm-test-chunk ()
  (unless (eq major-mode 'poly-head-tail-mode)
    (let* ((poly-lock-allow-background-adjustment nil)
           (sbeg (nth 1 *span*))
           (send (nth 2 *span*))
           (smode major-mode)
           (stext (buffer-substring-no-properties sbeg send))
           ;; other buffer
           (obuf (pm-test-run-on-string smode stext))
           (opos 1)
           (oend (with-current-buffer obuf (point-max))))
      (when pm-verbose
        (message "---- testing %s ----" (pm-format-span *span* t)))
      (while opos
        (let* ((pos (1- (+ opos sbeg)))
               (face (get-text-property pos 'face))
               (oface (get-text-property opos 'face obuf)))
          (unless (equal face oface)
            (let ((data
                   (append
                    (when pm-test-current-change-set
                      (list :change pm-test-current-change-set))
                    (list
                     :face face
                     :oface oface
                     :pos pos
                     :opos opos
                     :line (progn (goto-char pos)
                                  (buffer-substring-no-properties (point-at-bol) (point-at-eol)))
                     :oline (with-current-buffer obuf
                              (goto-char opos)
                              (buffer-substring-no-properties (point-at-bol) (point-at-eol)))
                     :mode smode))))
              (ert-fail data)))
          (setq opos (next-single-property-change opos 'face obuf)))))))

(defun pm-test-chunks ()
  (save-excursion
    (pm-map-over-spans #'pm-test-chunk)))

(defun pm-test-goto-loc (loc)
  "Go to LOC and switch to polymode indirect buffer.
LOC can be either
  - a number giving position in the buffer
  - regexp to search for from point-min
  - a cons of the form (ROW . COL)
In the last case ROW can be either a number or a regexp to search
for and COL either a column number or symbols beg or end
indicating beginning or end of the line. When COL is nil, goto
indentation."
  (cond
   ((numberp loc)
    (goto-char loc))
   ((stringp loc)
    (goto-char (point-min))
    (re-search-forward loc))
   ((consp loc)
    (goto-char (point-min))
    (let ((row (car loc)))
      (goto-char (point-min))
      (cond
       ((stringp row)
        (re-search-forward row))
       ((numberp row)
        (forward-line (1- row)))
       (t (error "Invalid row spec %s" row))))
    (let* ((col (cdr loc))
           (col (if (listp col)
                    (car col)
                  col)))
      (cond
       ((numberp col)
        (forward-char col))
       ((eq col 'end)
        (end-of-line))
       ((eq col 'beg)
        (beginning-of-line))
       ((null col)
        (back-to-indentation))
       (t (error "Invalid col spec %s" col))))))
  (when polymode-mode
    ;; pm-set-buffer would do for programs but not for interactive debugging
    (pm-switch-to-buffer (point))))

(defun pm-test-goto-loc-other-window (&optional loc)
  "Utility to navigate to LOC at point in other buffer.
LOC is as in `pm-test-goto-loc'."
  (interactive)
  (let* ((loc (or (sexp-at-point)
                  (read--expression "Loc: "))))
    (other-window 1)
    (pm-test-goto-loc loc)))

(defun pm-test-invoke-fontification (&rest _ignore)
  "Mimic calls to fontification functions by redisplay.
Needed because redisplay is not triggered in batch mode."
  (when fontification-functions
    (save-restriction
      (widen)
      (save-excursion
        (let (pos)
          (while (setq pos (text-property-any (point-min) (point-max) 'fontified nil))
            (let ((inhibit-modification-hooks t)
                  (inhibit-redisplay t))
              (when pm-verbose
                (message "after change fontification-functions (%s)" pos))
              (run-hook-with-args 'fontification-functions pos))))))))

(defmacro pm-test-poly-lock (mode file &rest change-sets)
  "Test font-lock and indentation for MODE and FILE.
CHANGE-SETS is a collection of forms of the form (NAME-LOC &rest
BODY). NAME-LOC is a list of the form (NAME LOCK) where NAME is a
symbol, LOC is the location as in `pm-test-goto-loc'. Before and
after execution of the BODY undo-boundary is set and after the
execution undo is called once. After each change-set
`pm-test-chunks' on the whole file is run."
  (declare (indent 2)
           (debug (sexp sexp &rest ((name sexp) &rest form))))
  `(kill-buffer
    (pm-test-run-on-file ,mode ,file
      (pm-test-chunks)
      (dolist (cset ',change-sets)
        (let ((pm-test-current-change-set (caar cset)))
          (setq pm-extra-span-info (caar cset))
          (undo-boundary)
          (pm-test-goto-loc (nth 1 (car cset)))
          (eval (cons 'progn (cdr cset)))
          (undo-boundary)
          (pm-test-chunks)
          (let ((inhibit-message (not pm-verbose)))
            (undo)))))))

;; `(let ((poly-lock-allow-background-adjustment nil)
;;        (file (expand-file-name ,file pm-test-input-dir))
;;        (buf "*pm-test-buffer*"))
;;    (when (get-buffer buf)
;;      (kill-buffer buf))
;;    (setq pm-extra-span-info nil)
;;    (with-current-buffer (get-buffer-create buf)
;;      (when pm-verbose
;;        (message "\n===================  testing %s =======================" file))
;;      (switch-to-buffer buf)
;;      (insert-file-contents file)
;;      (let ((inhibit-message t))
;;        (funcall-interactively ',mode))

;;      )
;;    (setq pm-extra-span-info nil)
;;    ;; if everything is fine kill the buffer
;;    (kill-buffer buf)))


;; (defun tt ()
;;   (interactive)
;;   (let ((oul (with-current-buffer (pm-base-buffer)
;;                buffer-undo-list)))
;;     (list (eq oul buffer-undo-list)
;;           (cons (pm-base-buffer) (length oul))
;;           (cons (current-buffer) (length buffer-undo-list)))))

(provide 'polymode-test)