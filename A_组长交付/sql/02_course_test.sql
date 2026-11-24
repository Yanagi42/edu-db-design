-- ============================================================================
-- 文件名：02_course_test.sql
-- 负责成员：A（组长）
-- 依赖：按顺序执行 01_base_ddl -> 01_base_seed -> 02_course_ddl -> 02_course_seed 后运行
-- 说明：完整覆盖《数据库测试业务.xlsx》课程管理模块全部 12 项参考测试（含第 12 项可选事务回滚）。
--       异常拦截与事务回滚用例通过测试包装过程捕获数据库触发器/存储过程抛出的真实 SQLSTATE 45000 错误，
--       确保整套脚本既能无中断一键执行，又能完整输出每项拦截的真实数据库报错信息与零脏数据验证。
-- ============================================================================

SET NAMES utf8mb4;
USE edu_system;

-- ----------------------------------------------------------------------------
-- 辅助测试包装过程：捕获真实触发器/存储过程异常，便于自动化一键运行并展示精确报错信息
-- （脚本末尾自动清理此临时测试过程，不污染正式库对象）
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_test_try_schedule;
DROP PROCEDURE IF EXISTS sp_test_try_enroll;
DROP PROCEDURE IF EXISTS sp_test_tx_rollback_demo;
DELIMITER $$

