-- 成员 C：考试管理、教室管理。MySQL >= 8.0.16。
-- 依赖 A 的 01_base_ddl.sql、02_course_ddl.sql；不修改 A/B/D/E 的表、函数、触发器。
-- 正式写入接口为 sp_er_* 事务过程；不在调用方已有事务中调用（过程自行提交/回滚）。
SET NAMES utf8mb4;
USE edu_system;

CREATE TABLE IF NOT EXISTS er_term_lock (
  term_id VARCHAR(16) NOT NULL COMMENT 'C 模块同学期写入串行化锁',
  PRIMARY KEY (term_id),
  CONSTRAINT fk_er_lock_term FOREIGN KEY (term_id) REFERENCES term(term_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS exam (
  exam_id VARCHAR(16) NOT NULL COMMENT '考试编号',
  offering_id VARCHAR(16) NOT NULL COMMENT '教学班；本课设每班一次正考',
  term_id VARCHAR(16) NOT NULL COMMENT '必须与教学班学期一致',
  classroom_id VARCHAR(16) NOT NULL,
  invigilator_id VARCHAR(16) NOT NULL COMMENT '本场监考教师；不要求是任课教师',
  exam_week TINYINT UNSIGNED NOT NULL COMMENT '考试为单次事件，映射起止周相等、全周',
  day_of_week TINYINT UNSIGNED NOT NULL,
  start_section TINYINT UNSIGNED NOT NULL,
  end_section TINYINT UNSIGNED NOT NULL,
  seat_limit SMALLINT UNSIGNED NOT NULL COMMENT '本场可用考位，不超过教室容量',
  require_multimedia TINYINT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (exam_id),
  UNIQUE KEY uk_er_exam_offering (offering_id),
  KEY idx_er_exam_room (term_id, classroom_id, exam_week, day_of_week),
  KEY idx_er_exam_invigilator (term_id, invigilator_id, exam_week, day_of_week),
  CONSTRAINT ck_er_exam_week CHECK (exam_week BETWEEN 1 AND 30),
  CONSTRAINT ck_er_exam_day CHECK (day_of_week BETWEEN 1 AND 7),
  CONSTRAINT ck_er_exam_section CHECK (start_section BETWEEN 1 AND 12 AND end_section BETWEEN start_section AND 12),
  CONSTRAINT ck_er_exam_seat CHECK (seat_limit BETWEEN 1 AND 500),
  CONSTRAINT ck_er_exam_mm CHECK (require_multimedia IN (0,1)),
  CONSTRAINT fk_er_exam_offering FOREIGN KEY (offering_id) REFERENCES course_offering(offering_id),
  CONSTRAINT fk_er_exam_term FOREIGN KEY (term_id) REFERENCES term(term_id),
  CONSTRAINT fk_er_exam_room FOREIGN KEY (classroom_id) REFERENCES classroom(classroom_id),
  CONSTRAINT fk_er_exam_invigilator FOREIGN KEY (invigilator_id) REFERENCES teacher(teacher_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教学班正考安排';

CREATE TABLE IF NOT EXISTS room_booking (
  booking_id VARCHAR(16) NOT NULL,
  applicant_student_id VARCHAR(16) NULL,
  applicant_teacher_id VARCHAR(16) NULL,
  term_id VARCHAR(16) NOT NULL,
  classroom_id VARCHAR(16) NOT NULL,
  start_week TINYINT UNSIGNED NOT NULL,
  end_week TINYINT UNSIGNED NOT NULL,
  week_type ENUM('全','单','双') NOT NULL DEFAULT '全',
  day_of_week TINYINT UNSIGNED NOT NULL,
  start_section TINYINT UNSIGNED NOT NULL,
  end_section TINYINT UNSIGNED NOT NULL,
  headcount SMALLINT UNSIGNED NOT NULL,
  require_multimedia TINYINT NOT NULL DEFAULT 0,
  purpose VARCHAR(255) NOT NULL,
  approval_status ENUM('待审核','已通过','已驳回','已取消') NOT NULL DEFAULT '待审核',
  apply_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewer VARCHAR(32) NULL COMMENT '教务员标识，由 A 的身份层核验；无账号表依赖',
  review_time DATETIME NULL,
  review_comment VARCHAR(255) NULL,
  cancelled_by VARCHAR(32) NULL,
  cancel_time DATETIME NULL,
  cancel_reason VARCHAR(255) NULL,
  PRIMARY KEY (booking_id),
  KEY idx_er_booking_room (term_id, classroom_id, approval_status, day_of_week),
  KEY idx_er_booking_student (applicant_student_id, approval_status),
  KEY idx_er_booking_teacher (applicant_teacher_id, approval_status),
  CONSTRAINT ck_er_booking_applicant CHECK ((applicant_student_id IS NOT NULL) + (applicant_teacher_id IS NOT NULL) = 1),
  CONSTRAINT ck_er_booking_week CHECK (start_week BETWEEN 1 AND 30 AND end_week BETWEEN start_week AND 30),
  CONSTRAINT ck_er_booking_day CHECK (day_of_week BETWEEN 1 AND 7),
  CONSTRAINT ck_er_booking_section CHECK (start_section BETWEEN 1 AND 12 AND end_section BETWEEN start_section AND 12),
  CONSTRAINT ck_er_booking_count CHECK (headcount BETWEEN 1 AND 500),
  CONSTRAINT ck_er_booking_mm CHECK (require_multimedia IN (0,1)),
  CONSTRAINT ck_er_booking_purpose CHECK (CHAR_LENGTH(TRIM(purpose)) > 0),
  CONSTRAINT ck_er_booking_review CHECK (
    (approval_status = '待审核' AND reviewer IS NULL AND review_time IS NULL AND review_comment IS NULL)
    OR (approval_status IN ('已通过','已驳回') AND reviewer IS NOT NULL AND CHAR_LENGTH(TRIM(reviewer)) > 0
        AND review_time IS NOT NULL AND review_comment IS NOT NULL AND CHAR_LENGTH(TRIM(review_comment)) > 0)
    OR approval_status = '已取消'),
  CONSTRAINT ck_er_booking_cancel CHECK (
    (approval_status = '已取消' AND cancelled_by IS NOT NULL AND CHAR_LENGTH(TRIM(cancelled_by)) > 0
       AND cancel_time IS NOT NULL AND cancel_reason IS NOT NULL AND CHAR_LENGTH(TRIM(cancel_reason)) > 0)
    OR (approval_status <> '已取消' AND cancelled_by IS NULL AND cancel_time IS NULL AND cancel_reason IS NULL)),
  CONSTRAINT fk_er_booking_student FOREIGN KEY (applicant_student_id) REFERENCES student(student_id),
  CONSTRAINT fk_er_booking_teacher FOREIGN KEY (applicant_teacher_id) REFERENCES teacher(teacher_id),
  CONSTRAINT fk_er_booking_term FOREIGN KEY (term_id) REFERENCES term(term_id),
  CONSTRAINT fk_er_booking_room FOREIGN KEY (classroom_id) REFERENCES classroom(classroom_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教室借用与审批留痕';

CREATE TABLE IF NOT EXISTS exam_deferral (
  deferral_id VARCHAR(16) NOT NULL,
  exam_id VARCHAR(16) NOT NULL,
  enrollment_id BIGINT UNSIGNED NOT NULL COMMENT '关联真实选课记录，避免任意学生申请',
  reason VARCHAR(255) NOT NULL,
  approval_status ENUM('待审核','已通过','已驳回') NOT NULL DEFAULT '待审核',
  apply_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewer VARCHAR(32) NULL,
  review_time DATETIME NULL,
  review_comment VARCHAR(255) NULL,
  PRIMARY KEY (deferral_id),
  UNIQUE KEY uk_er_deferral_exam_enrollment (exam_id, enrollment_id),
  KEY idx_er_deferral_enrollment (enrollment_id),
  KEY idx_er_deferral_status (approval_status, exam_id),
  CONSTRAINT ck_er_deferral_reason CHECK (CHAR_LENGTH(TRIM(reason)) > 0),
  CONSTRAINT ck_er_deferral_review CHECK (
    (approval_status = '待审核' AND reviewer IS NULL AND review_time IS NULL AND review_comment IS NULL)
    OR (approval_status IN ('已通过','已驳回') AND reviewer IS NOT NULL AND CHAR_LENGTH(TRIM(reviewer)) > 0
        AND review_time IS NOT NULL AND review_comment IS NOT NULL AND CHAR_LENGTH(TRIM(review_comment)) > 0)),
  CONSTRAINT fk_er_deferral_exam FOREIGN KEY (exam_id) REFERENCES exam(exam_id),
  CONSTRAINT fk_er_deferral_enrollment FOREIGN KEY (enrollment_id) REFERENCES enrollment(enrollment_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='缓考申请与单次审批记录';

-- 单一占用口径：待审、驳回、取消借用均不占用；A 的调课已落入当前正常排课。
CREATE OR REPLACE VIEW v_er_room_occupancy AS
SELECT CONCAT('CS:',schedule_id) AS source_id, '课程' AS occupancy_kind,
       term_id, classroom_id, start_week, end_week, week_type, day_of_week, start_section, end_section
FROM course_schedule WHERE schedule_status = '正常'
UNION ALL
SELECT CONCAT('EX:',exam_id), '考试', term_id, classroom_id,
       exam_week, exam_week, '全', day_of_week, start_section, end_section FROM exam
UNION ALL
SELECT CONCAT('BK:',booking_id), '借用', term_id, classroom_id,
       start_week, end_week, week_type, day_of_week, start_section, end_section
FROM room_booking WHERE approval_status = '已通过';

CREATE OR REPLACE VIEW v_er_exam_roster AS
SELECT x.exam_id, x.term_id, x.offering_id, e.enrollment_id, s.student_id, s.student_name,
       s.admin_class_id,
       CASE WHEN d.approval_status = '已通过' THEN '缓考' ELSE '应考' END AS attendance_status,
       COALESCE(d.approval_status, '未申请') AS deferral_status,
       CASE WHEN d.approval_status = '已通过' THEN NULL ELSE
         SUM(CASE WHEN d.approval_status = '已通过' THEN 0 ELSE 1 END)
         OVER (PARTITION BY x.exam_id ORDER BY s.student_id ROWS UNBOUNDED PRECEDING)
       END AS seat_no
FROM exam x JOIN enrollment e ON e.offering_id = x.offering_id AND e.status = '已选'
JOIN student s ON s.student_id = e.student_id
LEFT JOIN exam_deferral d ON d.exam_id = x.exam_id AND d.enrollment_id = e.enrollment_id;

CREATE OR REPLACE VIEW v_er_student_exam AS
SELECT r.student_id, r.student_name, x.exam_id, x.term_id, x.offering_id, c.course_name,
       x.exam_week, x.day_of_week, x.start_section, x.end_section,
       x.classroom_id, cr.building, cr.room_no, r.attendance_status, r.deferral_status, r.seat_no
FROM v_er_exam_roster r JOIN exam x ON x.exam_id = r.exam_id
JOIN course_offering o ON o.offering_id = x.offering_id
JOIN course c ON c.course_id = o.course_id JOIN classroom cr ON cr.classroom_id = x.classroom_id;

-- UNION 去重防止合讲教师兼任监考时同一场出现两行；保留两个角色标志。
CREATE OR REPLACE VIEW v_er_teacher_exam AS
SELECT t.teacher_id, t.teacher_name, x.exam_id, x.term_id, x.offering_id, c.course_name,
       x.exam_week, x.day_of_week, x.start_section, x.end_section, x.classroom_id,
       (x.invigilator_id = t.teacher_id) AS is_invigilator,
       EXISTS(SELECT 1 FROM offering_teacher ot WHERE ot.offering_id=x.offering_id AND ot.teacher_id=t.teacher_id) AS is_instructor
FROM exam x JOIN (
  SELECT exam_id, invigilator_id AS teacher_id FROM exam
  UNION
  SELECT x2.exam_id, ot.teacher_id FROM exam x2 JOIN offering_teacher ot ON ot.offering_id=x2.offering_id
) ids ON ids.exam_id=x.exam_id
JOIN teacher t ON t.teacher_id=ids.teacher_id
JOIN course_offering o ON o.offering_id=x.offering_id JOIN course c ON c.course_id=o.course_id;

DELIMITER $$
DROP PROCEDURE IF EXISTS sp_er_lock_term$$
CREATE PROCEDURE sp_er_lock_term(IN p_term VARCHAR(16))
BEGIN
  IF p_term IS NULL OR NOT EXISTS(SELECT 1 FROM term WHERE term_id=p_term) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_TERM: 学期不存在';
  END IF;
  INSERT INTO er_term_lock(term_id) VALUES(p_term) ON DUPLICATE KEY UPDATE term_id=p_term;
END$$

DROP PROCEDURE IF EXISTS sp_er_validate_slot$$
CREATE PROCEDURE sp_er_validate_slot(
  IN p_term VARCHAR(16), IN p_sw INT, IN p_ew INT, IN p_wt VARCHAR(4),
  IN p_day INT, IN p_ss INT, IN p_es INT)
BEGIN
  IF p_sw IS NULL OR p_ew IS NULL OR p_sw < 1 OR p_ew < p_sw
     OR NOT EXISTS(SELECT 1 FROM term WHERE term_id=p_term AND total_weeks>=p_ew)
     OR p_wt IS NULL OR p_wt NOT IN ('全','单','双')
     OR p_day IS NULL OR p_day NOT BETWEEN 1 AND 7
     OR p_ss IS NULL OR p_es IS NULL OR p_ss<1 OR p_es<p_ss OR p_es>12 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_SLOT: 周次、星期或节次不合法/超出学期';
  END IF;
  IF p_sw=p_ew AND ((p_wt='单' AND MOD(p_sw,2)=0) OR (p_wt='双' AND MOD(p_sw,2)=1)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_SLOT_EMPTY: 单双周配置没有实际发生周';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_er_validate_room$$
CREATE PROCEDURE sp_er_validate_room(
  IN p_room VARCHAR(16), IN p_count INT, IN p_mm INT)
BEGIN
  IF p_count IS NULL OR p_count NOT BETWEEN 1 AND 500 OR p_mm IS NULL OR p_mm NOT IN (0,1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_RESOURCE: 人数或多媒体参数不合法';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM classroom WHERE classroom_id=p_room AND status='可用') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_ROOM_UNAVAILABLE: 教室不存在或不可用';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM classroom WHERE classroom_id=p_room AND capacity>=p_count) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_ROOM_CAPACITY: 教室容量不足';
  END IF;
  IF p_mm=1 AND NOT EXISTS(SELECT 1 FROM classroom WHERE classroom_id=p_room AND is_multimedia=1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_ROOM_MULTIMEDIA: 教室不支持多媒体';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_er_check_room_busy$$
CREATE PROCEDURE sp_er_check_room_busy(
  IN p_source VARCHAR(40), IN p_term VARCHAR(16), IN p_room VARCHAR(16),
  IN p_sw INT, IN p_ew INT, IN p_wt VARCHAR(4), IN p_day INT, IN p_ss INT, IN p_es INT)
BEGIN
  IF EXISTS(SELECT 1 FROM v_er_room_occupancy v
    WHERE v.term_id=p_term AND v.classroom_id=p_room AND v.source_id<>p_source
      AND fn_time_overlap(v.start_week,v.end_week,v.week_type,v.day_of_week,v.start_section,v.end_section,
                          p_sw,p_ew,p_wt,p_day,p_ss,p_es)=1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_ROOM_BUSY: 教室与课程、考试或已通过借用冲突';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_er_validate_exam$$
CREATE PROCEDURE sp_er_validate_exam(
  IN p_id VARCHAR(16), IN p_off VARCHAR(16), IN p_term VARCHAR(16), IN p_room VARCHAR(16),
  IN p_teacher VARCHAR(16), IN p_week INT, IN p_day INT, IN p_ss INT, IN p_es INT,
  IN p_seats INT, IN p_mm INT)
BEGIN
  CALL sp_er_validate_slot(p_term,p_week,p_week,'全',p_day,p_ss,p_es);
  IF NOT EXISTS(SELECT 1 FROM course_offering WHERE offering_id=p_off AND term_id=p_term AND status<>'已停开') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_OFFERING_TERM: 教学班不存在、已停开或学期不一致';
  END IF;
  CALL sp_er_validate_room(p_room,p_seats,p_mm);
  IF (SELECT COUNT(*) FROM enrollment WHERE offering_id=p_off AND status='已选')>p_seats THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_EXAM_SEATS: 考位小于实际有效选课人数';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM teacher WHERE teacher_id=p_teacher AND status='在职') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_INVIGILATOR: 监考教师不存在或不在职';
  END IF;
  CALL sp_er_check_room_busy(CONCAT('EX:',p_id),p_term,p_room,p_week,p_week,'全',p_day,p_ss,p_es);
  IF EXISTS(SELECT 1 FROM exam x WHERE x.exam_id<>p_id AND x.term_id=p_term AND x.invigilator_id=p_teacher
    AND fn_time_overlap(x.exam_week,x.exam_week,'全',x.day_of_week,x.start_section,x.end_section,
                        p_week,p_week,'全',p_day,p_ss,p_es)=1)
  OR EXISTS(SELECT 1 FROM course_schedule cs WHERE cs.term_id=p_term AND cs.teacher_id=p_teacher AND cs.schedule_status='正常'
    AND fn_time_overlap(cs.start_week,cs.end_week,cs.week_type,cs.day_of_week,cs.start_section,cs.end_section,
                        p_week,p_week,'全',p_day,p_ss,p_es)=1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_TEACHER_BUSY: 监考教师与已有监考或授课冲突';
  END IF;
  -- 按真实选课交集检查学生，不以行政班近似，包含跨班选修。
  IF EXISTS(SELECT 1 FROM enrollment n JOIN enrollment e ON e.student_id=n.student_id AND e.status='已选'
    JOIN exam x ON x.offering_id=e.offering_id
    WHERE n.offering_id=p_off AND n.status='已选' AND x.exam_id<>p_id AND x.term_id=p_term
    AND fn_time_overlap(x.exam_week,x.exam_week,'全',x.day_of_week,x.start_section,x.end_section,
                        p_week,p_week,'全',p_day,p_ss,p_es)=1)
  OR EXISTS(SELECT 1 FROM enrollment n JOIN enrollment e ON e.student_id=n.student_id AND e.status='已选'
    JOIN course_schedule cs ON cs.offering_id=e.offering_id AND cs.schedule_status='正常'
    WHERE n.offering_id=p_off AND n.status='已选' AND cs.term_id=p_term
    AND fn_time_overlap(cs.start_week,cs.end_week,cs.week_type,cs.day_of_week,cs.start_section,cs.end_section,
                        p_week,p_week,'全',p_day,p_ss,p_es)=1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_STUDENT_BUSY: 选课学生与已有考试或课程冲突';
  END IF;
END$$

DROP TRIGGER IF EXISTS trg_er_exam_bi$$
CREATE TRIGGER trg_er_exam_bi BEFORE INSERT ON exam FOR EACH ROW
BEGIN
  CALL sp_er_validate_exam(NEW.exam_id,NEW.offering_id,NEW.term_id,NEW.classroom_id,NEW.invigilator_id,
    NEW.exam_week,NEW.day_of_week,NEW.start_section,NEW.end_section,NEW.seat_limit,NEW.require_multimedia);
END$$
DROP TRIGGER IF EXISTS trg_er_exam_bu$$
CREATE TRIGGER trg_er_exam_bu BEFORE UPDATE ON exam FOR EACH ROW
BEGIN
  IF NOT (NEW.exam_id<=>OLD.exam_id) OR NOT (NEW.offering_id<=>OLD.offering_id) OR NOT (NEW.term_id<=>OLD.term_id)
    OR NOT (NEW.created_at<=>OLD.created_at) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_EXAM_IMMUTABLE: 不可修改考试归属与创建时间';
  END IF;
  CALL sp_er_validate_exam(NEW.exam_id,NEW.offering_id,NEW.term_id,NEW.classroom_id,NEW.invigilator_id,
    NEW.exam_week,NEW.day_of_week,NEW.start_section,NEW.end_section,NEW.seat_limit,NEW.require_multimedia);
END$$

DROP PROCEDURE IF EXISTS sp_er_validate_booking$$
CREATE PROCEDURE sp_er_validate_booking(
  IN p_student VARCHAR(16), IN p_teacher VARCHAR(16), IN p_term VARCHAR(16), IN p_room VARCHAR(16),
  IN p_sw INT, IN p_ew INT, IN p_wt VARCHAR(4), IN p_day INT, IN p_ss INT, IN p_es INT, IN p_count INT, IN p_mm INT)
BEGIN
  IF (p_student IS NOT NULL)+(p_teacher IS NOT NULL)<>1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_APPLICANT: 必须且只能指定学生或教师申请人';
  END IF;
  IF p_student IS NOT NULL AND NOT EXISTS(SELECT 1 FROM student WHERE student_id=p_student AND enrollment_status IN ('在读','复学','留级')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_APPLICANT: 学生不存在或学籍状态不可申请';
  END IF;
  IF p_teacher IS NOT NULL AND NOT EXISTS(SELECT 1 FROM teacher WHERE teacher_id=p_teacher AND status='在职') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_APPLICANT: 教师不存在或不在职';
  END IF;
  CALL sp_er_validate_slot(p_term,p_sw,p_ew,p_wt,p_day,p_ss,p_es);
  CALL sp_er_validate_room(p_room,p_count,p_mm);
END$$

DROP TRIGGER IF EXISTS trg_er_booking_bi$$
CREATE TRIGGER trg_er_booking_bi BEFORE INSERT ON room_booking FOR EACH ROW
BEGIN
  IF NEW.approval_status<>'待审核' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_INITIAL_STATUS: 借用申请必须从待审核开始';
  END IF;
  CALL sp_er_validate_booking(NEW.applicant_student_id,NEW.applicant_teacher_id,NEW.term_id,NEW.classroom_id,
    NEW.start_week,NEW.end_week,NEW.week_type,NEW.day_of_week,NEW.start_section,NEW.end_section,NEW.headcount,NEW.require_multimedia);
END$$
DROP TRIGGER IF EXISTS trg_er_booking_bu$$
CREATE TRIGGER trg_er_booking_bu BEFORE UPDATE ON room_booking FOR EACH ROW
BEGIN
  IF NOT (NEW.booking_id<=>OLD.booking_id) OR NOT (NEW.applicant_student_id<=>OLD.applicant_student_id)
     OR NOT (NEW.applicant_teacher_id<=>OLD.applicant_teacher_id) OR NOT (NEW.term_id<=>OLD.term_id)
     OR NOT (NEW.classroom_id<=>OLD.classroom_id) OR NEW.start_week<>OLD.start_week OR NEW.end_week<>OLD.end_week
     OR NEW.week_type<>OLD.week_type OR NEW.day_of_week<>OLD.day_of_week
     OR NEW.start_section<>OLD.start_section OR NEW.end_section<>OLD.end_section
     OR NEW.headcount<>OLD.headcount OR NEW.require_multimedia<>OLD.require_multimedia
     OR NOT (NEW.purpose<=>OLD.purpose) OR NOT (NEW.apply_time<=>OLD.apply_time) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_BOOKING_IMMUTABLE: 申请内容不可覆盖，请取消后重新申请';
  END IF;
  IF NOT ((OLD.approval_status='待审核' AND NEW.approval_status IN ('已通过','已驳回','已取消'))
       OR (OLD.approval_status='已通过' AND NEW.approval_status='已取消')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_BOOKING_STATE: 禁止重复审批或非法状态回退';
  END IF;
  IF NEW.approval_status='已取消' AND (
     NOT (NEW.reviewer<=>OLD.reviewer) OR NOT (NEW.review_time<=>OLD.review_time)
     OR NOT (NEW.review_comment<=>OLD.review_comment)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_REVIEW_IMMUTABLE: 取消不得覆盖原审批记录';
  END IF;
  IF NEW.approval_status='已通过' THEN
    CALL sp_er_validate_booking(NEW.applicant_student_id,NEW.applicant_teacher_id,NEW.term_id,NEW.classroom_id,
      NEW.start_week,NEW.end_week,NEW.week_type,NEW.day_of_week,NEW.start_section,NEW.end_section,NEW.headcount,NEW.require_multimedia);
    CALL sp_er_check_room_busy(CONCAT('BK:',NEW.booking_id),NEW.term_id,NEW.classroom_id,
      NEW.start_week,NEW.end_week,NEW.week_type,NEW.day_of_week,NEW.start_section,NEW.end_section);
  END IF;
END$$
DROP TRIGGER IF EXISTS trg_er_booking_bd$$
CREATE TRIGGER trg_er_booking_bd BEFORE DELETE ON room_booking FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_HISTORY: 借用记录须保留，请使用取消流程';
END$$

DROP PROCEDURE IF EXISTS sp_er_validate_deferral$$
CREATE PROCEDURE sp_er_validate_deferral(IN p_exam VARCHAR(16), IN p_enrollment BIGINT UNSIGNED)
BEGIN
  IF NOT EXISTS(SELECT 1 FROM exam x JOIN enrollment e ON e.offering_id=x.offering_id
    JOIN student s ON s.student_id=e.student_id
    WHERE x.exam_id=p_exam AND e.enrollment_id=p_enrollment AND e.status='已选'
      AND s.enrollment_status IN ('在读','复学','留级')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DEFERRAL_ENROLLMENT: 必须是本场考试有效选课学生';
  END IF;
END$$
DROP TRIGGER IF EXISTS trg_er_deferral_bi$$
CREATE TRIGGER trg_er_deferral_bi BEFORE INSERT ON exam_deferral FOR EACH ROW
BEGIN
  IF NEW.approval_status<>'待审核' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_INITIAL_STATUS: 缓考申请必须从待审核开始';
  END IF;
  CALL sp_er_validate_deferral(NEW.exam_id,NEW.enrollment_id);
END$$
DROP TRIGGER IF EXISTS trg_er_deferral_bu$$
CREATE TRIGGER trg_er_deferral_bu BEFORE UPDATE ON exam_deferral FOR EACH ROW
BEGIN
  IF NOT (NEW.deferral_id<=>OLD.deferral_id) OR NOT (NEW.exam_id<=>OLD.exam_id)
     OR NOT (NEW.enrollment_id<=>OLD.enrollment_id) OR NOT (NEW.reason<=>OLD.reason)
     OR NOT (NEW.apply_time<=>OLD.apply_time) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DEFERRAL_IMMUTABLE: 不可覆盖申请归属或原因';
  END IF;
  IF OLD.approval_status<>'待审核' OR NEW.approval_status NOT IN ('已通过','已驳回') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DEFERRAL_STATE: 禁止重复审批或状态回退';
  END IF;
  IF NEW.approval_status='已通过' THEN CALL sp_er_validate_deferral(NEW.exam_id,NEW.enrollment_id); END IF;
END$$
DROP TRIGGER IF EXISTS trg_er_deferral_bd$$
CREATE TRIGGER trg_er_deferral_bd BEFORE DELETE ON exam_deferral FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_HISTORY: 缓考审批记录不可删除';
END$$

-- 以下写入过程均先获得同学期锁，再验证、写入；READ COMMITTED 避免等待锁后使用旧快照。
DROP PROCEDURE IF EXISTS sp_er_schedule_exam$$
CREATE PROCEDURE sp_er_schedule_exam(
  IN p_id VARCHAR(16), IN p_off VARCHAR(16), IN p_term VARCHAR(16), IN p_room VARCHAR(16),
  IN p_teacher VARCHAR(16), IN p_week INT, IN p_day INT, IN p_ss INT, IN p_es INT, IN p_seats INT, IN p_mm INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL sp_er_lock_term(p_term);
  INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia)
    VALUES(p_id,p_off,p_term,p_room,p_teacher,p_week,p_day,p_ss,p_es,p_seats,p_mm);
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_reschedule_exam$$
CREATE PROCEDURE sp_er_reschedule_exam(
  IN p_id VARCHAR(16), IN p_room VARCHAR(16), IN p_teacher VARCHAR(16),
  IN p_week INT, IN p_day INT, IN p_ss INT, IN p_es INT, IN p_seats INT, IN p_mm INT)
BEGIN
  DECLARE v_term VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SET v_term=(SELECT term_id FROM exam WHERE exam_id=p_id);
  IF v_term IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_NOT_FOUND: 考试不存在'; END IF;
  CALL sp_er_lock_term(v_term);
  UPDATE exam SET classroom_id=p_room,invigilator_id=p_teacher,exam_week=p_week,day_of_week=p_day,
    start_section=p_ss,end_section=p_es,seat_limit=p_seats,require_multimedia=p_mm WHERE exam_id=p_id;
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_apply_booking$$
CREATE PROCEDURE sp_er_apply_booking(
  IN p_id VARCHAR(16), IN p_student VARCHAR(16), IN p_teacher VARCHAR(16), IN p_term VARCHAR(16), IN p_room VARCHAR(16),
  IN p_sw INT, IN p_ew INT, IN p_wt VARCHAR(4), IN p_day INT, IN p_ss INT, IN p_es INT,
  IN p_count INT, IN p_mm INT, IN p_purpose VARCHAR(255))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  CALL sp_er_lock_term(p_term);
  INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,
    start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose)
  VALUES(p_id,p_student,p_teacher,p_term,p_room,p_sw,p_ew,p_wt,p_day,p_ss,p_es,p_count,p_mm,p_purpose);
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_review_booking$$
CREATE PROCEDURE sp_er_review_booking(IN p_id VARCHAR(16),IN p_decision VARCHAR(8),IN p_reviewer VARCHAR(32),IN p_comment VARCHAR(255))
BEGIN
  DECLARE v_term VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  IF p_decision IS NULL OR p_decision NOT IN ('已通过','已驳回') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DECISION: 审批决定只能为已通过或已驳回';
  END IF;
  SET v_term=(SELECT term_id FROM room_booking WHERE booking_id=p_id);
  IF v_term IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_NOT_FOUND: 借用申请不存在'; END IF;
  CALL sp_er_lock_term(v_term);
  UPDATE room_booking SET approval_status=p_decision,reviewer=p_reviewer,review_time=CURRENT_TIMESTAMP,review_comment=p_comment WHERE booking_id=p_id;
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_cancel_booking$$
CREATE PROCEDURE sp_er_cancel_booking(IN p_id VARCHAR(16),IN p_actor VARCHAR(32),IN p_reason VARCHAR(255))
BEGIN
  DECLARE v_term VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SET v_term=(SELECT term_id FROM room_booking WHERE booking_id=p_id);
  IF v_term IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_NOT_FOUND: 借用申请不存在'; END IF;
  CALL sp_er_lock_term(v_term);
  UPDATE room_booking SET approval_status='已取消',cancelled_by=p_actor,cancel_time=CURRENT_TIMESTAMP,cancel_reason=p_reason WHERE booking_id=p_id;
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_apply_deferral$$
CREATE PROCEDURE sp_er_apply_deferral(IN p_id VARCHAR(16),IN p_exam VARCHAR(16),IN p_student VARCHAR(16),IN p_reason VARCHAR(255))
BEGIN
  DECLARE v_term VARCHAR(16);
  DECLARE v_enrollment BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SET v_term=(SELECT term_id FROM exam WHERE exam_id=p_exam);
  IF v_term IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_NOT_FOUND: 考试不存在'; END IF;
  CALL sp_er_lock_term(v_term);
  SET v_enrollment=(SELECT e.enrollment_id FROM enrollment e JOIN exam x ON x.offering_id=e.offering_id
    WHERE x.exam_id=p_exam AND e.student_id=p_student AND e.status='已选');
  IF v_enrollment IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DEFERRAL_ENROLLMENT: 必须是本场考试有效选课学生'; END IF;
  INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) VALUES(p_id,p_exam,v_enrollment,p_reason);
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_review_deferral$$
CREATE PROCEDURE sp_er_review_deferral(IN p_id VARCHAR(16),IN p_decision VARCHAR(8),IN p_reviewer VARCHAR(32),IN p_comment VARCHAR(255))
BEGIN
  DECLARE v_term VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  IF p_decision IS NULL OR p_decision NOT IN ('已通过','已驳回') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_DECISION: 审批决定只能为已通过或已驳回';
  END IF;
  SET v_term=(SELECT x.term_id FROM exam_deferral d JOIN exam x ON x.exam_id=d.exam_id WHERE d.deferral_id=p_id);
  IF v_term IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_NOT_FOUND: 缓考申请不存在'; END IF;
  CALL sp_er_lock_term(v_term);
  UPDATE exam_deferral SET approval_status=p_decision,reviewer=p_reviewer,review_time=CURRENT_TIMESTAMP,review_comment=p_comment WHERE deferral_id=p_id;
  COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_er_free_rooms$$
CREATE PROCEDURE sp_er_free_rooms(IN p_term VARCHAR(16),IN p_sw INT,IN p_ew INT,IN p_wt VARCHAR(4),
  IN p_day INT,IN p_ss INT,IN p_es INT,IN p_count INT,IN p_mm INT)
BEGIN
  CALL sp_er_validate_slot(p_term,p_sw,p_ew,p_wt,p_day,p_ss,p_es);
  IF p_count IS NULL OR p_count<1 OR p_mm IS NULL OR p_mm NOT IN (0,1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='ER_RESOURCE: 人数或多媒体参数不合法';
  END IF;
  SELECT cr.classroom_id,cr.building,cr.room_no,cr.capacity,cr.is_multimedia,cr.room_type
  FROM classroom cr WHERE cr.status='可用' AND cr.capacity>=p_count AND (p_mm=0 OR cr.is_multimedia=1)
    AND NOT EXISTS(SELECT 1 FROM v_er_room_occupancy v WHERE v.term_id=p_term AND v.classroom_id=cr.classroom_id
      AND fn_time_overlap(v.start_week,v.end_week,v.week_type,v.day_of_week,v.start_section,v.end_section,
                          p_sw,p_ew,p_wt,p_day,p_ss,p_es)=1)
  ORDER BY cr.capacity,cr.classroom_id;
END$$
DELIMITER ;
