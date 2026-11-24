-- ============================================================================
-- 文件名：07_opt_rbac.sql
-- 负责成员：A（组长）
-- 依赖：仅依赖 01_base 与 02_course（与 B/C/D/E 模块零耦合）
-- 说明：覆盖全部选做加分项：
--   Part 1：RBAC 访问控制表（5 张表）与教务员/教师/学生三角色权限初始化
--   Part 2：三角色安全隔离视图（6 个视图）+ MySQL 8 ROLE/GRANT 最小权限参考 + 视图脱敏验证
--   Part 3：大样本造数（enrollment 50,000+ 行、schedule_change 30,000+ 行、course_schedule 12,000+ 行）
--           与高频查询加复合索引前后 EXPLAIN / EXPLAIN ANALYZE 实测对比，并自动清理压测合成数据。
-- ============================================================================

SET NAMES utf8mb4;
USE edu_system;

-- ============================================================================
-- PART 1：RBAC 权限管理模型（5 张表 + 初始种子数据）
-- ============================================================================

CREATE TABLE IF NOT EXISTS sys_role (
  role_id     VARCHAR(16)  NOT NULL COMMENT '角色编号（如 ROLE_ADMIN）',
  role_code   VARCHAR(32)  NOT NULL COMMENT '角色代码',
  role_name   VARCHAR(32)  NOT NULL COMMENT '角色名称（教务员/教师/学生）',
  description VARCHAR(255) NULL     COMMENT '角色职责描述',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (role_id),
  UNIQUE KEY uk_sys_role_code (role_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='RBAC 角色表';

CREATE TABLE IF NOT EXISTS sys_user (
  user_id       VARCHAR(32)                      NOT NULL COMMENT '系统账号主键',
  username      VARCHAR(64)                      NOT NULL COMMENT '登录用户名',
  password_hash CHAR(64)                         NOT NULL COMMENT '口令摘要（SHA-256 占位演示，生产环境使用加盐 Argon2/bcrypt）',
  display_name  VARCHAR(64)                      NOT NULL COMMENT '显示姓名',
  role_type     ENUM('教务员','教师','学生')       NOT NULL COMMENT '主体类型',
  ref_id        VARCHAR(16)                      NULL     COMMENT '关联业务主键（teacher_id / student_id / 教务员工号）',
  college_id    VARCHAR(16)                      NULL     COMMENT '所属学院编号（数据域隔离用）',
  status        ENUM('启用','锁定','停用')        NOT NULL DEFAULT '启用' COMMENT '账号状态',
  created_at    DATETIME                         NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (user_id),
  UNIQUE KEY uk_sys_user_username (username),
  KEY idx_sys_user_college (college_id),
  CONSTRAINT fk_sys_user_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='RBAC 系统用户表';

CREATE TABLE IF NOT EXISTS sys_user_role (
  user_id    VARCHAR(32) NOT NULL COMMENT '系统账号主键',
  role_id    VARCHAR(16) NOT NULL COMMENT '角色编号',
  granted_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '授权时间',
  PRIMARY KEY (user_id, role_id),
  KEY idx_sur_role (role_id),
  CONSTRAINT fk_sur_user FOREIGN KEY (user_id)
    REFERENCES sys_user (user_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_sur_role FOREIGN KEY (role_id)
    REFERENCES sys_role (role_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='RBAC 用户-角色关联表';

CREATE TABLE IF NOT EXISTS sys_permission (
  perm_id     VARCHAR(32)                         NOT NULL COMMENT '权限编号',
  perm_code   VARCHAR(64)                         NOT NULL COMMENT '权限标识符（module:action）',
  perm_name   VARCHAR(64)                         NOT NULL COMMENT '权限中文名称',
  module_name VARCHAR(32)                         NOT NULL COMMENT '所属功能模块',
  action_type ENUM('READ','WRITE','APPROVE','STATS') NOT NULL COMMENT '操作类别',
  PRIMARY KEY (perm_id),
  UNIQUE KEY uk_sys_perm_code (perm_code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='RBAC 权限点表';

CREATE TABLE IF NOT EXISTS sys_role_permission (
  role_id VARCHAR(16) NOT NULL COMMENT '角色编号',
  perm_id VARCHAR(32) NOT NULL COMMENT '权限编号',
  PRIMARY KEY (role_id, perm_id),
  KEY idx_srp_perm (perm_id),
  CONSTRAINT fk_srp_role FOREIGN KEY (role_id)
    REFERENCES sys_role (role_id)
    ON UPDATE CASCADE ON DELETE CASCADE,
  CONSTRAINT fk_srp_perm FOREIGN KEY (perm_id)
    REFERENCES sys_permission (perm_id)
    ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='RBAC 角色-权限关联表';

-- 1.1 初始化三角色与最小权限矩阵
INSERT INTO sys_role (role_id, role_code, role_name, description) VALUES
  ('ROLE_ADMIN',   'EDU_ADMIN',   '教务员', '负责全校/学院课程维护、排课、调停课与免听终审及统计分析'),
  ('ROLE_TEACHER', 'EDU_TEACHER', '教师',   '负责个人课表查询、选修名单查看、调课申请与免听初审'),
  ('ROLE_STUDENT', 'EDU_STUDENT', '学生',   '负责个人课表查询、选课/退课及提交免修/免听申请')
ON DUPLICATE KEY UPDATE
  role_name = VALUES(role_name),
  description = VALUES(description);

INSERT INTO sys_user (user_id, username, password_hash, display_name, role_type, ref_id, college_id, status) VALUES
  ('U_ADM01', 'adm_zhang', SHA2('Admin#2026!', 256), '张教务', '教务员', 'ADM01', 'COL01', '启用'),
  ('U_T001',  't_wangjg',  SHA2('Teach#2026!', 256), '王建国', '教师',   'T001',  'COL01', '启用'),
  ('U_T002',  't_limh',    SHA2('Teach#2026!', 256), '李明华', '教师',   'T002',  'COL01', '启用'),
  ('U_S001',  's_2023001', SHA2('Stu#2026!',   256), '张宇轩', '学生',   'S001',  'COL01', '启用'),
  ('U_S011',  's_2024011', SHA2('Stu#2026!',   256), '徐浩宇', '学生',   'S011',  'COL01', '启用')
ON DUPLICATE KEY UPDATE
  display_name = VALUES(display_name),
  status = VALUES(status);

INSERT INTO sys_user_role (user_id, role_id) VALUES
  ('U_ADM01', 'ROLE_ADMIN'),
  ('U_T001',  'ROLE_TEACHER'),
  ('U_T002',  'ROLE_TEACHER'),
  ('U_S001',  'ROLE_STUDENT'),
  ('U_S011',  'ROLE_STUDENT')
ON DUPLICATE KEY UPDATE granted_at = granted_at;

INSERT INTO sys_permission (perm_id, perm_code, perm_name, module_name, action_type) VALUES
  ('P01', 'course:read',              '浏览课程与教学班',       '课程管理', 'READ'),
  ('P02', 'course:write',             '维护课程与开课教学班',   '课程管理', 'WRITE'),
  ('P03', 'schedule:assign',          '教务员排课与冲突核查',   '课程管理', 'WRITE'),
  ('P04', 'schedule:read_all',        '查询全校四类课表',       '课程管理', 'READ'),
  ('P05', 'schedule:read_self',       '查询个人课表',           '课程管理', 'READ'),
  ('P06', 'schedule_change:apply',    '提交调/停课申请',        '课程管理', 'WRITE'),
  ('P07', 'schedule_change:approve',  '审批调/停课申请',        '课程管理', 'APPROVE'),
  ('P08', 'enroll:self',              '学生自主选课/退课',      '课程管理', 'WRITE'),
  ('P09', 'enroll:read_roster',       '查看本人所授选修课名单', '课程管理', 'READ'),
  ('P10', 'exemption:apply',          '提交免修/免听申请',      '课程管理', 'WRITE'),
  ('P11', 'exemption:teacher_review', '任课教师初审免听',       '课程管理', 'APPROVE'),
  ('P12', 'exemption:admin_review',   '教务员终审免修/免听',    '课程管理', 'APPROVE'),
  ('P13', 'stats:course_audit',       '统计全校开课与学院调课', '课程管理', 'STATS')
ON DUPLICATE KEY UPDATE perm_name = VALUES(perm_name);

INSERT INTO sys_role_permission (role_id, perm_id) VALUES
  -- 教务员权限集
  ('ROLE_ADMIN', 'P01'), ('ROLE_ADMIN', 'P02'), ('ROLE_ADMIN', 'P03'),
  ('ROLE_ADMIN', 'P04'), ('ROLE_ADMIN', 'P07'), ('ROLE_ADMIN', 'P12'), ('ROLE_ADMIN', 'P13'),
  -- 教师权限集
  ('ROLE_TEACHER', 'P01'), ('ROLE_TEACHER', 'P05'), ('ROLE_TEACHER', 'P06'),
  ('ROLE_TEACHER', 'P09'), ('ROLE_TEACHER', 'P11'),
  -- 学生权限集
  ('ROLE_STUDENT', 'P01'), ('ROLE_STUDENT', 'P05'), ('ROLE_STUDENT', 'P08'), ('ROLE_STUDENT', 'P10')
ON DUPLICATE KEY UPDATE role_id = role_id;

-- ============================================================================
-- PART 2：三角色安全隔离视图（字段裁剪与隐私脱敏）+ 权限核验
-- ============================================================================

-- 2.1 教务员视角视图：全校教学班开课总览
CREATE OR REPLACE VIEW v_admin_offering_overview AS
SELECT
  co.offering_id,
  co.term_id,
  col.college_id,
  col.college_name,
  c.course_id,
  c.course_name,
  c.course_type,
  c.credit,
  COALESCE(ac.class_name, '跨班/全校选修') AS target_class,
  co.capacity,
  co.enrolled_count,
  (co.capacity - co.enrolled_count) AS remaining_seats,
  co.require_multimedia,
  co.status AS offering_status
FROM course_offering co
JOIN course c ON c.course_id = co.course_id
JOIN college col ON col.college_id = c.college_id
LEFT JOIN admin_class ac ON ac.admin_class_id = co.target_class_id;

-- 2.2 教务员视角视图：全校调/停课审批与统计台账
CREATE OR REPLACE VIEW v_admin_schedule_change_audit AS
SELECT
  sc.change_id,
  sc.term_id,
  col.college_id,
  col.college_name,
  sc.applicant_teacher_id,
  t_app.teacher_name AS applicant_name,
  sc.change_type,
  sc.approval_status,
  sc.orig_classroom_id,
  sc.new_classroom_id,
  sc.orig_teacher_id,
  sc.new_teacher_id,
  sc.reason,
  sc.apply_time,
  sc.reviewer,
  sc.review_time
FROM schedule_change sc
JOIN teacher t_app ON t_app.teacher_id = sc.applicant_teacher_id
JOIN college col ON col.college_id = t_app.college_id;

-- 2.3 教师视角视图：个人授课与排课视图
CREATE OR REPLACE VIEW v_teacher_my_courses AS
SELECT
  cs.teacher_id,
  t.teacher_name,
  cs.term_id,
  co.offering_id,
  c.course_id,
  c.course_name,
  c.course_type,
  co.capacity,
  co.enrolled_count,
  r.classroom_id,
  CONCAT(r.building, '-', r.room_no) AS classroom_location,
  cs.start_week,
  cs.end_week,
  cs.week_type,
  cs.day_of_week,
  cs.start_section,
  cs.end_section,
  cs.schedule_status
FROM course_schedule cs
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN course_offering co ON co.offering_id = cs.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE cs.schedule_status = '正常';

-- 2.4 教师视角视图：选课学生名单（严格裁剪学生家庭情况 family_info、出生日期、手机号等敏感字段）
CREATE OR REPLACE VIEW v_teacher_elective_roster AS
SELECT
  ot.teacher_id,
  ot.teacher_role,
  co.offering_id,
  co.term_id,
  c.course_id,
  c.course_name,
  c.course_type,
  s.student_id,
  s.student_name,
  s.gender,
  s.grade,
  m.major_name,
  ac.class_name,
  e.enroll_time
FROM offering_teacher ot
JOIN course_offering co ON co.offering_id = ot.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN enrollment e ON e.offering_id = co.offering_id AND e.status = '已选'
JOIN student s ON s.student_id = e.student_id
JOIN major m ON m.major_id = s.major_id
JOIN admin_class ac ON ac.admin_class_id = s.admin_class_id;

-- 2.5 学生视角视图：个人课表视图（屏蔽教师年龄/电话及他人学籍隐私）
CREATE OR REPLACE VIEW v_student_timetable AS
SELECT
  e.student_id,
  s.student_name,
  cs.term_id,
  co.offering_id,
  c.course_id,
  c.course_name,
  c.course_type,
  c.credit,
  t.teacher_name,
  t.title AS teacher_title,
  CONCAT(r.building, '-', r.room_no) AS classroom_location,
  cs.start_week,
  cs.end_week,
  cs.week_type,
  cs.day_of_week,
  cs.start_section,
  cs.end_section
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
JOIN course_offering co ON co.offering_id = e.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN course_schedule cs ON cs.offering_id = co.offering_id AND cs.schedule_status = '正常'
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE e.status = '已选';

-- 2.6 学生视角视图：当前可选课程目录视图（含剩余名额与先修课提示）
CREATE OR REPLACE VIEW v_student_available_electives AS
SELECT
  co.offering_id,
  co.term_id,
  c.course_id,
  c.course_name,
  c.course_type,
  c.credit,
  c.prereq_course_id,
  col.college_name,
  co.capacity,
  co.enrolled_count,
  (co.capacity - co.enrolled_count) AS remaining_seats,
  co.status AS offering_status
FROM course_offering co
JOIN course c ON c.course_id = co.course_id
JOIN college col ON col.college_id = c.college_id
WHERE co.status IN ('选课中', '已开课');

-- ----------------------------------------------------------------------------
-- 2.7 MySQL 8 原生 ROLE / GRANT 最小权限授予参考脚本
--     （注：生产环境以 root / 含 CREATE USER 权限账号按需取消注释执行，避免低权限测试账号报错）
-- ----------------------------------------------------------------------------
/*
CREATE ROLE IF NOT EXISTS 'role_edu_admin', 'role_edu_teacher', 'role_edu_student';

-- 教务员：全库业务表读写与核心存储过程执行权
GRANT SELECT, INSERT, UPDATE, DELETE ON edu_system.* TO 'role_edu_admin';
GRANT EXECUTE ON edu_system.* TO 'role_edu_admin';

-- 教师：仅开放教师视图只读、调课申请与免听初审必要接口，禁止直读 student.family_info
GRANT SELECT ON edu_system.v_teacher_my_courses TO 'role_edu_teacher';
GRANT SELECT ON edu_system.v_teacher_elective_roster TO 'role_edu_teacher';
GRANT EXECUTE ON PROCEDURE edu_system.sp_submit_schedule_change TO 'role_edu_teacher';

-- 学生：仅开放个人课表/可选课视图只读及选退课存储过程，严禁直接篡改 enrollment 或 course_offering
GRANT SELECT ON edu_system.v_student_timetable TO 'role_edu_student';
GRANT SELECT ON edu_system.v_student_available_electives TO 'role_edu_student';
GRANT EXECUTE ON PROCEDURE edu_system.sp_enroll_student TO 'role_edu_student';
GRANT EXECUTE ON PROCEDURE edu_system.sp_drop_student TO 'role_edu_student';
FLUSH PRIVILEGES;
*/

-- ----------------------------------------------------------------------------
-- 2.8 RBAC 权限矩阵与视图字段隔离验证查询
-- ----------------------------------------------------------------------------
SELECT '=== [RBAC 验证 1] 三角色权限边界矩阵 ===' AS section_title;

SELECT
  r.role_id,
  r.role_name,
  COUNT(rp.perm_id) AS perm_count,
  GROUP_CONCAT(p.perm_code ORDER BY p.perm_id SEPARATOR ', ') AS granted_permissions
FROM sys_role r
LEFT JOIN sys_role_permission rp ON rp.role_id = r.role_id
LEFT JOIN sys_permission p ON p.perm_id = rp.perm_id
GROUP BY r.role_id, r.role_name
ORDER BY r.role_id;

SELECT '=== [RBAC 验证 2] 视图列级隔离与隐私脱敏检查（INFORMATION_SCHEMA 核验） ===' AS section_title;

SELECT
  TABLE_NAME AS view_name,
  GROUP_CONCAT(COLUMN_NAME ORDER BY ORDINAL_POSITION SEPARATOR ', ') AS exposed_columns,
  SUM(COLUMN_NAME IN ('family_info', 'birth_date', 'phone', 'age', 'password_hash')) AS sensitive_column_leaks
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'edu_system'
  AND TABLE_NAME IN (
    'v_admin_offering_overview',
    'v_admin_schedule_change_audit',
    'v_teacher_my_courses',
    'v_teacher_elective_roster',
    'v_student_timetable',
    'v_student_available_electives'
  )
GROUP BY TABLE_NAME
ORDER BY TABLE_NAME;

SELECT '=== [RBAC 验证 3] 三角色视图实际查询抽样 ===' AS section_title;
SELECT * FROM v_student_timetable WHERE student_id = 'S011' AND term_id = '2026-1' ORDER BY day_of_week, start_section;
SELECT * FROM v_teacher_elective_roster WHERE teacher_id = 'T001' AND offering_id = 'O010' ORDER BY student_id;
SELECT * FROM v_admin_offering_overview WHERE term_id = '2026-1' ORDER BY offering_id LIMIT 6;

-- ============================================================================
-- PART 3：索引设计与大样本 EXPLAIN / EXPLAIN ANALYZE 实测对比
-- ============================================================================

-- 3.1 工具存储过程：按需安全删/建索引（保证脚本可重复执行）
DROP PROCEDURE IF EXISTS sp_drop_index_if_exists;
DROP PROCEDURE IF EXISTS sp_generate_benchmark_data;
DROP PROCEDURE IF EXISTS sp_cleanup_benchmark_data;
DELIMITER $$

CREATE PROCEDURE sp_drop_index_if_exists(
  IN p_table_name VARCHAR(64),
  IN p_index_name VARCHAR(64)
)
BEGIN
  DECLARE v_cnt INT DEFAULT 0;
  SELECT COUNT(*) INTO v_cnt
  FROM INFORMATION_SCHEMA.STATISTICS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = p_table_name
    AND INDEX_NAME = p_index_name;

  IF v_cnt > 0 THEN
    SET @ddl = CONCAT('DROP INDEX `', p_index_name, '` ON `', p_table_name, '`');
    PREPARE stmt FROM @ddl;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END IF;
END$$

-- 3.2 批量压测造数存储过程（完全使用独立 BM-* / BS* / BO* 前缀，与 2026-1 业务数据零冲突）
--     生成规模：
--       - 20 个压测历史学期 (BM-T01 .. BM-T20)
--       - 2,000 名压测学生 (BS0001 .. BS2000)
--       - 100 个压测教学班 (BO0001 .. BO0100，每班容量 500)
--       - 50,000 条真实选课记录 (enrollment)
--       - 12,000 条真实排课记录 (course_schedule)
--       - 30,000 条真实调/停课记录 (schedule_change)
CREATE PROCEDURE sp_generate_benchmark_data()
BEGIN
  SET SESSION cte_max_recursion_depth = 60000;

  START TRANSACTION;

  -- (1) 压测独立行政班与 20 个压测历史学期
  INSERT IGNORE INTO admin_class (admin_class_id, class_name, grade, major_id, college_id, student_count)
  VALUES ('BM_CLS', '压测归档虚拟班', 2020, 'MAJ01', 'COL01', 2000);

  INSERT IGNORE INTO term (term_id, term_name, academic_year, semester_no, start_date, end_date, total_weeks, is_current, status)
  WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20
  )
  SELECT
    CONCAT('BM-T', LPAD(n, 2, '0')),
    CONCAT('压测历史归档学期-', LPAD(n, 2, '0')),
    CONCAT(2005 + FLOOR((n - 1) / 2), '-', 2006 + FLOOR((n - 1) / 2)),
    IF(MOD(n, 2) = 1, 1, 2),
    DATE_ADD('2005-09-01', INTERVAL (n - 1) * 180 DAY),
    DATE_ADD('2005-09-01', INTERVAL (n - 1) * 180 + 130 DAY),
    18, 0, '已结束'
  FROM seq;

  -- (2) 2,000 名压测学生 (BS0001 - BS2000)
  INSERT IGNORE INTO student (
    student_id, student_name, gender, birth_date, grade,
    enrollment_status, is_graduating, family_info,
    admin_class_id, major_id, college_id
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000
  )
  SELECT
    CONCAT('BS', LPAD(n, 4, '0')),
    CONCAT('压测学生', LPAD(n, 4, '0')),
    IF(MOD(n, 2) = 0, '女', '男'),
    '2002-01-01',
    2020,
    '已毕业',
    0,
    '压测合成样本',
    'BM_CLS',
    'MAJ01',
    'COL01'
  FROM seq;

  -- (3) 100 个选课压测教学班 (BO0001 - BO0100，容量 500) + 20 个排课压测教学班 (BSO001 - BSO020，容量 30，不限多媒体)
  INSERT IGNORE INTO course_offering (
    offering_id, course_id, term_id, target_class_id,
    capacity, enrolled_count, require_multimedia, status
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100
  )
  SELECT
    CONCAT('BO', LPAD(n, 4, '0')),
    CONCAT('C', LPAD(MOD(n - 1, 15) + 1, 3, '0')),
    CONCAT('BM-T', LPAD(MOD(n - 1, 20) + 1, 2, '0')),
    NULL,
    500,
    0,
    1,
    '已结课'
  FROM seq;

  INSERT IGNORE INTO course_offering (
    offering_id, course_id, term_id, target_class_id,
    capacity, enrolled_count, require_multimedia, status
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20
  )
  SELECT
    CONCAT('BSO', LPAD(n, 3, '0')),
    CONCAT('C', LPAD(MOD(n - 1, 15) + 1, 3, '0')),
    CONCAT('BM-T', LPAD(n, 2, '0')),
    NULL,
    30,
    0,
    0,
    '已结课'
  FROM seq;

  -- (4) 50,000 条真实选课记录（100 个教学班 × 每班 500 名学生，80% 已选 / 20% 已退）
  INSERT IGNORE INTO enrollment (student_id, offering_id, enroll_time, status, drop_time)
  WITH RECURSIVE seq(n) AS (
    SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 49999
  )
  SELECT
    CONCAT('BS', LPAD(MOD(n, 2000) + 1, 4, '0')) AS student_id,
    CONCAT('BO', LPAD(FLOOR(n / 500) + 1, 4, '0')) AS offering_id,
    DATE_ADD('2026-08-01 08:00:00', INTERVAL MOD(n * 73, 2592000) SECOND) AS enroll_time,
    IF(MOD(n, 5) = 0, '已退', '已选') AS status,
    IF(MOD(n, 5) = 0, DATE_ADD('2026-09-01 09:00:00', INTERVAL MOD(n, 86400) SECOND), NULL) AS drop_time
  FROM seq;

  -- (5) 12,000 条真实排课记录（覆盖 20 个压测学期 × 15 间可用教室，含 600 条“正常”与 11,400 条历史“已调课/已停课”）
  INSERT INTO course_schedule (
    offering_id, term_id, teacher_id, classroom_id,
    start_week, end_week, week_type, day_of_week, start_section, end_section, schedule_status
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 11399
  )
  SELECT
    CONCAT('BSO', LPAD(MOD(n, 20) + 1, 3, '0')),
    CONCAT('BM-T', LPAD(MOD(n, 20) + 1, 2, '0')),
    CONCAT('T', LPAD(MOD(n, 18) + 1, 3, '0')),
    CONCAT('R', LPAD(MOD(n, 15) + 1, 3, '0')),
    1, 16, '全',
    MOD(n, 7) + 1,
    MOD(FLOOR(n / 7), 5) * 2 + 1,
    MOD(FLOOR(n / 7), 5) * 2 + 2,
    IF(MOD(n, 3) = 0, '已停课', '已调课')
  FROM seq;

  -- 额外插入 600 条无冲突“正常”压测排课（每学期 30 条：15 教室 × 每教室 2 个不重叠时段，100% 通过 6 维冲突触发器）
  INSERT INTO course_schedule (
    offering_id, term_id, teacher_id, classroom_id,
    start_week, end_week, week_type, day_of_week, start_section, end_section, schedule_status
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 599
  )
  SELECT
    CONCAT('BSO', LPAD(MOD(n, 20) + 1, 3, '0')),
    CONCAT('BM-T', LPAD(MOD(n, 20) + 1, 2, '0')),
    CONCAT('T', LPAD(MOD(FLOOR(n / 20), 15) + 1, 3, '0')),
    CONCAT('R', LPAD(MOD(FLOOR(n / 20), 15) + 1, 3, '0')),
    1, 16, '全',
    IF(FLOOR(n / 20) < 15, 1, 3),
    IF(FLOOR(n / 20) < 15, 1, 3),
    IF(FLOOR(n / 20) < 15, 2, 4),
    '正常'
  FROM seq;

  -- (6) 30,000 条真实调/停课记录（关联已有正常排课与压测历史学期，用于验证学期+状态+教师聚合索引）
  INSERT INTO schedule_change (
    schedule_id, term_id, applicant_teacher_id, change_type,
    orig_start_week, orig_end_week, orig_week_type, orig_day_of_week, orig_start_section, orig_end_section, orig_classroom_id, orig_teacher_id,
    new_start_week, new_end_week, new_week_type, new_day_of_week, new_start_section, new_end_section, new_classroom_id, new_teacher_id,
    reason, approval_status, apply_time, reviewer, review_time
  )
  WITH RECURSIVE seq(n) AS (
    SELECT 0 UNION ALL SELECT n + 1 FROM seq WHERE n < 29999
  )
  SELECT
    1,
    CONCAT('BM-T', LPAD(MOD(n, 20) + 1, 2, '0')),
    CONCAT('T', LPAD(MOD(n, 18) + 1, 3, '0')),
    IF(MOD(n, 4) = 0, '停课', '调课'),
    1, 16, '全', 1, 1, 2, 'R001', 'T001',
    IF(MOD(n, 4) = 0, NULL, 2),
    IF(MOD(n, 4) = 0, NULL, 16),
    IF(MOD(n, 4) = 0, NULL, '全'),
    IF(MOD(n, 4) = 0, NULL, 5),
    IF(MOD(n, 4) = 0, NULL, 3),
    IF(MOD(n, 4) = 0, NULL, 4),
    IF(MOD(n, 4) = 0, NULL, 'R002'),
    IF(MOD(n, 4) = 0, NULL, 'T002'),
    '压测历史调停课样本',
    ELT(MOD(n, 3) + 1, '已通过', '待审核', '已驳回'),
    DATE_ADD('2026-08-01 08:00:00', INTERVAL MOD(n * 41, 2592000) SECOND),
    IF(MOD(n, 3) = 1, NULL, 'ADM01'),
    IF(MOD(n, 3) = 1, NULL, DATE_ADD('2026-08-02 10:00:00', INTERVAL MOD(n * 41, 2592000) SECOND))
  FROM seq;

  COMMIT;
END$$

-- 3.3 清理压测合成数据（保留 01_base/02_course 正常业务数据、RBAC 表、视图与全部复合索引）
CREATE PROCEDURE sp_cleanup_benchmark_data()
BEGIN
  START TRANSACTION;
  DELETE FROM schedule_change WHERE term_id LIKE 'BM-T%';
  DELETE FROM course_schedule WHERE term_id LIKE 'BM-T%';
  DELETE FROM enrollment WHERE offering_id LIKE 'BO%' OR offering_id LIKE 'BSO%';
  DELETE FROM course_offering WHERE offering_id LIKE 'BO%' OR offering_id LIKE 'BSO%';
  DELETE FROM student WHERE student_id LIKE 'BS%';
  DELETE FROM admin_class WHERE admin_class_id = 'BM_CLS';
  DELETE FROM term WHERE term_id LIKE 'BM-T%';
  COMMIT;
END$$
DELIMITER ;

-- 3.4 确保优化前不含有待测复合索引（支持重复跑基准对比）
CALL sp_drop_index_if_exists('enrollment',      'idx_enroll_off_status_time');
CALL sp_drop_index_if_exists('enrollment',      'idx_enroll_status_time_off');
CALL sp_drop_index_if_exists('course_schedule', 'idx_sched_term_room_status_time');
CALL sp_drop_index_if_exists('course_schedule', 'idx_sched_term_teacher_status_time');
CALL sp_drop_index_if_exists('schedule_change', 'idx_sc_term_status_teacher_type');

-- 3.5 先清理可能残留的压测样本，再重新生成标准大样本并刷新统计信息
CALL sp_cleanup_benchmark_data();
CALL sp_generate_benchmark_data();
ANALYZE TABLE enrollment, course_schedule, schedule_change;

SELECT '=== [压测样本规模确认] ===' AS section_title;
SELECT 'enrollment' AS table_name, COUNT(*) AS total_rows FROM enrollment
UNION ALL SELECT 'course_schedule', COUNT(*) FROM course_schedule
UNION ALL SELECT 'schedule_change', COUNT(*) FROM schedule_change;

-- ----------------------------------------------------------------------------
-- 3.6 【优化前 BEFORE】EXPLAIN 与 EXPLAIN ANALYZE 基准实测
-- ----------------------------------------------------------------------------
SELECT '=== [BEFORE Q1] 某教学班有效选课名单按时间倒序分页（优化前） ===' AS section_title;
EXPLAIN
SELECT e.student_id, s.student_name, e.enroll_time
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
WHERE e.offering_id = 'BO0015' AND e.status = '已选'
ORDER BY e.enroll_time DESC
LIMIT 50;

EXPLAIN ANALYZE
SELECT e.student_id, s.student_name, e.enroll_time
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
WHERE e.offering_id = 'BO0015' AND e.status = '已选'
ORDER BY e.enroll_time DESC
LIMIT 50;

SELECT '=== [BEFORE Q2] 全校某时间窗口内有效选课各教学班热度统计（优化前） ===' AS section_title;
EXPLAIN
SELECT offering_id, COUNT(*) AS active_cnt
FROM enrollment
WHERE status = '已选' AND enroll_time >= '2026-08-25 00:00:00'
GROUP BY offering_id;

EXPLAIN ANALYZE
SELECT offering_id, COUNT(*) AS active_cnt
FROM enrollment
WHERE status = '已选' AND enroll_time >= '2026-08-25 00:00:00'
GROUP BY offering_id;

SELECT '=== [BEFORE Q3] 某学期某教室正常排课有序查询（优化前） ===' AS section_title;
EXPLAIN
SELECT schedule_id, offering_id, teacher_id, start_week, end_week, day_of_week, start_section, end_section
FROM course_schedule
WHERE term_id = 'BM-T01' AND classroom_id = 'R001' AND schedule_status = '正常'
ORDER BY day_of_week, start_section;

EXPLAIN ANALYZE
SELECT schedule_id, offering_id, teacher_id, start_week, end_week, day_of_week, start_section, end_section
FROM course_schedule
WHERE term_id = 'BM-T01' AND classroom_id = 'R001' AND schedule_status = '正常'
ORDER BY day_of_week, start_section;

SELECT '=== [BEFORE Q4] 某学期已通过调/停课按教师分组统计（优化前） ===' AS section_title;
EXPLAIN
SELECT applicant_teacher_id, COUNT(*) AS total_cnt, SUM(change_type = '调课') AS adjust_cnt
FROM schedule_change
WHERE term_id = 'BM-T01' AND approval_status = '已通过'
GROUP BY applicant_teacher_id;

EXPLAIN ANALYZE
SELECT applicant_teacher_id, COUNT(*) AS total_cnt, SUM(change_type = '调课') AS adjust_cnt
FROM schedule_change
WHERE term_id = 'BM-T01' AND approval_status = '已通过'
GROUP BY applicant_teacher_id;

-- ----------------------------------------------------------------------------
-- 3.7 落地 5 个针对高频查询与覆盖索引设计的复合索引
-- ----------------------------------------------------------------------------
CREATE INDEX idx_enroll_off_status_time
  ON enrollment (offering_id, status, enroll_time DESC, student_id);

CREATE INDEX idx_enroll_status_time_off
  ON enrollment (status, enroll_time, offering_id);

CREATE INDEX idx_sched_term_room_status_time
  ON course_schedule (term_id, classroom_id, schedule_status, day_of_week, start_section);

CREATE INDEX idx_sched_term_teacher_status_time
  ON course_schedule (term_id, teacher_id, schedule_status, day_of_week, start_section);

CREATE INDEX idx_sc_term_status_teacher_type
  ON schedule_change (term_id, approval_status, applicant_teacher_id, change_type);

ANALYZE TABLE enrollment, course_schedule, schedule_change;

-- ----------------------------------------------------------------------------
-- 3.8 【优化后 AFTER】EXPLAIN 与 EXPLAIN ANALYZE 实测对比
-- ----------------------------------------------------------------------------
SELECT '=== [AFTER Q1] 某教学班有效选课名单按时间倒序分页（优化后） ===' AS section_title;
EXPLAIN
SELECT e.student_id, s.student_name, e.enroll_time
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
WHERE e.offering_id = 'BO0015' AND e.status = '已选'
ORDER BY e.enroll_time DESC
LIMIT 50;

EXPLAIN ANALYZE
SELECT e.student_id, s.student_name, e.enroll_time
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
WHERE e.offering_id = 'BO0015' AND e.status = '已选'
ORDER BY e.enroll_time DESC
LIMIT 50;

SELECT '=== [AFTER Q2] 全校某时间窗口内有效选课各教学班热度统计（优化后） ===' AS section_title;
EXPLAIN
SELECT offering_id, COUNT(*) AS active_cnt
FROM enrollment
WHERE status = '已选' AND enroll_time >= '2026-08-25 00:00:00'
GROUP BY offering_id;

EXPLAIN ANALYZE
SELECT offering_id, COUNT(*) AS active_cnt
FROM enrollment
WHERE status = '已选' AND enroll_time >= '2026-08-25 00:00:00'
GROUP BY offering_id;

SELECT '=== [AFTER Q3] 某学期某教室正常排课有序查询（优化后） ===' AS section_title;
EXPLAIN
SELECT schedule_id, offering_id, teacher_id, start_week, end_week, day_of_week, start_section, end_section
FROM course_schedule
WHERE term_id = 'BM-T01' AND classroom_id = 'R001' AND schedule_status = '正常'
ORDER BY day_of_week, start_section;

EXPLAIN ANALYZE
SELECT schedule_id, offering_id, teacher_id, start_week, end_week, day_of_week, start_section, end_section
FROM course_schedule
WHERE term_id = 'BM-T01' AND classroom_id = 'R001' AND schedule_status = '正常'
ORDER BY day_of_week, start_section;

SELECT '=== [AFTER Q4] 某学期已通过调/停课按教师分组统计（优化后） ===' AS section_title;
EXPLAIN
SELECT applicant_teacher_id, COUNT(*) AS total_cnt, SUM(change_type = '调课') AS adjust_cnt
FROM schedule_change
WHERE term_id = 'BM-T01' AND approval_status = '已通过'
GROUP BY applicant_teacher_id;

EXPLAIN ANALYZE
SELECT applicant_teacher_id, COUNT(*) AS total_cnt, SUM(change_type = '调课') AS adjust_cnt
FROM schedule_change
WHERE term_id = 'BM-T01' AND approval_status = '已通过'
GROUP BY applicant_teacher_id;

-- ----------------------------------------------------------------------------
-- 3.9 清理压测合成样本，恢复洁净教学业务库状态（永久保留 RBAC 表、6 个视图与 5 个复合索引）
-- ----------------------------------------------------------------------------
CALL sp_cleanup_benchmark_data();
ANALYZE TABLE enrollment, course_schedule, schedule_change;

SELECT '=== [收尾核验] 清理压测样本后的洁净库行数 ===' AS section_title;
SELECT 'student' AS table_name, COUNT(*) AS clean_rows FROM student
UNION ALL SELECT 'course_offering', COUNT(*) FROM course_offering
UNION ALL SELECT 'course_schedule', COUNT(*) FROM course_schedule
UNION ALL SELECT 'enrollment', COUNT(*) FROM enrollment
UNION ALL SELECT 'schedule_change', COUNT(*) FROM schedule_change;
