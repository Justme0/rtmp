(in-package :rtmp.message)

(defun list-map-p (list)
  (and (listp list)
       (every (lambda (x) (and (consp x) (stringp (car x)))) list)))

(deftype list-map () '(satisfies list-map-p))

(defparameter *chunk-stream-id* 3)
(defparameter *message-stream-id* 1)

(defun next-chunk-stream-id ()
  (when (> *chunk-stream-id* 65599)
    (setf *chunk-stream-id* 3))
  (prog1 *chunk-stream-id*
    (incf *chunk-stream-id*)))

(defun next-message-stream-id ()
  (when (> *message-stream-id* #xFFFFFF)
    (setf *message-stream-id* 0))
  (prog1 *message-stream-id*
    (incf *message-stream-id*)))

(defconstant +MESSAGE_TYPE_ID_COMMAND_AMF0+ 20)
(defconstant +MESSAGE_TYPE_ID_COMMAND_AMF3+ 17)

;;;; message
(defstruct message-base
  (type-id   0 :type (unsigned-byte 8))
  (stream-id 0 :type (unsigned-byte 32))
  (timestamp 0 :type (unsigned-byte 32)))

;;;; command
(defconstant +CONNECT_TRANSACIONT_ID+ 1)

(defstruct (command-base (:include message-base))
  (name           t :type string)
  (transaction-id t :type number))

;; TODO: 仕様 or 実装 を探す
(defstruct (on-bandwidth-done (:include command-base))
  field1 ; XXX:
  )

(defun on-bandwidth-done (transaction-id &key (field1 :null)
                                              (timestamp (get-internal-real-time))
                                              (stream-id (next-message-stream-id))
                                              (amf-version 0))
  (declare ((member 0 3) amf-version))
  (assert (= amf-version 0) () "unsupported AMF version: ~a" amf-version)

  (make-on-bandwidth-done :type-id +MESSAGE_TYPE_ID_COMMAND_AMF0+
                          :stream-id stream-id
                          :timestamp timestamp
                          :name "onbwdone"
                          :transaction-id transaction-id
                          :field1 field1))

(defmethod show ((m on-bandwidth-done))
  (with-slots (type-id stream-id timestamp name transaction-id) m
    (let ((*print-pretty* nil))
      (format nil "(~s \"~d:~d:~d\" ~d)"
              name type-id stream-id timestamp transaction-id ))))

(defmethod write-command (out (m on-bandwidth-done))
  (with-slots (field1) m
    (rtmp.amf0:encode field1 out)))

(defun parse-command-on-bandwidth-done (in transaction-id stream-id timestamp)
  (let ((obj (rtmp.amf0:decode in)))
    (on-bandwidth-done transaction-id 
                       :stream-id stream-id
                       :timestamp timestamp
                       :field1 obj)))

(defstruct (_result (:include command-base))
  (properties  t :type list-map)
  (information t :type list-map))

(defun _result (transaction-id properties information 
                &key (timestamp (get-internal-real-time))
                     (stream-id (next-message-stream-id))
                     (amf-version 0))
  (declare ((member 0 3) amf-version))
  (assert (= amf-version 0) () "unsupported AMF version: ~a" amf-version)

  (make-_result :type-id +MESSAGE_TYPE_ID_COMMAND_AMF0+
                :stream-id stream-id
                :timestamp timestamp
                :name "_result"
                :transaction-id transaction-id
                :properties properties
                :information information))

(defmethod show ((m _result))
  (with-slots (type-id stream-id timestamp name transaction-id properties information) m
    (let ((*print-pretty* nil))
      (format nil "(~s \"~d:~d:~d\" ~d (:PROPS ~s) (:INFO ~s))" 
              name type-id stream-id timestamp 
              transaction-id properties information))))

(defmethod write-command (out (m _result))
  (with-slots (properties information) m
    (rtmp.amf0:encode `(:map ,properties) out)
    (rtmp.amf0:encode `(:map ,information) out)))

(defun parse-command-_result (in transaction-id stream-id timestamp)
  (let ((properties (rtmp.amf0:decode in))
        (information (rtmp.amf0:decode in)))
    (declare (rtmp.amf0:object-type properties information))

    (_result transaction-id (second properties) (second information)
             :stream-id stream-id
             :timestamp timestamp)))

(defstruct (connect (:include command-base))
  (command-object t :type list-map)
  (optional-args  t :type list-map))

(defun connect (command-object &key (timestamp (get-internal-real-time))
                                    (stream-id (next-message-stream-id))
                                    optional-args 
                                    (amf-version 0))
  (declare ((member 0 3) amf-version))
  (assert (= amf-version 0) () "unsupported AMF version: ~a" amf-version)

  (make-connect :type-id +MESSAGE_TYPE_ID_COMMAND_AMF0+
                :stream-id stream-id
                :timestamp timestamp
                :name "connect"
                :transaction-id +CONNECT_TRANSACIONT_ID+
                :command-object command-object
                :optional-args  optional-args))

(defmethod show ((m connect))
  (with-slots (type-id stream-id timestamp name transaction-id command-object optional-args) m
    (let ((*print-pretty* nil))
      (format nil "(~s \"~d:~d:~d\" ~d (:PARAMS ~s) (:OPTS ~s))" 
              name type-id stream-id timestamp 
              transaction-id command-object optional-args))))

(defmacro write-impl ((out message &key chunk-size chunk-stream-id) &body body)
  (let ((m (gensym)))
    `(let ((,m ,message))
       (declare ((integer 2 65599) ,chunk-stream-id))
       (show-log "write message# ~a" (show ,m))

       (let ((payload (with-output-to-bytes (,out)
                        ,@body)))
         (with-slots (type-id timestamp stream-id) ,m
           ;; TODO: chunkはchunk-streamっぽいものを使って、使いまわすようにする (fmt0の数が減る)
           (write-chunks ,out ,chunk-size ,chunk-stream-id type-id stream-id timestamp payload))))))

(defmethod write-command (out (m connect))
  (with-slots (command-object optional-args) m
    (rtmp.amf0:encode `(:map ,command-object) out)
    (when optional-args
      (rtmp.amf0:encode `(:map ,optional-args) out))))
     
(defmethod write (out (m command-base) &key (chunk-size +DEFAULT_CHUNK_SIZE+)
                                            (chunk-stream-id (next-chunk-stream-id)))
  (write-impl (out m :chunk-size chunk-size
                     :chunk-stream-id chunk-stream-id)
    (with-slots (name transaction-id) m
      (rtmp.amf0:encode name out) ; TODO: amf3にも対応
      (rtmp.amf0:encode transaction-id out)
      (write-command out m))))

(defun parse-command-connect (in transaction-id stream-id timestamp)
  (declare (ignore transaction-id))
  (let ((command-object (rtmp.amf0:decode in))
        (optional-args  (when (listen in) (rtmp.amf0:decode in))))
    (declare (rtmp.amf0:object-type command-object optional-args))

    (connect (second command-object )
             :stream-id stream-id
             :timestamp timestamp
             :optional-args (second optional-args))))

(defun parse-command (payload stream-id timestamp amf-version)
  (declare (ignore amf-version))

  (with-input-from-bytes (in payload)
    (let* ((command-name   (rtmp.amf0:decode in))
           (transaction-id (rtmp.amf0:decode in))
           (command (intern (string-upcase command-name) :keyword))) ; XXX: gc
      (ecase command
        (:connect (parse-command-connect in transaction-id stream-id timestamp))
        (:_result (parse-command-_result in transaction-id stream-id timestamp))
        (:onbwdone (parse-command-on-bandwidth-done in transaction-id stream-id timestamp))
        ))))

;;; user control
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +MESSAGE_TYPE_ID_UCM+ 4)
  
  (defconstant +UCM_EVENT_STREAM_BEGIN+ 0)
  )

(defstruct (user-control-base (:include message-base))
  (event-type 0 :type (unsigned-byte 16)))

(defstruct (stream-begin (:include user-control-base))
  (target-stream-id 0 :type (unsigned-byte 32)))

(defun stream-begin (target-stream-id &key (timestamp (get-internal-real-time)))
  (make-stream-begin :type-id +MESSAGE_TYPE_ID_UCM+
                     :stream-id +MESSAGE_STREAM_ID_PCM+
                     :event-type +UCM_EVENT_STREAM_BEGIN+
                     :timestamp timestamp
                     :target-stream-id target-stream-id))

(defmethod show ((m stream-begin))
  (with-slots (type-id event-type target-stream-id) m
    (format nil "(~s \"~d:~d\" stream-id=~d)" "stream-begin" type-id event-type target-stream-id))) 

(defmethod write (out (m user-control-base) &key (chunk-size +DEFAULT_CHUNK_SIZE+)
                                                 (chunk-stream-id +CHUNK_STREAM_ID_PCM+))
  (write-impl (out m :chunk-size chunk-size :chunk-stream-id chunk-stream-id)
    (with-slots (event-type target-stream-id) m
      (write-uint 2 event-type out)
      (write-ucm out m))))

(defmethod write-ucm (out (m stream-begin))
  (write-uint 4 (stream-begin-target-stream-id m) out))

(defun parse-stream-begin (payload timestamp)
  (let ((target-stream-id (read-uint-from-bytes 4 payload :start 2)))
    (stream-begin target-stream-id :timestamp timestamp)))

(defun parse-user-control (payload stream-id timestamp)
  (declare (ignore stream-id))
  (let ((event-type (read-uint-from-bytes 2 payload)))
    (ecase event-type
      (#. +UCM_EVENT_STREAM_BEGIN+ (parse-stream-begin payload timestamp))
      )))

;;; program control
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +MESSAGE_TYPE_ID_SET_CHUNK_SIZE+ 1)
  (defconstant +MESSAGE_TYPE_ID_ACK_WINDOW_SIZE+ 5)
  (defconstant +MESSAGE_TYPE_ID_SET_PEER_BANDWIDTH+ 6)
  )

(defconstant +CHUNK_STREAM_ID_PCM+ 2)
(defconstant +MESSAGE_STREAM_ID_PCM+ 0)

(defstruct (protocol-control-base (:include message-base)))

(defstruct (set-chunk-size (:include protocol-control-base))
  (size 0 :type (unsigned-byte 32)))

(defun set-chunk-size (size &key (timestamp (get-internal-real-time)))
  (make-set-chunk-size :type-id +MESSAGE_TYPE_ID_SET_CHUNK_SIZE+
                       :stream-id +MESSAGE_STREAM_ID_PCM+
                       :timestamp timestamp
                       :size size))

(defmethod write (out (m set-chunk-size)  &key (chunk-size +DEFAULT_CHUNK_SIZE+)
                                               (chunk-stream-id +CHUNK_STREAM_ID_PCM+))
  (write-impl (out m :chunk-size chunk-size
                     :chunk-stream-id chunk-stream-id)
    (write-uint 4 (set-chunk-size-size m) out)))

(defun parse-set-chunk-size (payload stream-id timestamp)
  (declare (ignore stream-id))
  (let ((size (read-uint-from-bytes 4 payload)))
    (set-chunk-size size :timestamp timestamp)))

(defmethod show ((m set-chunk-size))
  (with-slots (type-id size) m
    (format nil "(~s \"~d\" size=~d)" "set-chunk-size" type-id size)))
  
(defstruct (ack-win-size (:include protocol-control-base))
  (size 0 :type (unsigned-byte 32)))

(defun ack-win-size (size &key (timestamp (get-internal-real-time)))
  (make-ack-win-size :type-id +MESSAGE_TYPE_ID_ACK_WINDOW_SIZE+
                     :stream-id +MESSAGE_STREAM_ID_PCM+
                     :timestamp timestamp
                     :size size))

(defmethod show ((m ack-win-size))
  (with-slots (type-id size) m
    (format nil "(~s \"~d\" size=~d)" "ack-win-size" type-id size)))

(defmethod write (out (m ack-win-size)  &key (chunk-size +DEFAULT_CHUNK_SIZE+)
                                             (chunk-stream-id +CHUNK_STREAM_ID_PCM+))
  (write-impl (out m :chunk-size chunk-size
                     :chunk-stream-id chunk-stream-id)
    (write-uint 4 (ack-win-size-size m) out)))

(defun parse-ack-win-size (payload stream-id timestamp)
  (declare (ignore stream-id))
  (let ((size (read-uint-from-bytes 4 payload)))
    (ack-win-size size :timestamp timestamp)))

(defstruct (set-peer-bandwidth (:include protocol-control-base))
  (size       0 :type (unsigned-byte 32))
  (limit-type 0 :type (unsigned-byte 8)))

(defun set-peer-bandwidth (ack-win-size limit-type &key (timestamp (get-internal-real-time)))
  (make-set-peer-bandwidth :type-id +MESSAGE_TYPE_ID_SET_PEER_BANDWIDTH+
                           :stream-id +MESSAGE_STREAM_ID_PCM+
                           :timestamp timestamp
                           :size ack-win-size
                           :limit-type limit-type))

(defmethod show ((m set-peer-bandwidth))
  (with-slots (type-id size limit-type) m
    (format nil "(~s \"~d\" size=~d limit-type=~d)" "set-peer-bandwidth" type-id size limit-type)))

(defmethod write (out (m set-peer-bandwidth) &key (chunk-size +DEFAULT_CHUNK_SIZE+)
                                                  (chunk-stream-id +CHUNK_STREAM_ID_PCM+))
  (write-impl (out m :chunk-size chunk-size
                     :chunk-stream-id chunk-stream-id)
    (with-slots (size limit-type) m
      (write-uint 4 size out)
      (write-uint 1 limit-type out))))

(defun parse-set-peer-bandwidth (payload stream-id timestamp)
  (declare (ignore stream-id))
  (let ((ack-win-size (read-uint-from-bytes 4 payload))
        (limit-type   (read-uint-from-bytes 1 payload :start 4)))
    (set-peer-bandwidth ack-win-size limit-type :timestamp timestamp)))

;;; other
(defstruct state ; XXX: name ; TODO: chunk-stream-idごとに管理する必要がありそう
  chunk-stream-id
  message-type-id
  message-stream-id
  timestamp
  (timestamp-delta 0)
  chunk-size
  (payload-length 0)
  payload-chunks)
  
(defun state-payload-read-length (state)
  (loop FOR chunk IN (state-payload-chunks state)
        SUM (length chunk)))

(defun make-initial-state (&key (chunk-size +DEFAULT_CHUNK_SIZE+))
  (make-state :chunk-size chunk-size))

(defun change-state-chunk-size (state new-chunk-size)
  (setf (state-chunk-size state) new-chunk-size)
  t)

(defun read-chunk-basic-header (in)
  (let* ((byte1 (read-uint 1 in))
         (fmt                  (ldb (byte 2 6) byte1))
         (base-chunk-stream-id (ldb (byte 6 0) byte1))
         (chunk-stream-id 
          (case base-chunk-stream-id
            (#. +CHUNK_STREAM_ID_INDICATE_2BYTE+ (+ (read-uint 1 in) 64))
            (#. +CHUNK_STREAM_ID_INDICATE_3BYTE+ (+ (read-uint 2 in) 64))
            (otherwise                           base-chunk-stream-id))))
    (values fmt chunk-stream-id)))

(defun read-chunk-message-header-fmt0 (io state)
  (let ((timestamp         (read-uint 3 io))
        (message-length    (read-uint 3 io))
        (message-type-id   (read-uint 1 io))
        (message-stream-id (read-uint 4 io :endian :little)))
    (show-log "msg-header-fmt0# timestamp=~d, length=~d, type-id=~d, stream-id=~d" 
              timestamp message-length message-type-id message-stream-id)
    (setf (state-timestamp state) timestamp
          (state-timestamp-delta state) 0
          (state-payload-length state) message-length
          (state-message-type-id state) message-type-id
          (state-message-stream-id state) message-stream-id))
  (values))

(defun read-chunk-message-header-fmt1 (io state)
  (let ((timestamp-delta (read-uint 3 io))
        (message-length  (read-uint 3 io))
        (message-type-id (read-uint 1 io)))
    (show-log "msg-header-fmt1# timestamp-delta=~d, length=~d, type-id=~d" 
              timestamp-delta message-length message-type-id)
    (setf (state-timestamp-delta state) timestamp-delta
          (state-payload-length state) message-length
          (state-message-type-id state) message-type-id))
  (values))

(defun read-chunk-message-header-fmt2 (io state)
  (let ((timestamp-delta (read-uint 3 io)))
    (show-log "msg-header-fmt2# timestamp-delta=~d" timestamp-delta)
    (setf (state-timestamp-delta state) timestamp-delta))
  (values))

(defun read-chunk-message-header-fmt3 (io state)
  (declare (ignore io state))
  (show-log "msg-header-fmt3#")
  (values))
    
(defun read-chunk-ext-timestamp-if-need (io state)
  (when (= (state-timestamp state) #x00FFFFFF)
    (setf (state-timestamp state) (read-uint 4 io))))

(defun read-chunk (io state)
  (with-log-section ("read-chunk")
    (multiple-value-bind (fmt chunk-stream-id)
                         (read-chunk-basic-header io)
      (show-log "basic-header# fmt=~d, chunk-stream-id=~d" fmt chunk-stream-id)
      (setf (state-chunk-stream-id state) chunk-stream-id)

      (ecase fmt
        (0 (read-chunk-message-header-fmt0 io state)
           (read-chunk-ext-timestamp-if-need io state))
        (1 (read-chunk-message-header-fmt1 io state))
        (2 (read-chunk-message-header-fmt2 io state))
        (3 (read-chunk-message-header-fmt3 io state)))

      (incf (state-timestamp state) (state-timestamp-delta state))

      (let* ((message-payload-length (state-payload-length state))
             (read-payload-length (state-payload-read-length state))
             (chunk-payload-length (min (state-chunk-size state)
                                        (- message-payload-length read-payload-length))))
        (push (read-bytes chunk-payload-length io) (state-payload-chunks state))
        
        (show-log "current message# timestamp=~d, payload-length=~d"
                  (state-timestamp state) (state-payload-read-length state))
        (assert (<= (state-payload-read-length state) message-payload-length) ; XXX: 毎回計算は無駄
                () "TODO: ")
        (= (state-payload-read-length state) message-payload-length)))))
    
(defun read-message-chunks (io state)
  (loop FOR end? = (read-chunk io state)
        UNTIL end?)
  (with-slots (message-type-id timestamp message-stream-id payload-chunks) state
    (let ((payload (apply #'concatenate 'octets (reverse payload-chunks))))
      (setf payload-chunks '())
      (values message-type-id timestamp message-stream-id payload))))

(defun read (io state)
  (with-log-section ("read-message")
    (multiple-value-bind (type timestamp stream-id payload)
                         (read-message-chunks io state)
      (let ((msg 
             (ecase type
               (#. +MESSAGE_TYPE_ID_SET_CHUNK_SIZE+ (parse-set-chunk-size payload stream-id timestamp))
               (#. +MESSAGE_TYPE_ID_ACK_WINDOW_SIZE+ (parse-ack-win-size payload stream-id timestamp))
               (#. +MESSAGE_TYPE_ID_SET_PEER_BANDWIDTH+ (parse-set-peer-bandwidth payload stream-id timestamp))
               (#. +MESSAGE_TYPE_ID_UCM+ (parse-user-control payload stream-id timestamp))
               (#. +MESSAGE_TYPE_ID_COMMAND_AMF0+ (parse-command payload stream-id timestamp 0))
               (#. +MESSAGE_TYPE_ID_COMMAND_AMF3+ (error "unsupported message-type: ~a" type))
               )))
        (show-log "message: ~a" (show msg))
        msg))))
