-- ============================================================================
-- 文件名：02_course_ddl.sql
-- 负责成员：A（组长）
-- 依赖：仅依赖 01_base_ddl.sql（与 B/C/D/E 模块零耦合）
-- 说明：课程管理核心 7 张表 + 时间重叠判定函数 + 排课/选课完整性触发器 + 事务存储过程
--       包含有意识反范式字段 course_offering.enrolled_count（由触发器与行锁存储过程强一致维护）。
-- ============================================================================

SET NAMES utf8mb4;
USE edu_system;

-- ----------------------------------------------------------------------------
-- 1. 课程库表 (course)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS course (
  course_id        VARCHAR(16)                    NOT NULL COMMENT '课程编号（如 C001）',
  course_name      VARCHAR(100)                   NOT NULL COMMENT '课程名称',
  credit           DECIMAL(3,1)                   NOT NULL COMMENT '学分',
  hours            SMALLINT UNSIGNED              NOT NULL COMMENT '总学时',
  course_type      ENUM('必修','专业选修','公选')  NOT NULL COMMENT '课程性质',
  prereq_course_id VARCHAR(16)                    NULL     COMMENT '先修课程编号（自引用，可空）',
  college_id       VARCHAR(16)                    NOT NULL COMMENT '开课学院编号',
  description      VARCHAR(255)                   NULL     COMMENT '课程简介',
  created_at       DATETIME                       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (course_id),
  KEY idx_course_college_type (college_id, course_type),
  KEY idx_course_prereq (prereq_course_id),
  CONSTRAINT chk_course_credit CHECK (credit > 0 AND credit <= 12.0),
  CONSTRAINT chk_course_hours CHECK (hours > 0 AND hours <= 240),
  CONSTRAINT fk_course_prereq FOREIGN KEY (prereq_course_id)
    REFERENCES course (course_id)
    ON UPDATE CASCADE ON DELETE SET NULL,
  CONSTRAINT fk_course_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='培养方案课程库表';

-- ----------------------------------------------------------------------------
-- 2. 开课教学班表 (course_offering)
-- 反范式设计说明：enrolled_count 冗余统计当前有效选课人数，避免高频选课并发与开课统计每次聚合大表；
--                 通过 enrollment 表增改删触发器与选课行锁存储过程保持强一致。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS course_offering (
  offering_id        VARCHAR(16)       NOT NULL COMMENT '开课教学班编号（如 O001）',
  course_id          VARCHAR(16)       NOT NULL COMMENT '所属课程编号',
  term_id            VARCHAR(16)       NOT NULL COMMENT '开课学期编号',
  target_class_id    VARCHAR(16)       NULL     COMMENT '面向行政班级（必修课指定，全校/专业选修可空）',
  capacity           SMALLINT UNSIGNED NOT NULL COMMENT '教学班额定容量',
  enrolled_count     SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '当前已选人数（反范式冗余计数器）',
  require_multimedia TINYINT(1)        NOT NULL DEFAULT 1 COMMENT '是否要求多媒体教室（1=要求，0=不要求）',
  status             ENUM('未开课','选课中','已开课','已结课','已停开')
                                       NOT NULL DEFAULT '已开课' COMMENT '教学班状态',
  created_at         DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (offering_id),
  KEY idx_offering_course (course_id),
  KEY idx_offering_term (term_id),
  KEY idx_offering_target_class (target_class_id),
  CONSTRAINT chk_offering_capacity CHECK (capacity BETWEEN 1 AND 500),
  CONSTRAINT chk_offering_enrolled_le_cap CHECK (enrolled_count <= capacity),
  CONSTRAINT chk_offering_multimedia CHECK (require_multimedia IN (0, 1)),
  CONSTRAINT fk_offering_course FOREIGN KEY (course_id)
    REFERENCES course (course_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_offering_term FOREIGN KEY (term_id)
    REFERENCES term (term_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_offering_target_class FOREIGN KEY (target_class_id)
    REFERENCES admin_class (admin_class_id)
    ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='开课教学班表';

-- ----------------------------------------------------------------------------
-- 3. 教学班-教师多对多关联表 (offering_teacher)
-- 跨模块支撑：支持一门教学班由多位教师合讲，直接服务评教模块“为某门课的所有老师评分”
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS offering_teacher (
  offering_id  VARCHAR(16)                      NOT NULL COMMENT '教学班编号',
  teacher_id   VARCHAR(16)                      NOT NULL COMMENT '教师工号',
  teacher_role ENUM('主讲','合讲','实验指导')    NOT NULL DEFAULT '主讲' COMMENT '授课角色',
  assigned_at  DATETIME                         NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '分配时间',
  PRIMARY KEY (offering_id, teacher_id),
  KEY idx_ot_teacher (teacher_id),
  CONSTRAINT fk_ot_offering FOREIGN KEY (offering_id)
    REFERENCES course_offering (offering_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_ot_teacher FOREIGN KEY (teacher_id)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教学班-授课教师多对多关联表';

-- ----------------------------------------------------------------------------
-- 4. 排课表 (course_schedule)
-- 统一时间口径：term_id + start_week + end_week + week_type(全/单/双) + day_of_week(1-7) + start_section + end_section
-- 注：此处仅保留必要单列外键索引，高频复合查询索引在 07_opt_rbac.sql 中对比实测并落地。
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS course_schedule (
  schedule_id     BIGINT UNSIGNED                NOT NULL AUTO_INCREMENT COMMENT '排课记录主键',
  offering_id     VARCHAR(16)                    NOT NULL COMMENT '所属教学班编号',
  term_id         VARCHAR(16)                    NOT NULL COMMENT '学期编号（与教学班学期一致）',
  teacher_id      VARCHAR(16)                    NOT NULL COMMENT '本次排课授课教师工号',
  classroom_id    VARCHAR(16)                    NOT NULL COMMENT '上课教室编号',
  start_week      TINYINT UNSIGNED               NOT NULL COMMENT '起始周次（1–25）',
  end_week        TINYINT UNSIGNED               NOT NULL COMMENT '结束周次（1–25）',
  week_type       ENUM('全','单','双')            NOT NULL DEFAULT '全' COMMENT '单双周标记（全/单/双）',
  day_of_week     TINYINT UNSIGNED               NOT NULL COMMENT '星期几（1=周一 … 7=周日）',
  start_section   TINYINT UNSIGNED               NOT NULL COMMENT '起始节次（1–12）',
  end_section     TINYINT UNSIGNED               NOT NULL COMMENT '结束节次（1–12）',
  schedule_status ENUM('正常','已调课','已停课')  NOT NULL DEFAULT '正常' COMMENT '排课状态',
  created_at      DATETIME                       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  updated_at      DATETIME                       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (schedule_id),
  KEY idx_sched_offering (offering_id),
  KEY idx_sched_term (term_id),
  KEY idx_sched_teacher (teacher_id),
  KEY idx_sched_classroom (classroom_id),
  CONSTRAINT chk_sched_week_bounds CHECK (start_week BETWEEN 1 AND 25 AND end_week BETWEEN 1 AND 25 AND end_week >= start_week),
  CONSTRAINT chk_sched_day_of_week CHECK (day_of_week BETWEEN 1 AND 7),
  CONSTRAINT chk_sched_section_bounds CHECK (start_section BETWEEN 1 AND 12 AND end_section BETWEEN 1 AND 12 AND end_section >= start_section),
  CONSTRAINT fk_sched_offering FOREIGN KEY (offering_id)
    REFERENCES course_offering (offering_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_sched_term FOREIGN KEY (term_id)
    REFERENCES term (term_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sched_teacher FOREIGN KEY (teacher_id)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sched_classroom FOREIGN KEY (classroom_id)
    REFERENCES classroom (classroom_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教学班排课表';

-- ----------------------------------------------------------------------------
-- 5. 学生选课表 (enrollment)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS enrollment (
  enrollment_id BIGINT UNSIGNED       NOT NULL AUTO_INCREMENT COMMENT '选课记录主键',
  student_id    VARCHAR(16)           NOT NULL COMMENT '学生学号',
  offering_id   VARCHAR(16)           NOT NULL COMMENT '教学班编号',
  enroll_time   DATETIME              NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '选课时间',
  status        ENUM('已选','已退')    NOT NULL DEFAULT '已选' COMMENT '选课状态',
  drop_time     DATETIME              NULL     COMMENT '退课时间（已退时记录）',
  PRIMARY KEY (enrollment_id),
  UNIQUE KEY uk_enroll_student_offering (student_id, offering_id),
  KEY idx_enroll_offering (offering_id),
  CONSTRAINT fk_enroll_student FOREIGN KEY (student_id)
    REFERENCES student (student_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_enroll_offering FOREIGN KEY (offering_id)
    REFERENCES course_offering (offering_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='学生选课记录表';

-- ----------------------------------------------------------------------------
-- 6. 调/停课申请审批表 (schedule_change)
-- 完整保留原上课安排与目标上课安排，支持全生命周期审批追踪与学院维度统计
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schedule_change (
  change_id            BIGINT UNSIGNED                NOT NULL AUTO_INCREMENT COMMENT '调/停课申请主键',
  schedule_id          BIGINT UNSIGNED                NOT NULL COMMENT '关联原排课记录主键',
  term_id              VARCHAR(16)                    NOT NULL COMMENT '所属学期编号',
  applicant_teacher_id VARCHAR(16)                    NOT NULL COMMENT '申请教师工号',
  change_type          ENUM('调课','停课')             NOT NULL COMMENT '变更类型（调课/停课）',
  -- 原上课信息快照
  orig_start_week      TINYINT UNSIGNED               NOT NULL COMMENT '原起始周次',
  orig_end_week        TINYINT UNSIGNED               NOT NULL COMMENT '原结束周次',
  orig_week_type       ENUM('全','单','双')            NOT NULL DEFAULT '全' COMMENT '原单双周标记',
  orig_day_of_week     TINYINT UNSIGNED               NOT NULL COMMENT '原星期几（1–7）',
  orig_start_section   TINYINT UNSIGNED               NOT NULL COMMENT '原起始节次',
  orig_end_section     TINYINT UNSIGNED               NOT NULL COMMENT '原结束节次',
  orig_classroom_id    VARCHAR(16)                    NOT NULL COMMENT '原教室编号',
  orig_teacher_id      VARCHAR(16)                    NOT NULL COMMENT '原授课教师工号',
  -- 目标上课信息（停课时可为空，调课时通过 CHECK 强制非空）
  new_start_week       TINYINT UNSIGNED               NULL     COMMENT '目标起始周次',
  new_end_week         TINYINT UNSIGNED               NULL     COMMENT '目标结束周次',
  new_week_type        ENUM('全','单','双')            NULL     COMMENT '目标单双周标记',
  new_day_of_week      TINYINT UNSIGNED               NULL     COMMENT '目标星期几（1–7）',
  new_start_section    TINYINT UNSIGNED               NULL     COMMENT '目标起始节次',
  new_end_section      TINYINT UNSIGNED               NULL     COMMENT '目标结束节次',
  new_classroom_id     VARCHAR(16)                    NULL     COMMENT '目标教室编号',
  new_teacher_id       VARCHAR(16)                    NULL     COMMENT '目标授课教师工号',
  -- 审批信息
  reason               VARCHAR(255)                   NOT NULL COMMENT '调/停课原因',
  approval_status      ENUM('待审核','已通过','已驳回') NOT NULL DEFAULT '待审核' COMMENT '审批状态',
  apply_time           DATETIME                       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '提交时间',
  reviewer             VARCHAR(32)                    NULL     COMMENT '审批教务员工号',
  review_time          DATETIME                       NULL     COMMENT '审批时间',
  review_comment       VARCHAR(255)                   NULL     COMMENT '审批意见',
  PRIMARY KEY (change_id),
  KEY idx_sc_schedule (schedule_id),
  KEY idx_sc_term (term_id),
  KEY idx_sc_applicant (applicant_teacher_id),
  KEY idx_sc_orig_room (orig_classroom_id),
  KEY idx_sc_orig_teacher (orig_teacher_id),
  KEY idx_sc_new_room (new_classroom_id),
  KEY idx_sc_new_teacher (new_teacher_id),
  CONSTRAINT chk_sc_orig_valid CHECK (
    orig_start_week BETWEEN 1 AND 25 AND orig_end_week BETWEEN 1 AND 25 AND orig_end_week >= orig_start_week
    AND orig_day_of_week BETWEEN 1 AND 7
    AND orig_start_section BETWEEN 1 AND 12 AND orig_end_section BETWEEN 1 AND 12 AND orig_end_section >= orig_start_section
  ),
  CONSTRAINT chk_sc_new_valid CHECK (
    change_type = '停课'
    OR (
      change_type = '调课'
      AND new_start_week BETWEEN 1 AND 25 AND new_end_week BETWEEN 1 AND 25 AND new_end_week >= new_start_week
      AND new_week_type IS NOT NULL
      AND new_day_of_week BETWEEN 1 AND 7
      AND new_start_section BETWEEN 1 AND 12 AND new_end_section BETWEEN 1 AND 12 AND new_end_section >= new_start_section
    )
  ),
  CONSTRAINT fk_sc_schedule FOREIGN KEY (schedule_id)
    REFERENCES course_schedule (schedule_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_term FOREIGN KEY (term_id)
    REFERENCES term (term_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_applicant FOREIGN KEY (applicant_teacher_id)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_orig_room FOREIGN KEY (orig_classroom_id)
    REFERENCES classroom (classroom_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_orig_teacher FOREIGN KEY (orig_teacher_id)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_new_room FOREIGN KEY (new_classroom_id)
    REFERENCES classroom (classroom_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_sc_new_teacher FOREIGN KEY (new_teacher_id)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教师调课与停课申请审批表';

-- ----------------------------------------------------------------------------
-- 7. 免修/免听申请审批表 (course_exemption)
-- 支持二级审批：任课教师初审 (teacher_review) -> 教务员终审 (admin_review)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS course_exemption (
  exemption_id        BIGINT UNSIGNED                          NOT NULL AUTO_INCREMENT COMMENT '免修/免听申请主键',
  student_id          VARCHAR(16)                              NOT NULL COMMENT '申请学生学号',
  offering_id         VARCHAR(16)                              NOT NULL COMMENT '申请免修/免听的教学班编号',
  exemption_type      ENUM('免修','免听')                       NOT NULL COMMENT '申请类型（免修/免听）',
  reason              VARCHAR(255)                             NOT NULL COMMENT '申请理由',
  approval_status     ENUM('待教师审核','待教务终审','已通过','已驳回')
                                                               NOT NULL DEFAULT '待教师审核' COMMENT '综合审批状态',
  teacher_review      ENUM('待审核','同意','不同意')            NOT NULL DEFAULT '待审核' COMMENT '任课教师审核结论',
  teacher_reviewer    VARCHAR(16)                              NULL     COMMENT '审核教师工号',
  teacher_review_time DATETIME                                 NULL     COMMENT '教师审核时间',
  admin_review        ENUM('待审核','同意','不同意')            NOT NULL DEFAULT '待审核' COMMENT '教务员终审结论',
  admin_reviewer      VARCHAR(32)                              NULL     COMMENT '终审教务员工号',
  admin_review_time   DATETIME                                 NULL     COMMENT '教务终审时间',
  apply_time          DATETIME                                 NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '提交时间',
  PRIMARY KEY (exemption_id),
  UNIQUE KEY uk_exemption_stu_off_type (student_id, offering_id, exemption_type),
  KEY idx_exemption_offering (offering_id),
  KEY idx_exemption_teacher_reviewer (teacher_reviewer),
  CONSTRAINT fk_exemption_student FOREIGN KEY (student_id)
    REFERENCES student (student_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_exemption_offering FOREIGN KEY (offering_id)
    REFERENCES course_offering (offering_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_exemption_teacher_reviewer FOREIGN KEY (teacher_reviewer)
    REFERENCES teacher (teacher_id)
    ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='学生免修与免听申请审批表';

-- ============================================================================
-- 8. 核心函数：判定两个排课时间槽是否存在实际重叠 (fn_time_overlap)
--    返回 1 表示冲突，0 表示不冲突（精确处理周次区间、单双周奇偶与节次区间）
-- ============================================================================
DROP FUNCTION IF EXISTS fn_time_overlap;
DELIMITER $$
CREATE FUNCTION fn_time_overlap(
  p_w1_start TINYINT UNSIGNED,
  p_w1_end   TINYINT UNSIGNED,
  p_t1       VARCHAR(4),
  p_d1       TINYINT UNSIGNED,
  p_s1_start TINYINT UNSIGNED,
  p_s1_end   TINYINT UNSIGNED,
  p_w2_start TINYINT UNSIGNED,
  p_w2_end   TINYINT UNSIGNED,
  p_t2       VARCHAR(4),
  p_d2       TINYINT UNSIGNED,
  p_s2_start TINYINT UNSIGNED,
  p_s2_end   TINYINT UNSIGNED
) RETURNS TINYINT
DETERMINISTIC
NO SQL
BEGIN
  DECLARE v_ow_start TINYINT UNSIGNED;
  DECLARE v_ow_end   TINYINT UNSIGNED;

  -- 1) 不同星期或节次区间不相交，无冲突
  IF p_d1 <> p_d2 OR p_s1_start > p_s2_end OR p_s2_start > p_s1_end THEN
    RETURN 0;
  END IF;

  -- 2) 计算周次交集区间
  SET v_ow_start = GREATEST(p_w1_start, p_w2_start);
  SET v_ow_end   = LEAST(p_w1_end, p_w2_end);
  IF v_ow_start > v_ow_end THEN
    RETURN 0;
  END IF;

  -- 3) 单双周互斥直接无冲突
  IF (p_t1 = '单' AND p_t2 = '双') OR (p_t1 = '双' AND p_t2 = '单') THEN
    RETURN 0;
  END IF;

  -- 4) 只要交集跨度 >= 2 周，必然同时包含单周与双周
  IF v_ow_end > v_ow_start THEN
    RETURN 1;
  END IF;

  -- 5) 交集仅有唯一 1 周时，校验奇偶性是否命中
  IF p_t1 = '单' OR p_t2 = '单' THEN
    RETURN IF(MOD(v_ow_start, 2) = 1, 1, 0);
  END IF;
  IF p_t1 = '双' OR p_t2 = '双' THEN
    RETURN IF(MOD(v_ow_start, 2) = 0, 1, 0);
  END IF;

  RETURN 1;
END$$
DELIMITER ;

-- ============================================================================
-- 9. 课程先修与调课目标完整性触发器 + 排课多维冲突校验触发器 (INSERT / UPDATE)
--    说明：MySQL 8 不允许对含 ON UPDATE CASCADE/ON DELETE SET NULL 外键动作的列建 CHECK，
--          因此将先修非自引与调课目标教室/教师非空校验下沉至 BEFORE 触发器。
--    排课触发器覆盖全部 6 维校验：学期一致性、教室状态、教室容量、多媒体要求、
--    教室时间冲突、教师时间冲突、行政班级与已选学生时间冲突。
-- ============================================================================
DROP TRIGGER IF EXISTS trg_course_bi;
DROP TRIGGER IF EXISTS trg_course_bu;
DROP TRIGGER IF EXISTS trg_schedule_change_bi;
DROP TRIGGER IF EXISTS trg_schedule_change_bu;
DROP TRIGGER IF EXISTS trg_course_schedule_bi;
DROP TRIGGER IF EXISTS trg_course_schedule_bu;
DELIMITER $$

CREATE TRIGGER trg_course_bi
BEFORE INSERT ON course
FOR EACH ROW
BEGIN
  IF NEW.prereq_course_id IS NOT NULL AND NEW.prereq_course_id = NEW.course_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '课程维护失败：课程的先修课程不能指向自身';
  END IF;
END$$

CREATE TRIGGER trg_course_bu
BEFORE UPDATE ON course
FOR EACH ROW
BEGIN
  IF NEW.prereq_course_id IS NOT NULL AND NEW.prereq_course_id = NEW.course_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '课程维护失败：课程的先修课程不能指向自身';
  END IF;
END$$

CREATE TRIGGER trg_schedule_change_bi
BEFORE INSERT ON schedule_change
FOR EACH ROW
BEGIN
  IF NEW.change_type = '调课' THEN
    IF NEW.new_classroom_id IS NULL OR NEW.new_teacher_id IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '调课申请失败：调课必须指定目标教室与目标授课教师';
    END IF;
    IF NEW.new_start_week = NEW.orig_start_week
       AND NEW.new_end_week = NEW.orig_end_week
       AND NEW.new_week_type = NEW.orig_week_type
       AND NEW.new_day_of_week = NEW.orig_day_of_week
       AND NEW.new_start_section = NEW.orig_start_section
       AND NEW.new_end_section = NEW.orig_end_section
       AND NEW.new_classroom_id = NEW.orig_classroom_id
       AND NEW.new_teacher_id = NEW.orig_teacher_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '调课申请失败：目标安排与原排课完全一致，请至少变更时间、教室或教师之一';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_schedule_change_bu
BEFORE UPDATE ON schedule_change
FOR EACH ROW
BEGIN
  IF NEW.change_type = '调课' THEN
    IF NEW.new_classroom_id IS NULL OR NEW.new_teacher_id IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '调课更新失败：调课必须指定目标教室与目标授课教师';
    END IF;
    IF NEW.new_start_week = NEW.orig_start_week
       AND NEW.new_end_week = NEW.orig_end_week
       AND NEW.new_week_type = NEW.orig_week_type
       AND NEW.new_day_of_week = NEW.orig_day_of_week
       AND NEW.new_start_section = NEW.orig_start_section
       AND NEW.new_end_section = NEW.orig_end_section
       AND NEW.new_classroom_id = NEW.orig_classroom_id
       AND NEW.new_teacher_id = NEW.orig_teacher_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '调课更新失败：目标安排与原排课完全一致，请至少变更时间、教室或教师之一';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_course_schedule_bi
BEFORE INSERT ON course_schedule
FOR EACH ROW
BEGIN
  DECLARE v_off_term_id    VARCHAR(16);
  DECLARE v_off_cap        SMALLINT UNSIGNED;
  DECLARE v_off_req_mm     TINYINT(1);
  DECLARE v_target_cls_id  VARCHAR(16);
  DECLARE v_room_cap       SMALLINT UNSIGNED;
  DECLARE v_room_mm        TINYINT(1);
  DECLARE v_room_status    VARCHAR(16);
  DECLARE v_conflict_cnt   INT DEFAULT 0;

  IF NEW.schedule_status = '正常' THEN
    SELECT term_id, capacity, require_multimedia, target_class_id
      INTO v_off_term_id, v_off_cap, v_off_req_mm, v_target_cls_id
    FROM course_offering
    WHERE offering_id = NEW.offering_id;

    IF v_off_term_id <> NEW.term_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：排课学期与教学班所属学期不一致';
    END IF;

    SELECT capacity, is_multimedia, status
      INTO v_room_cap, v_room_mm, v_room_status
    FROM classroom
    WHERE classroom_id = NEW.classroom_id;

    IF v_room_status <> '可用' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：目标教室当前处于维修或停用状态';
    END IF;

    IF v_room_cap < v_off_cap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：教室容纳人数小于教学班额定容量';
    END IF;

    IF v_off_req_mm = 1 AND v_room_mm = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：教学班要求多媒体设备，目标教室不支持多媒体';
    END IF;

    -- 教室时间冲突校验
    SELECT COUNT(*) INTO v_conflict_cnt
    FROM course_schedule cs
    WHERE cs.term_id = NEW.term_id
      AND cs.classroom_id = NEW.classroom_id
      AND cs.schedule_status = '正常'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：目标教室在该时间段已有其他课程安排';
    END IF;

    -- 教师时间冲突校验
    SELECT COUNT(*) INTO v_conflict_cnt
    FROM course_schedule cs
    WHERE cs.term_id = NEW.term_id
      AND cs.teacher_id = NEW.teacher_id
      AND cs.schedule_status = '正常'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：授课教师在该时间段已有其他排课冲突';
    END IF;

    -- 面向行政班级时间冲突校验
    IF v_target_cls_id IS NOT NULL THEN
      SELECT COUNT(*) INTO v_conflict_cnt
      FROM course_schedule cs
      JOIN course_offering co ON co.offering_id = cs.offering_id
      WHERE cs.term_id = NEW.term_id
        AND cs.schedule_status = '正常'
        AND cs.offering_id <> NEW.offering_id
        AND co.target_class_id = v_target_cls_id
        AND fn_time_overlap(
              cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
              NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
            ) = 1;
      IF v_conflict_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：目标行政班级在该时间段已有其他课程安排';
      END IF;
    END IF;

    -- 已选课学生个人时间冲突校验
    SELECT COUNT(*) INTO v_conflict_cnt
    FROM enrollment e1
    JOIN enrollment e2
      ON e2.student_id = e1.student_id
     AND e2.status = '已选'
     AND e2.offering_id <> NEW.offering_id
    JOIN course_schedule cs
      ON cs.offering_id = e2.offering_id
     AND cs.term_id = NEW.term_id
     AND cs.schedule_status = '正常'
    WHERE e1.offering_id = NEW.offering_id
      AND e1.status = '已选'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：教学班内已有选课学生在该时间段存在课表冲突';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_course_schedule_bu
BEFORE UPDATE ON course_schedule
FOR EACH ROW
BEGIN
  DECLARE v_off_term_id    VARCHAR(16);
  DECLARE v_off_cap        SMALLINT UNSIGNED;
  DECLARE v_off_req_mm     TINYINT(1);
  DECLARE v_target_cls_id  VARCHAR(16);
  DECLARE v_room_cap       SMALLINT UNSIGNED;
  DECLARE v_room_mm        TINYINT(1);
  DECLARE v_room_status    VARCHAR(16);
  DECLARE v_conflict_cnt   INT DEFAULT 0;

  IF NEW.schedule_status = '正常' THEN
    SELECT term_id, capacity, require_multimedia, target_class_id
      INTO v_off_term_id, v_off_cap, v_off_req_mm, v_target_cls_id
    FROM course_offering
    WHERE offering_id = NEW.offering_id;

    IF v_off_term_id <> NEW.term_id THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：排课学期与教学班所属学期不一致';
    END IF;

    SELECT capacity, is_multimedia, status
      INTO v_room_cap, v_room_mm, v_room_status
    FROM classroom
    WHERE classroom_id = NEW.classroom_id;

    IF v_room_status <> '可用' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：目标教室当前处于维修或停用状态';
    END IF;

    IF v_room_cap < v_off_cap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：教室容纳人数小于教学班额定容量';
    END IF;

    IF v_off_req_mm = 1 AND v_room_mm = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：教学班要求多媒体设备，目标教室不支持多媒体';
    END IF;

    SELECT COUNT(*) INTO v_conflict_cnt
    FROM course_schedule cs
    WHERE cs.schedule_id <> OLD.schedule_id
      AND cs.term_id = NEW.term_id
      AND cs.classroom_id = NEW.classroom_id
      AND cs.schedule_status = '正常'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：目标教室在该时间段已有其他课程安排';
    END IF;

    SELECT COUNT(*) INTO v_conflict_cnt
    FROM course_schedule cs
    WHERE cs.schedule_id <> OLD.schedule_id
      AND cs.term_id = NEW.term_id
      AND cs.teacher_id = NEW.teacher_id
      AND cs.schedule_status = '正常'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：授课教师在该时间段已有其他排课冲突';
    END IF;

    IF v_target_cls_id IS NOT NULL THEN
      SELECT COUNT(*) INTO v_conflict_cnt
      FROM course_schedule cs
      JOIN course_offering co ON co.offering_id = cs.offering_id
      WHERE cs.schedule_id <> OLD.schedule_id
        AND cs.term_id = NEW.term_id
        AND cs.schedule_status = '正常'
        AND cs.offering_id <> NEW.offering_id
        AND co.target_class_id = v_target_cls_id
        AND fn_time_overlap(
              cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
              NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
            ) = 1;
      IF v_conflict_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：目标行政班级在该时间段已有其他课程安排';
      END IF;
    END IF;

    SELECT COUNT(*) INTO v_conflict_cnt
    FROM enrollment e1
    JOIN enrollment e2
      ON e2.student_id = e1.student_id
     AND e2.status = '已选'
     AND e2.offering_id <> NEW.offering_id
    JOIN course_schedule cs
      ON cs.offering_id = e2.offering_id
     AND cs.schedule_id <> OLD.schedule_id
     AND cs.term_id = NEW.term_id
     AND cs.schedule_status = '正常'
    WHERE e1.offering_id = NEW.offering_id
      AND e1.status = '已选'
      AND fn_time_overlap(
            cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section,
            NEW.start_week, NEW.end_week, NEW.week_type, NEW.day_of_week, NEW.start_section, NEW.end_section
          ) = 1;
    IF v_conflict_cnt > 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课更新失败：教学班内已有选课学生在该时间段存在课表冲突';
    END IF;
  END IF;
END$$

-- ============================================================================
-- 10. 选课容量兜底校验 + 反范式计数 (enrolled_count) 强一致维护触发器
-- ============================================================================
DROP TRIGGER IF EXISTS trg_enrollment_bi$$
DROP TRIGGER IF EXISTS trg_enrollment_ai$$
DROP TRIGGER IF EXISTS trg_enrollment_bu$$
DROP TRIGGER IF EXISTS trg_enrollment_au$$
DROP TRIGGER IF EXISTS trg_enrollment_ad$$

CREATE TRIGGER trg_enrollment_bi
BEFORE INSERT ON enrollment
FOR EACH ROW
BEGIN
  DECLARE v_cap SMALLINT UNSIGNED;
  DECLARE v_cnt SMALLINT UNSIGNED;

  IF NEW.status = '已选' THEN
    SELECT capacity, enrolled_count INTO v_cap, v_cnt
    FROM course_offering
    WHERE offering_id = NEW.offering_id;

    IF v_cnt >= v_cap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：该教学班人数已满，超过容量上限';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_enrollment_ai
AFTER INSERT ON enrollment
FOR EACH ROW
BEGIN
  IF NEW.status = '已选' THEN
    UPDATE course_offering
    SET enrolled_count = enrolled_count + 1
    WHERE offering_id = NEW.offering_id;
  END IF;
END$$

CREATE TRIGGER trg_enrollment_bu
BEFORE UPDATE ON enrollment
FOR EACH ROW
BEGIN
  DECLARE v_cap SMALLINT UNSIGNED;
  DECLARE v_cnt SMALLINT UNSIGNED;

  IF OLD.status = '已退' AND NEW.status = '已选' THEN
    SELECT capacity, enrolled_count INTO v_cap, v_cnt
    FROM course_offering
    WHERE offering_id = NEW.offering_id;

    IF v_cnt >= v_cap THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '重选失败：该教学班人数已满，超过容量上限';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_enrollment_au
AFTER UPDATE ON enrollment
FOR EACH ROW
BEGIN
  IF OLD.status = '已选' AND NEW.status = '已退' THEN
    UPDATE course_offering
    SET enrolled_count = enrolled_count - 1
    WHERE offering_id = NEW.offering_id;
  ELSEIF OLD.status = '已退' AND NEW.status = '已选' THEN
    UPDATE course_offering
    SET enrolled_count = enrolled_count + 1
    WHERE offering_id = NEW.offering_id;
  END IF;
END$$

CREATE TRIGGER trg_enrollment_ad
AFTER DELETE ON enrollment
FOR EACH ROW
BEGIN
  IF OLD.status = '已选' THEN
    UPDATE course_offering
    SET enrolled_count = enrolled_count - 1
    WHERE offering_id = OLD.offering_id;
  END IF;
END$$

-- ============================================================================
-- 11. 核心业务存储过程（原子事务控制）
--     (1) sp_assign_schedule          教务员单次排课（事务包装）
--     (2) sp_enroll_student           学生选课（行锁防超卖 + 先修课 + 时间冲突）
--     (3) sp_drop_student             学生退课（同步扣减已选人数）
--     (4) sp_submit_schedule_change   教师提交调/停课申请（自动快照原排课信息）
--     (5) sp_approve_schedule_change  教务员审批调/停课（通过则原子同步排课表）
-- ============================================================================
DROP PROCEDURE IF EXISTS sp_assign_schedule$$
DROP PROCEDURE IF EXISTS sp_enroll_student$$
DROP PROCEDURE IF EXISTS sp_drop_student$$
DROP PROCEDURE IF EXISTS sp_submit_schedule_change$$
DROP PROCEDURE IF EXISTS sp_approve_schedule_change$$

CREATE PROCEDURE sp_assign_schedule(
  IN p_offering_id   VARCHAR(16),
  IN p_teacher_id    VARCHAR(16),
  IN p_classroom_id  VARCHAR(16),
  IN p_start_week    TINYINT UNSIGNED,
  IN p_end_week      TINYINT UNSIGNED,
  IN p_week_type     ENUM('全','单','双'),
  IN p_day_of_week   TINYINT UNSIGNED,
  IN p_start_section TINYINT UNSIGNED,
  IN p_end_section   TINYINT UNSIGNED
)
BEGIN
  DECLARE v_term_id VARCHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT term_id INTO v_term_id
  FROM course_offering
  WHERE offering_id = p_offering_id
  FOR UPDATE;

  IF v_term_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '排课失败：指定教学班不存在';
  END IF;

  INSERT INTO course_schedule (
    offering_id, term_id, teacher_id, classroom_id,
    start_week, end_week, week_type, day_of_week,
    start_section, end_section, schedule_status
  ) VALUES (
    p_offering_id, v_term_id, p_teacher_id, p_classroom_id,
    p_start_week, p_end_week, p_week_type, p_day_of_week,
    p_start_section, p_end_section, '正常'
  );

  -- 若该教师尚未登记在该教学班授课名单中，自动补录为合讲教师
  INSERT IGNORE INTO offering_teacher (offering_id, teacher_id, teacher_role)
  VALUES (p_offering_id, p_teacher_id, '合讲');

  COMMIT;
END$$

CREATE PROCEDURE sp_enroll_student(
  IN p_student_id  VARCHAR(16),
  IN p_offering_id VARCHAR(16)
)
BEGIN
  DECLARE v_stu_status     VARCHAR(16);
  DECLARE v_off_status     VARCHAR(16);
  DECLARE v_course_id      VARCHAR(16);
  DECLARE v_prereq_id      VARCHAR(16);
  DECLARE v_cap            SMALLINT UNSIGNED;
  DECLARE v_cnt            SMALLINT UNSIGNED;
  DECLARE v_exist_status   VARCHAR(16);
  DECLARE v_prereq_met     INT DEFAULT 0;
  DECLARE v_conflict_cnt   INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT enrollment_status INTO v_stu_status
  FROM student
  WHERE student_id = p_student_id;

  IF v_stu_status IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：学生学号不存在';
  END IF;
  IF v_stu_status NOT IN ('在读','复学','留级') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：当前学籍状态不允许选课';
  END IF;

  -- 行锁锁定目标教学班，防止高并发超卖
  SELECT co.course_id, co.capacity, co.enrolled_count, co.status, c.prereq_course_id
    INTO v_course_id, v_cap, v_cnt, v_off_status, v_prereq_id
  FROM course_offering co
  JOIN course c ON c.course_id = co.course_id
  WHERE co.offering_id = p_offering_id
  FOR UPDATE;

  IF v_course_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：指定教学班不存在';
  END IF;
  IF v_off_status NOT IN ('选课中','已开课') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：该教学班当前未开放选课';
  END IF;

  SELECT status INTO v_exist_status
  FROM enrollment
  WHERE student_id = p_student_id AND offering_id = p_offering_id
  LIMIT 1;

  IF v_exist_status = '已选' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：该学生已选择此教学班，请勿重复选课';
  END IF;

  -- 1) 先修课程校验（支持已结课修读记录或已通过的免修审批）
  IF v_prereq_id IS NOT NULL THEN
    SELECT COUNT(*) INTO v_prereq_met
    FROM enrollment e
    JOIN course_offering co ON co.offering_id = e.offering_id
    JOIN term t ON t.term_id = co.term_id
    WHERE e.student_id = p_student_id
      AND e.status = '已选'
      AND co.course_id = v_prereq_id
      AND (t.status = '已结束' OR co.status = '已结课');

    IF v_prereq_met = 0 THEN
      SELECT COUNT(*) INTO v_prereq_met
      FROM course_exemption ce
      JOIN course_offering co ON co.offering_id = ce.offering_id
      WHERE ce.student_id = p_student_id
        AND co.course_id = v_prereq_id
        AND ce.exemption_type = '免修'
        AND ce.approval_status = '已通过';
    END IF;

    IF v_prereq_met = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：未完成该课程要求的先修课程';
    END IF;
  END IF;

  -- 2) 容量校验
  IF v_cnt >= v_cap THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：该教学班人数已满，超过容量上限';
  END IF;

  -- 3) 学生个人课表时间冲突校验
  SELECT COUNT(*) INTO v_conflict_cnt
  FROM course_schedule cs_new
  JOIN enrollment e_exist
    ON e_exist.student_id = p_student_id
   AND e_exist.status = '已选'
   AND e_exist.offering_id <> p_offering_id
  JOIN course_schedule cs_exist
    ON cs_exist.offering_id = e_exist.offering_id
   AND cs_exist.term_id = cs_new.term_id
   AND cs_exist.schedule_status = '正常'
  WHERE cs_new.offering_id = p_offering_id
    AND cs_new.schedule_status = '正常'
    AND fn_time_overlap(
          cs_new.start_week, cs_new.end_week, cs_new.week_type, cs_new.day_of_week, cs_new.start_section, cs_new.end_section,
          cs_exist.start_week, cs_exist.end_week, cs_exist.week_type, cs_exist.day_of_week, cs_exist.start_section, cs_exist.end_section
        ) = 1;

  IF v_conflict_cnt > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '选课失败：该教学班上课时间与学生已有课表冲突';
  END IF;

  -- 4) 写入或恢复选课记录（enrolled_count 由触发器自动 +1）
  IF v_exist_status = '已退' THEN
    UPDATE enrollment
    SET status = '已选', enroll_time = NOW(), drop_time = NULL
    WHERE student_id = p_student_id AND offering_id = p_offering_id;
  ELSE
    INSERT INTO enrollment (student_id, offering_id, enroll_time, status)
    VALUES (p_student_id, p_offering_id, NOW(), '已选');
  END IF;

  COMMIT;
END$$

CREATE PROCEDURE sp_drop_student(
  IN p_student_id  VARCHAR(16),
  IN p_offering_id VARCHAR(16)
)
BEGIN
  DECLARE v_updated INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  UPDATE enrollment
  SET status = '已退', drop_time = NOW()
  WHERE student_id = p_student_id
    AND offering_id = p_offering_id
    AND status = '已选';

  SET v_updated = ROW_COUNT();
  IF v_updated = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '退课失败：未找到有效的已选记录';
  END IF;

  COMMIT;
END$$

CREATE PROCEDURE sp_submit_schedule_change(
  IN  p_schedule_id       BIGINT UNSIGNED,
  IN  p_applicant_teacher VARCHAR(16),
  IN  p_change_type       ENUM('调课','停课'),
  IN  p_new_start_week    TINYINT UNSIGNED,
  IN  p_new_end_week      TINYINT UNSIGNED,
  IN  p_new_week_type     ENUM('全','单','双'),
  IN  p_new_day_of_week   TINYINT UNSIGNED,
  IN  p_new_start_section TINYINT UNSIGNED,
  IN  p_new_end_section   TINYINT UNSIGNED,
  IN  p_new_classroom_id  VARCHAR(16),
  IN  p_new_teacher_id    VARCHAR(16),
  IN  p_reason            VARCHAR(255),
  OUT p_out_change_id     BIGINT UNSIGNED
)
BEGIN
  DECLARE v_offering_id   VARCHAR(16);
  DECLARE v_term_id       VARCHAR(16);
  DECLARE v_orig_sw       TINYINT UNSIGNED;
  DECLARE v_orig_ew       TINYINT UNSIGNED;
  DECLARE v_orig_wt       ENUM('全','单','双');
  DECLARE v_orig_dow      TINYINT UNSIGNED;
  DECLARE v_orig_ss       TINYINT UNSIGNED;
  DECLARE v_orig_es       TINYINT UNSIGNED;
  DECLARE v_orig_room     VARCHAR(16);
  DECLARE v_orig_teacher  VARCHAR(16);
  DECLARE v_status        VARCHAR(16);
  DECLARE v_is_authorized INT DEFAULT 0;

  SELECT offering_id, term_id, start_week, end_week, week_type, day_of_week,
         start_section, end_section, classroom_id, teacher_id, schedule_status
    INTO v_offering_id, v_term_id, v_orig_sw, v_orig_ew, v_orig_wt, v_orig_dow,
         v_orig_ss, v_orig_es, v_orig_room, v_orig_teacher, v_status
  FROM course_schedule
  WHERE schedule_id = p_schedule_id;

  IF v_term_id IS NULL OR v_status <> '正常' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申请失败：原排课记录不存在或已非正常状态';
  END IF;

  -- 归属权限校验：仅本排课授课教师或同教学班合讲教师可发起调/停课申请（对齐 UC-KC-10）
  SELECT COUNT(*) INTO v_is_authorized
  FROM offering_teacher
  WHERE offering_id = v_offering_id
    AND teacher_id = p_applicant_teacher;

  IF p_applicant_teacher <> v_orig_teacher AND v_is_authorized = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申请失败：申请教师非该教学班任课教师，无权提交调/停课申请';
  END IF;

  -- 实质变更校验：调课至少变更周次、单双周、星期、节次、教室或教师之一
  IF p_change_type = '调课'
     AND p_new_start_week = v_orig_sw
     AND p_new_end_week = v_orig_ew
     AND p_new_week_type = v_orig_wt
     AND p_new_day_of_week = v_orig_dow
     AND p_new_start_section = v_orig_ss
     AND p_new_end_section = v_orig_es
     AND p_new_classroom_id = v_orig_room
     AND p_new_teacher_id = v_orig_teacher THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '申请失败：调课目标安排与原排课完全一致，请至少变更时间、教室或教师之一';
  END IF;

  INSERT INTO schedule_change (
    schedule_id, term_id, applicant_teacher_id, change_type,
    orig_start_week, orig_end_week, orig_week_type, orig_day_of_week,
    orig_start_section, orig_end_section, orig_classroom_id, orig_teacher_id,
    new_start_week, new_end_week, new_week_type, new_day_of_week,
    new_start_section, new_end_section, new_classroom_id, new_teacher_id,
    reason, approval_status
  ) VALUES (
    p_schedule_id, v_term_id, p_applicant_teacher, p_change_type,
    v_orig_sw, v_orig_ew, v_orig_wt, v_orig_dow,
    v_orig_ss, v_orig_es, v_orig_room, v_orig_teacher,
    p_new_start_week, p_new_end_week, p_new_week_type, p_new_day_of_week,
    p_new_start_section, p_new_end_section, p_new_classroom_id, p_new_teacher_id,
    p_reason, '待审核'
  );

  SET p_out_change_id = LAST_INSERT_ID();
END$$

CREATE PROCEDURE sp_approve_schedule_change(
  IN p_change_id BIGINT UNSIGNED,
  IN p_decision  ENUM('已通过','已驳回'),
  IN p_reviewer  VARCHAR(32),
  IN p_comment   VARCHAR(255)
)
BEGIN
  DECLARE v_schedule_id   BIGINT UNSIGNED;
  DECLARE v_offering_id   VARCHAR(16);
  DECLARE v_change_type   ENUM('调课','停课');
  DECLARE v_curr_status   ENUM('待审核','已通过','已驳回');
  DECLARE v_new_sw        TINYINT UNSIGNED;
  DECLARE v_new_ew        TINYINT UNSIGNED;
  DECLARE v_new_wt        ENUM('全','单','双');
  DECLARE v_new_dow       TINYINT UNSIGNED;
  DECLARE v_new_ss        TINYINT UNSIGNED;
  DECLARE v_new_es        TINYINT UNSIGNED;
  DECLARE v_new_room      VARCHAR(16);
  DECLARE v_new_teacher   VARCHAR(16);
  DECLARE v_orig_teacher  VARCHAR(16);

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT schedule_id, change_type, approval_status,
         new_start_week, new_end_week, new_week_type, new_day_of_week,
         new_start_section, new_end_section, new_classroom_id, new_teacher_id, orig_teacher_id
    INTO v_schedule_id, v_change_type, v_curr_status,
         v_new_sw, v_new_ew, v_new_wt, v_new_dow,
         v_new_ss, v_new_es, v_new_room, v_new_teacher, v_orig_teacher
  FROM schedule_change
  WHERE change_id = p_change_id
  FOR UPDATE;

  IF v_schedule_id IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审批失败：调/停课申请记录不存在';
  END IF;
  IF v_curr_status <> '待审核' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = '审批失败：该申请已处理，不可重复审批';
  END IF;

  UPDATE schedule_change
  SET approval_status = p_decision,
      reviewer = p_reviewer,
      review_time = NOW(),
      review_comment = p_comment
  WHERE change_id = p_change_id;

  IF p_decision = '已通过' THEN
    SELECT offering_id INTO v_offering_id
    FROM course_schedule
    WHERE schedule_id = v_schedule_id
    FOR UPDATE;

    IF v_change_type = '调课' THEN
      -- 更新排课记录将自动触发 trg_course_schedule_bu 的 6 维冲突与教室校验，冲突则整笔回滚
      UPDATE course_schedule
      SET start_week = v_new_sw,
          end_week = v_new_ew,
          week_type = v_new_wt,
          day_of_week = v_new_dow,
          start_section = v_new_ss,
          end_section = v_new_es,
          classroom_id = v_new_room,
          teacher_id = v_new_teacher,
          schedule_status = '正常'
      WHERE schedule_id = v_schedule_id;

      IF v_new_teacher <> v_orig_teacher THEN
        INSERT IGNORE INTO offering_teacher (offering_id, teacher_id, teacher_role)
        VALUES (v_offering_id, v_new_teacher, '合讲');
      END IF;
    ELSE
      UPDATE course_schedule
      SET schedule_status = '已停课'
      WHERE schedule_id = v_schedule_id;
    END IF;
  END IF;

  COMMIT;
END$$

DELIMITER ;
