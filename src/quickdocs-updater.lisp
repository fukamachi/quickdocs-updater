(in-package :cl-user)
(defpackage quickdocs-updater
  (:use :cl
        :quickdocs-database
        :split-sequence
        :sxql)
  (:import-from :quickdocs-updater.extracter
                :release-info)
  (:import-from :quickdocs-updater.release
                :release-repos-url)
  (:import-from :quickdocs-updater.readme 
                :convert-readme)
  (:import-from :quickdocs-updater.cliki
                :cliki-project-info)
  (:import-from :quickdocs-updater.http
                :send-get)
  (:import-from :datafly
                :retrieve-one
                :execute)
  (:export :update-dist
           :update-release))
(in-package :quickdocs-updater)

(defun ql-dist-releases (ql-dist-version)
  (let ((releases.txt
          (send-get (format nil "http://beta.quicklisp.org/dist/quicklisp/~A/releases.txt"
                            ql-dist-version))))
    (loop for line in (split-sequence #\Newline releases.txt)
          when (and (not (= (length line) 0))
                    (not (char= (aref line 0) #\#)))
            collect (first (split-sequence #\Space line :count 1)))))

(defun update-dist (ql-dist-version)
  (check-type ql-dist-version string)
  ;; Update database
  (let ((releases (ql-dist-releases ql-dist-version)))
    ;; Update 'project' and 'system' tables
    (format *error-output* "~&Updating 'project' and 'system'...~%")
    (dolist (release releases)
      (update-release release))

    (flet ((retrieve-system (system-name project-id)
             (retrieve-one
              (select :*
                (from :system)
                (where (:and (:= :name system-name)
                             (:= :project_id project-id)))
                (limit 1))
              :as 'quickdocs-database:system))
           (retrieve-project (project-name)
             (retrieve-one
              (select :*
                (from :project)
                (where (:and (:= :ql_dist_version ql-dist-version)
                             (:= :name project-name)))
                (limit 1))
              :as 'quickdocs-database:project)))

      ;; Update dependencies
      (format *error-output* "~&Updating dependencies...~%")
      (dolist (release releases)
        (let ((project (retrieve-project release)))
          (dolist (system (getf (release-info release) :systems))
            (dolist (depends-system-name (append (getf system :depends-on)
                                                 (getf system :defsystem-depends-on)))
              (let ((system (retrieve-system (getf system :name) (project-id project)))
                    (depends-system (retrieve-system depends-system-name (project-id project))))
                (create-dependency (system-id system) (system-id depends-system)))))))

      ;; Retrieve description and categories from cliki and update DB.
      (format *error-output* "~&Retrieving description and categories from CLiki...~%")
      (dolist (release releases)
        (let ((project (retrieve-project release)))
          (format *error-output* "~&~A...~%" (project-name project))
          (multiple-value-bind (description categories)
              (cliki-project-info (project-name project))
            (execute
             (insert-into :project_cliki_description
               (set= :project_id (project-id project)
                     :description description)))
            (dolist (category categories)
              (execute
               (insert-into :project_category
                 (set= :project_name (project-name project)
                       :category category))))))
        (sleep 3))))
  t)

(defun update-release (release &aux (release-info (release-info release)))
  (check-type release ql-dist:release)
  (let ((project
          (create-project :ql-dist-version (ql-dist:version (ql-dist:dist release))
                          :name (getf release-info :name)
                          :release-version (getf release-info :release-version)
                          :repos-url (release-repos-url release)
                          :archive-url (ql-dist:archive-url release)
                          :project-readme (when (getf release-info :readme-file)
                                            (make-project-readme
                                             :filename (getf release-info :readme-file)
                                             :raw (getf release-info :readme)
                                             :converted (convert-readme (make-string-input-stream (getf release-info :readme))
                                                                        (first
                                                                         (split-sequence #\.
                                                                                         (getf release-info :readme-file)
                                                                                         :from-end t
                                                                                         :count 1))))))))
    (dolist (system-info (getf release-info :systems))
      (let ((system
              (create-system :project-id (project-id project)
                             :name (getf system-info :name)
                             :version (getf system-info :version)
                             :description (getf system-info :description)
                             :long-description (getf system-info :long-description)
                             :license (getf system-info :license)
                             :homepage-url (getf system-info :homepage)
                             :authors (list (getf system-info :author))
                             :maintainers (list (getf system-info :maintainer)))))
        (create-system-packages (system-id system)
                                (getf system-info :packages)
                                :failed (getf system-info :failed)
                                :error-log (getf system-info :error-log))))
    project))
