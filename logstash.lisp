;; -*- lisp -*-

(in-package :a-cl-logger)
(cl-interpol:enable-interpol-syntax)

(defclass node-logstash-appender (stream-log-appender)
  ((log-stash-type :accessor log-stash-type :initarg :log-stash-type :initform nil)
   (log-stash-server
    :accessor log-stash-server :initarg :log-stash-server
    :initform nil))
  (:default-initargs :formatter 'json-formatter))

(defun zeromq-send-data (json &key server &aux connected)
  "Push a message to the logstash zmq"
  (zmq:with-context (ctx 1)
    (zmq:with-socket (socket ctx :push)      
      (unwind-protect
           (progn 
             (setf connected (zerop (zmq:connect socket server)))
             (zmq:with-msg-init-data (msg json) 
               (zmq:msg-send msg socket (list :dontwait))))
        (when connected
          ;; Disconnecting causes all messages to not flow, for some reason
          ;; I believe we will blcok on with-socket to close until all messages
          ;; are sent which this seems to bypass?
          ;; (zmq:disconnect socket server)
          )))))

(defmethod append-message ((appender node-logstash-appender)
                           message)
  (setf message
        (copy-messsage
         message
         :type (princ-to-string
                (or (log-stash-type appender)
                    (name (logger message))))))
  (let ((out (with-output-to-string (json)
               (format-message
                appender
                (formatter appender)
                message
                json))))
    ; (format t "~%SENDING ZMQ MSQ: ~A~%" out)
    (zeromq-send-data out :server (log-stash-server appender))))

(defun ensure-node-logstash-appender (logger
                                      &key log-stash-server log-stash-type
                                      (type 'node-logstash-appender))
  (require-logger! logger)
  (alexandria:when-let
      (a (find-appender
          logger
          :type type
          :predicate (lambda (a) (string-equal (log-stash-server a)
                                          log-stash-server))))
    (return-from ensure-node-logstash-appender a))
  (let ((new (make-instance type
                            :log-stash-type log-stash-type
                            :log-stash-server log-stash-server)))
    (push new (appenders logger))
    new))

(defun only-logstash-appends (c)
  (unless (typep (appender c) 'node-logstash-appender)
    (abort c)))

(defun no-logstash-appends (c)
  (when (typep (appender c) 'node-logstash-appender)
    (abort c)))

(defmacro without-logstashing (() &body body)
  `(handler-bind ((appending-message 'no-logstash-appends))
    ,@body))

(defmacro with-logstashing-only (() &body body)
  `(handler-bind ((appending-message 'only-logstash-appends))
    ,@body))

(defmacro with-concatenated-logstash-logs ((&key (logger *root-logger*)
                                            (level '+info+))
                                           &body body)
  (alexandria:with-unique-names (lg logs rtn)
    `(let ( (,lg ,logger) ,logs  ,rtn )
      (without-logstashing ()
        (with-logged-output-to-place (,lg ,logs)
          (setf ,rtn (multiple-value-list
                      (progn ,@body)))))
      (with-logstashing-only ()
        (do-log ,lg ,level ,logs))
      (apply #'values ,rtn))))