CREATE PROCEDURE sp_test_try_schedule(
  IN p_case_label    VARCHAR(80),
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
  DECLARE v_err_no   INT DEFAULT 0;
  DECLARE v_err_msg  VARCHAR(255) DEFAULT '无异常（写入成功）';
  DECLARE v_before   INT DEFAULT 0;
  DECLARE v_after    INT DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err_no = MYSQL_ERRNO, v_err_msg = MESSAGE_TEXT;
  END;

  SELECT COUNT(*) INTO v_before FROM course_schedule;
  CALL sp_assign_schedule(
    p_offering_id, p_teacher_id, p_classroom_id,
    p_start_week, p_end_week, p_week_type,
    p_day_of_week, p_start_section, p_end_section
  );
  SELECT COUNT(*) INTO v_after FROM course_schedule;

  SELECT
    p_case_label AS test_case,
    IF(v_err_no > 0, '已被数据库拦截', '允许写入') AS actual_outcome,
    v_err_no AS mysql_errno,
    v_err_msg AS db_message,
    v_before AS rows_before,
    v_after AS rows_after;
END$$

CREATE PROCEDURE sp_test_try_enroll(
  IN p_case_label  VARCHAR(80),
  IN p_student_id  VARCHAR(16),
  IN p_offering_id VARCHAR(16)
)
BEGIN
  DECLARE v_err_no   INT DEFAULT 0;
  DECLARE v_err_msg  VARCHAR(255) DEFAULT '无异常（选课成功）';
  DECLARE v_cap      SMALLINT UNSIGNED DEFAULT 0;
  DECLARE v_before   SMALLINT UNSIGNED DEFAULT 0;
  DECLARE v_after    SMALLINT UNSIGNED DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err_no = MYSQL_ERRNO, v_err_msg = MESSAGE_TEXT;
  END;

  SELECT capacity, enrolled_count INTO v_cap, v_before
  FROM course_offering WHERE offering_id = p_offering_id;

  CALL sp_enroll_student(p_student_id, p_offering_id);

  SELECT enrolled_count INTO v_after
  FROM course_offering WHERE offering_id = p_offering_id;

  SELECT
    p_case_label AS test_case,
    p_student_id AS student_id,
    p_offering_id AS offering_id,
    IF(v_err_no > 0, '已被数据库拦截', '选课成功') AS actual_outcome,
    v_err_no AS mysql_errno,
    v_err_msg AS db_message,
    v_cap AS capacity,
    v_before AS enrolled_before,
    v_after AS enrolled_after;
END$$

CREATE PROCEDURE sp_test_tx_rollback_demo()
BEGIN
  DECLARE v_err_no       INT DEFAULT 0;
  DECLARE v_err_msg      VARCHAR(255) DEFAULT '';
  DECLARE v_before_cnt   INT DEFAULT 0;
  DECLARE v_mid_tx_cnt   INT DEFAULT 0;
  DECLARE v_after_cnt    INT DEFAULT 0;
  DECLARE v_dirty_slot1  INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_err_no = MYSQL_ERRNO, v_err_msg = MESSAGE_TEXT;
    ROLLBACK;
    SELECT COUNT(*) INTO v_after_cnt FROM course_schedule WHERE offering_id = 'O012';
    SELECT COUNT(*) INTO v_dirty_slot1
    FROM course_schedule
    WHERE offering_id = 'O012' AND day_of_week = 5 AND start_section = 3 AND classroom_id = 'R008';

    SELECT
      '测试项12：排课双时段原子事务失败回滚演示' AS test_case,
      v_before_cnt AS before_tx_count,
      v_mid_tx_cnt AS mid_tx_after_step1_count,
      v_err_no AS step2_error_no,
      v_err_msg AS step2_conflict_error,
      v_after_cnt AS after_rollback_count,
      v_dirty_slot1 AS step1_dirty_rows_remaining,
      IF(v_after_cnt = v_before_cnt AND v_dirty_slot1 = 0, 'PASS（整笔事务已原子回滚，零脏数据）', 'FAIL') AS verification_result;
  END;

  SELECT COUNT(*) INTO v_before_cnt FROM course_schedule WHERE offering_id = 'O012';

  START TRANSACTION;
    -- 步骤 1：合法写入 O012 第 1 个新时段（周五 3-4 节 R008，无任何冲突）
    INSERT INTO course_schedule (
      offering_id, term_id, teacher_id, classroom_id,
      start_week, end_week, week_type, day_of_week, start_section, end_section, schedule_status
    ) VALUES (
      'O012', '2026-1', 'T006', 'R008', 1, 16, '全', 5, 3, 4, '正常'
    );
    -- 验证事务内部第 1 条记录确实已写入（数量 +1）
    SELECT COUNT(*) INTO v_mid_tx_cnt FROM course_schedule WHERE offering_id = 'O012';

    -- 步骤 2：模拟同一排课事务的第 2 个时段冲突（R001 周一 1-2 节已被 O007 占用）-> 触发异常并整笔 ROLLBACK
    INSERT INTO course_schedule (
      offering_id, term_id, teacher_id, classroom_id,
      start_week, end_week, week_type, day_of_week, start_section, end_section, schedule_status
    ) VALUES (
      'O012', '2026-1', 'T006', 'R001', 1, 16, '全', 1, 1, 2, '正常'
    );
  COMMIT;
END$$
DELIMITER ;

-- ============================================================================
-- 【测试项 1】教师调课（含原/目标周次、节次、地点、教师，审批通过同步生效）
-- ============================================================================
SELECT '=== [测试项 1] 教师调课申请与审批同步更新排课 ===' AS section_title;

-- 1.1 调课前：查看 schedule_id = 7 (O010 分布式系统导论) 的原排课信息
SELECT
  cs.schedule_id, cs.offering_id, c.course_name, cs.term_id,
  cs.teacher_id, t.teacher_name, cs.classroom_id, CONCAT(r.building, r.room_no) AS room_loc,
  CONCAT('第', cs.start_week, '-', cs.end_week, '周(', cs.week_type, ') 周', cs.day_of_week, ' 第', cs.start_section, '-', cs.end_section, '节') AS time_slot
FROM course_schedule cs
JOIN course_offering co ON co.offering_id = cs.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE cs.schedule_id = 7;

-- 1.2 教师 T001 提交调课申请：调整周次(2-16)、节次(周五1-2节)、教室(R008)、代课教师(T002)
SET @new_change_id = 0;
CALL sp_submit_schedule_change(
  7, 'T001', '调课',
  2, 16, '全', 5, 1, 2, 'R008', 'T002',
  '参加国际数据库学术会议出差，申请调至周五1-2节教二楼205并由李明华副教授合讲代课',
  @new_change_id
);

-- 1.3 查看提交后的调课申请单（完整展示原/目标周次、节次、地点、教师）
SELECT
  sc.change_id, sc.schedule_id, sc.change_type, sc.approval_status,
  CONCAT('第', sc.orig_start_week, '-', sc.orig_end_week, '周(', sc.orig_week_type, ') 周', sc.orig_day_of_week, ' ', sc.orig_start_section, '-', sc.orig_end_section, '节 / ', sc.orig_classroom_id, ' / ', sc.orig_teacher_id) AS original_plan,
  CONCAT('第', sc.new_start_week, '-', sc.new_end_week, '周(', sc.new_week_type, ') 周', sc.new_day_of_week, ' ', sc.new_start_section, '-', sc.new_end_section, '节 / ', sc.new_classroom_id, ' / ', sc.new_teacher_id) AS target_plan,
  sc.reason
FROM schedule_change sc
WHERE sc.change_id = @new_change_id;

-- 1.4 教务员 ADM01 审批通过：原子更新审批状态、排课表并补录合讲教师
CALL sp_approve_schedule_change(@new_change_id, '已通过', 'ADM01', '已核验目标教室、教师与学生课表无冲突，批准调课');

-- 1.5 调课后核验：审批状态已更新且 course_schedule 已同步生效
SELECT
  sc.change_id, sc.approval_status, sc.reviewer, sc.review_time, sc.review_comment,
  cs.schedule_id, cs.teacher_id AS current_teacher, t.teacher_name,
  cs.classroom_id AS current_room, CONCAT(r.building, r.room_no) AS current_loc,
  CONCAT('第', cs.start_week, '-', cs.end_week, '周(', cs.week_type, ') 周', cs.day_of_week, ' 第', cs.start_section, '-', cs.end_section, '节') AS current_time_slot
FROM schedule_change sc
JOIN course_schedule cs ON cs.schedule_id = sc.schedule_id
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE sc.change_id = @new_change_id;

-- ============================================================================
-- 【测试项 2】查询某学生某学期课表（学生 S011，2026-1 学期）
-- ============================================================================
SELECT '=== [测试项 2] 查询学生 S011 在 2026-1 学期的个人课表 ===' AS section_title;

SELECT
  s.student_id, s.student_name, cs.term_id,
  c.course_id, c.course_name, c.course_type, c.credit,
  t.teacher_name, CONCAT(r.building, '-', r.room_no) AS classroom_location,
  cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section
FROM enrollment e
JOIN student s ON s.student_id = e.student_id
JOIN course_offering co ON co.offering_id = e.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN course_schedule cs ON cs.offering_id = co.offering_id AND cs.schedule_status = '正常'
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE e.student_id = 'S011'
  AND e.status = '已选'
  AND cs.term_id = '2026-1'
ORDER BY cs.day_of_week, cs.start_section, cs.start_week;

-- ============================================================================
-- 【测试项 3】查询某教师某学期课表（教师 T002，2026-1 学期，包含刚调入代授的 O010）
-- ============================================================================
SELECT '=== [测试项 3] 查询教师 T002 在 2026-1 学期的授课课表 ===' AS section_title;

SELECT
  t.teacher_id, t.teacher_name, t.title, cs.term_id,
  co.offering_id, c.course_id, c.course_name,
  COALESCE(ac.class_name, '全校/专业选修') AS target_class,
  CONCAT(r.building, '-', r.room_no) AS classroom_location,
  cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section
FROM course_schedule cs
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN course_offering co ON co.offering_id = cs.offering_id
JOIN course c ON c.course_id = co.course_id
LEFT JOIN admin_class ac ON ac.admin_class_id = co.target_class_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE cs.teacher_id = 'T002'
  AND cs.term_id = '2026-1'
  AND cs.schedule_status = '正常'
ORDER BY cs.day_of_week, cs.start_section;

-- ============================================================================
-- 【测试项 4】查询某班级某学期课表（班级 CLS02 计科2024-1班，2026-1 学期）
-- ============================================================================
SELECT '=== [测试项 4] 查询行政班级 CLS02 在 2026-1 学期的班级课表 ===' AS section_title;

SELECT
  ac.admin_class_id, ac.class_name, cs.term_id,
  co.offering_id, c.course_id, c.course_name, c.credit,
  t.teacher_name, CONCAT(r.building, '-', r.room_no) AS classroom_location,
  cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section
FROM course_offering co
JOIN admin_class ac ON ac.admin_class_id = co.target_class_id
JOIN course c ON c.course_id = co.course_id
JOIN course_schedule cs ON cs.offering_id = co.offering_id AND cs.schedule_status = '正常'
JOIN teacher t ON t.teacher_id = cs.teacher_id
JOIN classroom r ON r.classroom_id = cs.classroom_id
WHERE co.target_class_id = 'CLS02'
  AND cs.term_id = '2026-1'
ORDER BY cs.day_of_week, cs.start_section;

-- ============================================================================
-- 【测试项 5】查询某教室某学期课表（教室 R001 教三楼301，2026-1 学期）
-- ============================================================================
SELECT '=== [测试项 5] 查询教室 R001 在 2026-1 学期的教室课表 ===' AS section_title;

SELECT
  r.classroom_id, CONCAT(r.building, '-', r.room_no) AS classroom_location,
  r.capacity, r.is_multimedia, cs.term_id,
  co.offering_id, c.course_name, t.teacher_name,
  cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section
FROM course_schedule cs
JOIN classroom r ON r.classroom_id = cs.classroom_id
JOIN course_offering co ON co.offering_id = cs.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN teacher t ON t.teacher_id = cs.teacher_id
WHERE cs.classroom_id = 'R001'
  AND cs.term_id = '2026-1'
  AND cs.schedule_status = '正常'
ORDER BY cs.day_of_week, cs.start_section;

-- ============================================================================
-- 【测试项 6】教师查询自己开设的某门选修课选课学生名单（教师 T001，选修班 O010）
-- ============================================================================
SELECT '=== [测试项 6] 教师 T001 查询所开选修课 O010（分布式系统导论）选课名单 ===' AS section_title;

SELECT
  ot.teacher_id, t.teacher_name, ot.teacher_role,
  co.offering_id, c.course_name, c.course_type,
  s.student_id, s.student_name, s.gender, s.grade,
  m.major_name, ac.class_name, e.enroll_time
FROM offering_teacher ot
JOIN teacher t ON t.teacher_id = ot.teacher_id
JOIN course_offering co ON co.offering_id = ot.offering_id
JOIN course c ON c.course_id = co.course_id
JOIN enrollment e ON e.offering_id = co.offering_id AND e.status = '已选'
JOIN student s ON s.student_id = e.student_id
JOIN major m ON m.major_id = s.major_id
JOIN admin_class ac ON ac.admin_class_id = s.admin_class_id
WHERE ot.teacher_id = 'T001'
  AND co.offering_id = 'O010'
  AND c.course_type IN ('专业选修','公选')
ORDER BY s.student_id;

-- ============================================================================
-- 【测试项 7】教务员排课（合法插入 + 校验教室容量/多媒体/教师/班级学生多维冲突）
-- ============================================================================
SELECT '=== [测试项 7] 教务员排课合法插入与多维冲突校验 ===' AS section_title;

-- 7a. 合法排课：为 O012(大数据存储与计算，容量50，需多媒体) 安排 T006、R004(容量60，多媒体)、周四5-6节
CALL sp_test_try_schedule('7a-合法排课(O012/T006/R004/周四5-6节)', 'O012', 'T006', 'R004', 1, 16, '全', 4, 5, 6);

-- 7b. 教室容量不足拦截：O012(容量50) 试图排入 R007(容量30，支持多媒体)
CALL sp_test_try_schedule('7b-教室容量不足拦截(R007容量30<50)', 'O012', 'T006', 'R007', 1, 16, '全', 4, 1, 2);

-- 7c. 多媒体性质不匹配拦截：O012(要求多媒体) 试图排入 R006(容量100但非多媒体)
CALL sp_test_try_schedule('7c-非多媒体教室拦截(R006不支持多媒体)', 'O012', 'T006', 'R006', 1, 16, '全', 3, 1, 2);

-- 7d. 教师时间冲突拦截：T006 在周四5-6节已排课，试图同时间排入空闲教室 R008
CALL sp_test_try_schedule('7d-教师时间冲突拦截(T006周四5-6节冲突)', 'O012', 'T006', 'R008', 1, 16, '全', 4, 5, 6);

-- 7e. 行政班级学生时间冲突拦截：CLS02 周一1-2节已有 O007，试图把 O008(同属CLS02)也排在周一1-2节
CALL sp_test_try_schedule('7e-班级学生时间冲突拦截(CLS02周一1-2节冲突)', 'O008', 'T006', 'R008', 1, 16, '全', 1, 1, 2);

-- 7f. 教室状态维修中拦截：R016 处于维修中状态
CALL sp_test_try_schedule('7f-维修中教室拦截(R016维修中)', 'O012', 'T006', 'R016', 1, 16, '全', 5, 1, 2);

-- 核验 O012 仅写入 7a 的 1 条合法排课记录
SELECT
  cs.schedule_id, cs.offering_id, c.course_name, cs.teacher_id, cs.classroom_id,
  cs.start_week, cs.end_week, cs.week_type, cs.day_of_week, cs.start_section, cs.end_section
FROM course_schedule cs
JOIN course_offering co ON co.offering_id = cs.offering_id
JOIN course c ON c.course_id = co.course_id
WHERE cs.offering_id = 'O012';

-- ============================================================================
-- 【测试项 8】教务员统计本学期（2026-1）所有课程开课情况
-- ============================================================================
SELECT '=== [测试项 8] 教务员统计 2026-1 学期全校课程开课情况 ===' AS section_title;

WITH course_teachers AS (
  SELECT
    co.course_id,
    GROUP_CONCAT(DISTINCT t.teacher_name ORDER BY t.teacher_id SEPARATOR '、') AS teachers
  FROM course_offering co
  JOIN offering_teacher ot ON ot.offering_id = co.offering_id
  JOIN teacher t ON t.teacher_id = ot.teacher_id
  WHERE co.term_id = '2026-1'
  GROUP BY co.course_id
),
offering_schedules AS (
  SELECT
    offering_id,
    COUNT(*) AS active_slot_cnt
  FROM course_schedule
  WHERE term_id = '2026-1' AND schedule_status = '正常'
  GROUP BY offering_id
)
SELECT
  col.college_name,
  c.course_id,
  c.course_name,
  c.course_type,
  c.credit,
  COUNT(co.offering_id) AS offering_count,
  SUM(co.capacity) AS total_capacity,
  SUM(co.enrolled_count) AS total_enrolled,
  CONCAT(ROUND(SUM(co.enrolled_count) * 100.0 / NULLIF(SUM(co.capacity), 0), 1), '%') AS fill_rate,
  COALESCE(SUM(os.active_slot_cnt), 0) AS active_schedule_slots,
  COALESCE(ct.teachers, '') AS teachers
FROM course_offering co
JOIN course c ON c.course_id = co.course_id
JOIN college col ON col.college_id = c.college_id
LEFT JOIN offering_schedules os ON os.offering_id = co.offering_id
LEFT JOIN course_teachers ct ON ct.course_id = c.course_id
WHERE co.term_id = '2026-1'
GROUP BY col.college_name, c.course_id, c.course_name, c.course_type, c.credit, ct.teachers
ORDER BY col.college_name, c.course_id;

-- ============================================================================
-- 【测试项 9】学生选修某学期选修课（合法选课 + 超容量拦截 + 先修课与冲突校验）
-- ============================================================================
SELECT '=== [测试项 9] 学生选修课程（合法选课 + 超容量/先修/时间冲突拦截） ===' AS section_title;

-- 9a. 合法选课：S007(已修先修课 C004，时间无冲突) 选修 O010(分布式系统导论)，enrolled_count 应由 6 变为 7
CALL sp_test_try_enroll('9a-合法选课(S007选O010)', 'S007', 'O010');

-- 9b. 超容量拦截：O011(云原生，容量=3，已选=3) 拒绝 S004 选课
CALL sp_test_try_enroll('9b-超容量拦截(S004选已满班O011)', 'S004', 'O011');

-- 9c. 先修课未完成拦截：S071(信管2025级，未修 C004) 试图选修 O010(C006，要求先修 C004)
CALL sp_test_try_enroll('9c-先修课不足拦截(S071未修C004选O010)', 'S071', 'O010');

-- 9d. 学生课表时间冲突拦截：S011 周一1-2节已有 O007，试图选修同时间段的 O015
CALL sp_test_try_enroll('9d-学生课表时间冲突拦截(S011选周一1-2节O015)', 'S011', 'O015');

-- 核验 O010 与 O011 的反范式已选人数与明细计数完全一致
SELECT
  co.offering_id, c.course_name, co.capacity, co.enrolled_count,
  (SELECT COUNT(*) FROM enrollment e WHERE e.offering_id = co.offering_id AND e.status = '已选') AS verified_actual_cnt
FROM course_offering co
JOIN course c ON c.course_id = co.course_id
WHERE co.offering_id IN ('O010', 'O011');

-- ============================================================================
-- 【测试项 10】教务员统计某学院所有教师某学期调课情况（COL01 计算机学院，2026-1 学期）
-- ============================================================================
SELECT '=== [测试项 10] 教务员统计 COL01（计算机学院）全体教师 2026-1 学期调课情况 ===' AS section_title;

-- 10.1 学院教师汇总表（包含 0 调课教师，便于学院全员排查）
SELECT
  col.college_name,
  t.teacher_id,
  t.teacher_name,
  t.title,
  COUNT(sc.change_id) AS total_requests,
  SUM(CASE WHEN sc.change_type = '调课' THEN 1 ELSE 0 END) AS adjust_count,
  SUM(CASE WHEN sc.change_type = '停课' THEN 1 ELSE 0 END) AS suspend_count,
  SUM(CASE WHEN sc.approval_status = '已通过' THEN 1 ELSE 0 END) AS approved_count,
  SUM(CASE WHEN sc.approval_status = '待审核' THEN 1 ELSE 0 END) AS pending_count,
  SUM(CASE WHEN sc.approval_status = '已驳回' THEN 1 ELSE 0 END) AS rejected_count
FROM teacher t
JOIN college col ON col.college_id = t.college_id
LEFT JOIN schedule_change sc
  ON sc.applicant_teacher_id = t.teacher_id
 AND sc.term_id = '2026-1'
WHERE t.college_id = 'COL01'
GROUP BY col.college_name, t.teacher_id, t.teacher_name, t.title
ORDER BY total_requests DESC, t.teacher_id;

-- 10.2 COL01 调/停课明细清单
SELECT
  sc.change_id, t.teacher_id, t.teacher_name, sc.change_type, sc.approval_status,
  sc.orig_classroom_id, sc.new_classroom_id, sc.reason, sc.apply_time
FROM schedule_change sc
JOIN teacher t ON t.teacher_id = sc.applicant_teacher_id
WHERE t.college_id = 'COL01'
  AND sc.term_id = '2026-1'
ORDER BY sc.apply_time;

-- ============================================================================
-- 【测试项 11】异常拦截：新增排课记录与同时间教室已有课程冲突
-- ============================================================================
SELECT '=== [测试项 11] 异常拦截：新增排课记录与同时间教室已有课程冲突 ===' AS section_title;

-- 试图将 O012 排入 R001（周一1-2节，第1-16周全），该教室同时段已被 O007 占用
-- 等价独立失败语句参考：
-- INSERT INTO course_schedule(offering_id,term_id,teacher_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section)
-- VALUES('O012','2026-1','T006','R001',1,16,'全',1,1,2);
CALL sp_test_try_schedule('测试项11-同时间教室冲突拦截(R001周一1-2节已被O007占用)', 'O012', 'T006', 'R001', 1, 16, '全', 1, 1, 2);

-- 确认 R001 周一1-2节仅有原本的 O007 一条正常排课记录
SELECT schedule_id, offering_id, teacher_id, classroom_id, start_week, end_week, day_of_week, start_section, end_section
FROM course_schedule
WHERE term_id = '2026-1' AND classroom_id = 'R001' AND day_of_week = 1 AND start_section = 1;

-- ============================================================================
-- 【测试项 12（可选加分项）】模拟排课事务失败场景与回滚零脏数据验证
-- ============================================================================
SELECT '=== [测试项 12] 可选加分项：排课事务部分写入后遇冲突触发 ROLLBACK 验证 ===' AS section_title;

CALL sp_test_tx_rollback_demo();

-- 清理临时测试包装过程，保持正式库对象整洁
DROP PROCEDURE IF EXISTS sp_test_try_schedule;
DROP PROCEDURE IF EXISTS sp_test_try_enroll;
DROP PROCEDURE IF EXISTS sp_test_tx_rollback_demo;
