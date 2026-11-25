-- B 成绩管理；依赖 A 的 01_base_ddl + 02_course_ddl；MySQL 8.0/InnoDB
SET NAMES utf8mb4;
USE edu_system;

CREATE TABLE IF NOT EXISTS score (
  score_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  enrollment_id BIGINT UNSIGNED NOT NULL,
  recorded_by_teacher_id VARCHAR(16) NOT NULL,
  score_value DECIMAL(5,2) NULL,
  exam_status ENUM('正常','缓考','缺考') NOT NULL DEFAULT '正常',
  score_status ENUM('草稿','待审核','退回','已发布') NOT NULL DEFAULT '草稿',
  recorded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  submitted_at DATETIME NULL,
  reviewed_by_admin_id VARCHAR(32) NULL,
  review_decision ENUM('通过','退回') NULL,
  review_comment VARCHAR(255) NULL,
  reviewed_at DATETIME NULL,
  published_at DATETIME NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (score_id),
  UNIQUE KEY uk_score_enrollment (enrollment_id),
  KEY idx_score_status (score_status),
  KEY idx_score_teacher (recorded_by_teacher_id),
  CONSTRAINT fk_score_enrollment FOREIGN KEY (enrollment_id) REFERENCES enrollment(enrollment_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_score_teacher FOREIGN KEY (recorded_by_teacher_id) REFERENCES teacher(teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_score_range CHECK (score_value IS NULL OR score_value BETWEEN 0 AND 100),
  CONSTRAINT chk_score_exam CHECK ((exam_status = '正常' AND score_value IS NOT NULL)
    OR (exam_status <> '正常' AND score_value IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='每条有效修读至多一条课程总评成绩';

CREATE TABLE IF NOT EXISTS score_change_request (
  request_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  score_id BIGINT UNSIGNED NOT NULL,
  applicant_teacher_id VARCHAR(16) NOT NULL,
  old_value DECIMAL(5,2) NOT NULL,
  new_value DECIMAL(5,2) NOT NULL,
  reason VARCHAR(255) NOT NULL,
  status ENUM('待审核','已通过','已驳回') NOT NULL DEFAULT '待审核',
  pending_score_id BIGINT UNSIGNED GENERATED ALWAYS AS (IF(status = '待审核', score_id, NULL)) STORED,
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewer VARCHAR(32) NULL,
  reviewed_at DATETIME NULL,
  decision_comment VARCHAR(255) NULL,
  PRIMARY KEY (request_id),
  UNIQUE KEY uk_change_one_pending (pending_score_id),
  KEY idx_change_score (score_id),
  KEY idx_change_teacher (applicant_teacher_id),
  CONSTRAINT fk_change_score FOREIGN KEY (score_id) REFERENCES score(score_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_change_teacher FOREIGN KEY (applicant_teacher_id) REFERENCES teacher(teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_change_values CHECK (old_value BETWEEN 0 AND 100 AND new_value BETWEEN 0 AND 100 AND old_value <> new_value),
  CONSTRAINT chk_change_reason CHECK (CHAR_LENGTH(TRIM(reason)) > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='成绩更正审批及已批准变更历史';

CREATE TABLE IF NOT EXISTS score_recheck_request (
  recheck_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  score_id BIGINT UNSIGNED NOT NULL,
  reason VARCHAR(255) NOT NULL,
  status ENUM('待核查','待确认','待更正','已办结') NOT NULL DEFAULT '待核查',
  open_score_id BIGINT UNSIGNED GENERATED ALWAYS AS (IF(status = '已办结', NULL, score_id)) STORED,
  requested_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  checked_by_teacher_id VARCHAR(16) NULL,
  teacher_opinion VARCHAR(255) NULL,
  teacher_checked_at DATETIME NULL,
  confirmed_by_admin_id VARCHAR(32) NULL,
  admin_opinion VARCHAR(255) NULL,
  admin_confirmed_at DATETIME NULL,
  conclusion VARCHAR(255) NULL,
  change_request_id BIGINT UNSIGNED NULL,
  closed_at DATETIME NULL,
  PRIMARY KEY (recheck_id),
  UNIQUE KEY uk_recheck_one_open (open_score_id),
  KEY idx_recheck_score (score_id),
  KEY idx_recheck_teacher (checked_by_teacher_id),
  KEY idx_recheck_change (change_request_id),
  CONSTRAINT fk_recheck_score FOREIGN KEY (score_id) REFERENCES score(score_id)
    ON UPDATE RESTRICT ON DELETE RESTRICT,
  CONSTRAINT fk_recheck_teacher FOREIGN KEY (checked_by_teacher_id) REFERENCES teacher(teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_recheck_change FOREIGN KEY (change_request_id) REFERENCES score_change_request(request_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_recheck_reason CHECK (CHAR_LENGTH(TRIM(reason)) > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='学生查卷复核申请';

-- 即使绕开录入过程直接 INSERT，也不得为退课或非任课教师建立成绩。
DROP TRIGGER IF EXISTS trg_score_bi;
DROP TRIGGER IF EXISTS trg_score_bu;
DELIMITER $$
CREATE TRIGGER trg_score_bi BEFORE INSERT ON score FOR EACH ROW
BEGIN
  DECLARE v_offering VARCHAR(16);
  DECLARE v_status VARCHAR(8);
  SELECT offering_id,status INTO v_offering,v_status FROM enrollment
    WHERE enrollment_id=NEW.enrollment_id;
  IF v_status IS NULL OR v_status<>'已选' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='成绩写入失败：选课记录无效或已退课';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM offering_teacher
    WHERE offering_id=v_offering AND teacher_id=NEW.recorded_by_teacher_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='成绩写入失败：录入教师不是教学班任课教师';
  END IF;
END$$
CREATE TRIGGER trg_score_bu BEFORE UPDATE ON score FOR EACH ROW
BEGIN
  IF NEW.enrollment_id<>OLD.enrollment_id OR NEW.recorded_by_teacher_id<>OLD.recorded_by_teacher_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='成绩更新失败：修读记录及原录入教师不可更改';
  END IF;
END$$
DELIMITER ;

DROP PROCEDURE IF EXISTS sp_score_save;
DROP PROCEDURE IF EXISTS sp_score_submit;
DROP PROCEDURE IF EXISTS sp_score_publish;
DROP PROCEDURE IF EXISTS sp_score_change_apply;
DROP PROCEDURE IF EXISTS sp_score_change_approve;
DROP PROCEDURE IF EXISTS sp_score_recheck_apply;
DROP PROCEDURE IF EXISTS sp_score_recheck_check;
DROP PROCEDURE IF EXISTS sp_score_recheck_finish;
DELIMITER $$

CREATE PROCEDURE sp_score_save(IN p_enrollment_id BIGINT UNSIGNED, IN p_teacher_id VARCHAR(16),
  IN p_value DECIMAL(5,2), IN p_exam_status VARCHAR(8))
BEGIN
  DECLARE v_offering VARCHAR(16);
  DECLARE v_status VARCHAR(8);
  DECLARE v_owner VARCHAR(16);
  DECLARE v_score_status VARCHAR(8);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT offering_id, status INTO v_offering, v_status FROM enrollment
    WHERE enrollment_id = p_enrollment_id FOR UPDATE;
  IF v_offering IS NULL OR v_status <> '已选' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '登分失败：无有效选课记录';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM offering_teacher WHERE offering_id = v_offering AND teacher_id = p_teacher_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '登分失败：教师不属于该教学班';
  END IF;
  SELECT recorded_by_teacher_id, score_status INTO v_owner, v_score_status
    FROM score WHERE enrollment_id = p_enrollment_id FOR UPDATE;
  IF v_owner IS NOT NULL AND (v_owner <> p_teacher_id OR v_score_status NOT IN ('草稿','退回')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '登分失败：不能覆盖其他教师或已提交的成绩';
  END IF;
  IF v_owner IS NULL THEN
    INSERT INTO score(enrollment_id, recorded_by_teacher_id, score_value, exam_status)
    VALUES(p_enrollment_id, p_teacher_id, p_value, p_exam_status);
  ELSE
    UPDATE score SET score_value = p_value, exam_status = p_exam_status, score_status = '草稿'
    WHERE enrollment_id = p_enrollment_id;
  END IF;
  COMMIT;
END$$

CREATE PROCEDURE sp_score_submit(IN p_offering_id VARCHAR(16), IN p_teacher_id VARCHAR(16))
BEGIN
  DECLARE v_offering VARCHAR(16);
  DECLARE v_total INT;
  DECLARE v_ready INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT offering_id INTO v_offering FROM course_offering
    WHERE offering_id=p_offering_id FOR UPDATE;
  IF v_offering IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '提交失败：教学班不存在';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM offering_teacher WHERE offering_id=p_offering_id AND teacher_id=p_teacher_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '提交失败：教师不属于该教学班';
  END IF;
  SELECT COUNT(*), COUNT(s.score_id) INTO v_total, v_ready
  FROM enrollment e LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
    AND s.recorded_by_teacher_id=p_teacher_id AND s.score_status IN ('草稿','退回')
  WHERE e.offering_id=p_offering_id AND e.status='已选';
  IF v_total = 0 OR v_total <> v_ready THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '提交失败：有效选课名单成绩不完整或录入人不一致';
  END IF;
  UPDATE score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id
  SET s.score_status='待审核', s.submitted_at=NOW()
  WHERE e.offering_id=p_offering_id AND e.status='已选' AND s.recorded_by_teacher_id=p_teacher_id;
  COMMIT;
END$$

CREATE PROCEDURE sp_score_publish(IN p_offering_id VARCHAR(16), IN p_admin_id VARCHAR(32),
  IN p_decision VARCHAR(8), IN p_comment VARCHAR(255))
BEGIN
  DECLARE v_offering VARCHAR(16);
  DECLARE v_total INT;
  DECLARE v_pending INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT offering_id INTO v_offering FROM course_offering
    WHERE offering_id=p_offering_id FOR UPDATE;
  IF v_offering IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审核失败：教学班不存在';
  END IF;
  IF p_admin_id IS NULL OR CHAR_LENGTH(TRIM(p_admin_id))=0 OR p_decision NOT IN ('通过','退回') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审核失败：审核人或结论无效';
  END IF;
  SELECT COUNT(*), SUM(s.score_status='待审核') INTO v_total, v_pending
  FROM enrollment e LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
  WHERE e.offering_id=p_offering_id AND e.status='已选';
  IF v_total=0 OR v_pending <> v_total OR v_pending IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审核失败：名单不完整或存在非待审核成绩';
  END IF;
  UPDATE score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id
  SET s.score_status=IF(p_decision='通过','已发布','退回'),
      s.reviewed_by_admin_id=p_admin_id, s.review_decision=p_decision,
      s.review_comment=p_comment, s.reviewed_at=NOW(),
      s.published_at=IF(p_decision='通过',NOW(),NULL)
  WHERE e.offering_id=p_offering_id AND e.status='已选' AND s.score_status='待审核';
  COMMIT;
END$$

CREATE PROCEDURE sp_score_change_apply(IN p_score_id BIGINT UNSIGNED, IN p_teacher_id VARCHAR(16),
  IN p_new_value DECIMAL(5,2), IN p_reason VARCHAR(255))
BEGIN
  DECLARE v_old DECIMAL(5,2);
  DECLARE v_owner VARCHAR(16);
  DECLARE v_status VARCHAR(8);
  DECLARE v_exam VARCHAR(8);
  DECLARE v_offering VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT s.score_value,s.recorded_by_teacher_id,s.score_status,s.exam_status,e.offering_id
    INTO v_old,v_owner,v_status,v_exam,v_offering
  FROM score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id
  WHERE s.score_id=p_score_id FOR UPDATE;
  IF v_status <> '已发布' OR v_exam <> '正常' OR v_owner <> p_teacher_id
     OR NOT EXISTS (SELECT 1 FROM offering_teacher WHERE offering_id=v_offering AND teacher_id=p_teacher_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '修改申请失败：成绩状态或教师权限不符';
  END IF;
  INSERT INTO score_change_request(score_id,applicant_teacher_id,old_value,new_value,reason)
  VALUES(p_score_id,p_teacher_id,v_old,p_new_value,p_reason);
  COMMIT;
END$$

CREATE PROCEDURE sp_score_change_approve(IN p_request_id BIGINT UNSIGNED, IN p_admin_id VARCHAR(32),
  IN p_approved TINYINT, IN p_comment VARCHAR(255))
BEGIN
  DECLARE v_score_id BIGINT UNSIGNED;
  DECLARE v_old DECIMAL(5,2);
  DECLARE v_new DECIMAL(5,2);
  DECLARE v_status VARCHAR(8);
  DECLARE v_current DECIMAL(5,2);
  DECLARE v_score_status VARCHAR(8);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  IF p_admin_id IS NULL OR CHAR_LENGTH(TRIM(p_admin_id))=0 OR p_approved NOT IN (0,1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审批失败：审核人或结论无效';
  END IF;
  SELECT score_id,old_value,new_value,status INTO v_score_id,v_old,v_new,v_status
  FROM score_change_request WHERE request_id=p_request_id FOR UPDATE;
  IF v_status IS NULL OR v_status <> '待审核' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审批失败：申请不存在或已处理';
  END IF;
  SELECT score_value,score_status INTO v_current,v_score_status FROM score WHERE score_id=v_score_id FOR UPDATE;
  IF v_current <> v_old OR v_score_status <> '已发布' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审批失败：成绩已变化，申请失效';
  END IF;
  IF p_approved=1 THEN
    UPDATE score SET score_value=v_new WHERE score_id=v_score_id;
  END IF;
  UPDATE score_change_request SET status=IF(p_approved=1,'已通过','已驳回'),
    reviewer=p_admin_id,reviewed_at=NOW(),decision_comment=p_comment WHERE request_id=p_request_id;
  COMMIT;
END$$

CREATE PROCEDURE sp_score_recheck_apply(IN p_score_id BIGINT UNSIGNED, IN p_student_id VARCHAR(16),
  IN p_reason VARCHAR(255))
BEGIN
  DECLARE v_student VARCHAR(16);
  DECLARE v_status VARCHAR(8);
  SELECT e.student_id,s.score_status INTO v_student,v_status
  FROM score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id WHERE s.score_id=p_score_id;
  IF v_student IS NULL OR v_student<>p_student_id OR v_status<>'已发布' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '复核失败：非本人成绩或成绩未发布';
  END IF;
  INSERT INTO score_recheck_request(score_id,reason) VALUES(p_score_id,p_reason);
END$$

CREATE PROCEDURE sp_score_recheck_check(IN p_recheck_id BIGINT UNSIGNED,IN p_teacher_id VARCHAR(16),
  IN p_opinion VARCHAR(255))
BEGIN
  DECLARE v_offering VARCHAR(16);
  DECLARE v_status VARCHAR(8);
  SELECT e.offering_id,r.status INTO v_offering,v_status
  FROM score_recheck_request r JOIN score s ON s.score_id=r.score_id
  JOIN enrollment e ON e.enrollment_id=s.enrollment_id WHERE r.recheck_id=p_recheck_id;
  IF v_status<>'待核查' OR NOT EXISTS
    (SELECT 1 FROM offering_teacher WHERE offering_id=v_offering AND teacher_id=p_teacher_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '核查失败：状态或教师权限不符';
  END IF;
  UPDATE score_recheck_request SET status='待确认',checked_by_teacher_id=p_teacher_id,
    teacher_opinion=p_opinion,teacher_checked_at=NOW() WHERE recheck_id=p_recheck_id;
END$$

CREATE PROCEDURE sp_score_recheck_finish(IN p_recheck_id BIGINT UNSIGNED,IN p_admin_id VARCHAR(32),
  IN p_opinion VARCHAR(255),IN p_change_request_id BIGINT UNSIGNED)
BEGIN
  DECLARE v_score_id BIGINT UNSIGNED;
  DECLARE v_status VARCHAR(8);
  DECLARE v_linked_request_id BIGINT UNSIGNED;
  DECLARE v_change_status VARCHAR(8);
  DECLARE v_change_score BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT score_id,status,change_request_id INTO v_score_id,v_status,v_linked_request_id FROM score_recheck_request
    WHERE recheck_id=p_recheck_id FOR UPDATE;
  IF v_status IS NULL OR v_status NOT IN ('待确认','待更正')
     OR p_admin_id IS NULL OR CHAR_LENGTH(TRIM(p_admin_id))=0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '复核办结失败：状态或审核人无效';
  END IF;
  IF v_status='待更正' AND (p_change_request_id IS NULL OR NOT (p_change_request_id <=> v_linked_request_id)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '复核办结失败：必须等待已关联的更正申请获批';
  END IF;
  IF p_change_request_id IS NOT NULL THEN
    SELECT score_id,status INTO v_change_score,v_change_status FROM score_change_request
      WHERE request_id=p_change_request_id;
    IF v_change_score IS NULL OR v_change_score<>v_score_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '复核办结失败：修改申请不属于该成绩';
    END IF;
    IF v_change_status='待审核' THEN
      UPDATE score_recheck_request SET status='待更正',change_request_id=p_change_request_id,
        confirmed_by_admin_id=p_admin_id,admin_opinion=p_opinion,admin_confirmed_at=NOW()
      WHERE recheck_id=p_recheck_id;
      COMMIT;
    ELSEIF v_change_status<>'已通过' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '复核办结失败：修改申请未获通过';
    END IF;
  END IF;
  IF p_change_request_id IS NULL OR v_change_status='已通过' THEN
    UPDATE score_recheck_request SET status='已办结',change_request_id=p_change_request_id,
      confirmed_by_admin_id=p_admin_id,admin_opinion=p_opinion,admin_confirmed_at=NOW(),
      conclusion=p_opinion,closed_at=NOW() WHERE recheck_id=p_recheck_id;
    COMMIT;
  END IF;
END$$
DELIMITER ;
