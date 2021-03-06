(in-package :rtmp.server)

(defun generate-random-bytes (size)
  (let ((bytes (make-array size :element-type 'octet)))
    (dotimes (i size bytes)
      (setf (aref bytes i) (random #x100)))))

(defun recv-c0 (in expected-version)
  (let ((version (read-uint 1 in)))
    (show-log "recv c0# version=~d, expected=~d" version expected-version)
    (assert (= version expected-version) () "unexpected c0 version: ~d" version))
  (values))

(defun recv-c1 (in)
  (let ((timestamp (read-uint 4 in))
        (zero (read-uint 4 in))
        (random-bytes (read-bytes 1528 in)))
    (show-log "recv c1# timestamp=~d, zero=~d" timestamp zero)
    (values timestamp zero random-bytes)))

(defun send-s0/s1 (out version timestamp zero random-bytes)
  (show-log "send s0# version=~d" version)
  (write-uint 1 version out)

  (show-log "send s1# timestamp=~d, zero=~d" timestamp zero)
  (write-uint 4 timestamp out)
  (write-uint 4 zero out)
  (write-bytes random-bytes out)
  (force-output out))

(defun send-s2 (out c1-timestamp s1-timestamp c1-random-bytes)
  (show-log "send s2# timestamp1=~d, timestamp2=~d" c1-timestamp s1-timestamp)
  (write-uint 4 c1-timestamp out)
  (write-uint 4 s1-timestamp out)
  (write-bytes c1-random-bytes out)
  (force-output out))

(defun recv-c2 (in c1-timestamp s1-timestamp s1-random-bytes)
  (declare (ignore c1-timestamp))
  (let ((timestamp1 (read-uint 4 in))
        (timestamp2 (read-uint 4 in))
        (random-bytes (read-bytes 1528 in)))
    (show-log "recv c2# timestamp1=~d, timestamp2=~d" timestamp1 timestamp2)

    (assert (= s1-timestamp timestamp1) ()
            "incorrect C2's timestamp: s1=~a, c2=~a" s1-timestamp timestamp1)
    (assert (not (mismatch s1-random-bytes random-bytes)) ()
            "incorrect C2's random-bytes")
    
    (values)))

(defun handshake (io &key (version +RTMP_VERSION+)
                          (timestamp (get-internal-real-time))
                          (zero 0)
                          (random-bytes (generate-random-bytes 1528)))
  (with-log-section ("handshake")
    (recv-c0 io version)
    (send-s0/s1 io version timestamp zero random-bytes)
    (multiple-value-bind (c1-timestamp c1-zero c1-random-bytes)
                         (recv-c1 io)
      (declare (ignore c1-zero))
      (send-s2 io c1-timestamp timestamp c1-random-bytes)
      (recv-c2 io c1-timestamp timestamp random-bytes))))
