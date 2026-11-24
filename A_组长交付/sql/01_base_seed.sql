-- ============================================================================
-- 文件名：01_base_seed.sql
-- 负责成员：A（组长）
-- 说明：公共底座幂等造数脚本（含存储过程批量生成学生基础数据）
--       提供 3 个学期、4 个学院、5 个专业、8 个行政班级、18 名教师、16 间教室、80 名学生。
--       主键 ID 采用可读编码（COL01/MAJ01/CLS01/S001/T001/R001/2026-1），便于 B/C/D/E 直接引用。
-- ============================================================================

SET NAMES utf8mb4;
USE edu_system;

-- ----------------------------------------------------------------------------
-- 1. 学期数据 (term)：覆盖历史已结课学期与当前活跃学期
-- ----------------------------------------------------------------------------
INSERT INTO term (term_id, term_name, academic_year, semester_no, start_date, end_date, total_weeks, is_current, status) VALUES
  ('2025-1', '2025-2026学年第一学期', '2025-2026', 1, '2025-09-01', '2026-01-16', 18, 0, '已结束'),
  ('2025-2', '2025-2026学年第二学期', '2025-2026', 2, '2026-02-23', '2026-07-05', 18, 0, '已结束'),
  ('2026-1', '2026-2027学年第一学期', '2026-2027', 1, '2026-09-07', '2027-01-22', 18, 1, '进行中')
ON DUPLICATE KEY UPDATE
  term_name = VALUES(term_name),
  is_current = VALUES(is_current),
  status = VALUES(status);

-- ----------------------------------------------------------------------------
-- 2. 学院数据 (college)
-- ----------------------------------------------------------------------------
INSERT INTO college (college_id, college_name, office_location, contact_phone) VALUES
  ('COL01', '计算机学院',         '科研楼4层401', '000-00001001'),
  ('COL02', '信息与通信工程学院', '教三楼6层602', '000-00001002'),
  ('COL03', '人工智能学院',       '新科研楼508',  '000-00001003'),
  ('COL04', '经济管理学院',       '经管楼305',    '000-00001004')
ON DUPLICATE KEY UPDATE
  college_name = VALUES(college_name),
  office_location = VALUES(office_location),
  contact_phone = VALUES(contact_phone);

-- ----------------------------------------------------------------------------
-- 3. 专业数据 (major)
-- ----------------------------------------------------------------------------
INSERT INTO major (major_id, major_name, college_id, required_elective_credits, duration_years) VALUES
  ('MAJ01', '计算机科学与技术',   'COL01', 12.0, 4),
  ('MAJ02', '软件工程',           'COL01', 12.0, 4),
  ('MAJ03', '通信工程',           'COL02', 10.0, 4),
  ('MAJ04', '人工智能',           'COL03', 12.0, 4),
  ('MAJ05', '信息管理与信息系统', 'COL04', 10.0, 4)
ON DUPLICATE KEY UPDATE
  major_name = VALUES(major_name),
  required_elective_credits = VALUES(required_elective_credits);

-- ----------------------------------------------------------------------------
-- 4. 行政班级数据 (admin_class)：覆盖 2023（毕业年级）、2024、2025 三个年级
-- ----------------------------------------------------------------------------
INSERT INTO admin_class (admin_class_id, class_name, grade, major_id, college_id, student_count) VALUES
  ('CLS01', '计科2023-1班', 2023, 'MAJ01', 'COL01', 0),
  ('CLS02', '计科2024-1班', 2024, 'MAJ01', 'COL01', 0),
  ('CLS03', '软工2023-1班', 2023, 'MAJ02', 'COL01', 0),
  ('CLS04', '软工2024-1班', 2024, 'MAJ02', 'COL01', 0),
  ('CLS05', '通信2023-1班', 2023, 'MAJ03', 'COL02', 0),
  ('CLS06', '通信2024-1班', 2024, 'MAJ03', 'COL02', 0),
  ('CLS07', '智科2024-1班', 2024, 'MAJ04', 'COL03', 0),
  ('CLS08', '信管2025-1班', 2025, 'MAJ05', 'COL04', 0)
ON DUPLICATE KEY UPDATE
  class_name = VALUES(class_name),
  grade = VALUES(grade);

-- ----------------------------------------------------------------------------
-- 5. 教师数据 (teacher)：18 名教师，覆盖 4 个学院、4 类职称与多年龄段
-- ----------------------------------------------------------------------------
INSERT INTO teacher (teacher_id, teacher_name, gender, birth_date, age, title, college_id, phone, email, status) VALUES
  ('T001', '王建国', '男', '1976-04-12', 50, '教授',   'COL01', '13810000001', 't001@edu.example.com', '在职'),
  ('T002', '李明华', '女', '1983-09-21', 43, '副教授', 'COL01', '13810000002', 't002@edu.example.com', '在职'),
  ('T003', '张志远', '男', '1980-02-18', 46, '教授',   'COL01', '13810000003', 't003@edu.example.com', '在职'),
  ('T004', '陈晓峰', '男', '1986-11-05', 40, '副教授', 'COL01', '13810000004', 't004@edu.example.com', '在职'),
  ('T005', '赵静怡', '女', '1990-06-30', 36, '讲师',   'COL01', '13810000005', 't005@edu.example.com', '在职'),
  ('T006', '刘浩然', '男', '1992-03-14', 34, '讲师',   'COL01', '13810000006', 't006@edu.example.com', '在职'),
  ('T007', '孙文博', '男', '1996-08-09', 30, '助教',   'COL01', '13810000007', 't007@edu.example.com', '在职'),
  ('T008', '周立新', '男', '1974-12-03', 52, '教授',   'COL02', '13810000008', 't008@edu.example.com', '在职'),
  ('T009', '吴海燕', '女', '1982-05-19', 44, '副教授', 'COL02', '13810000009', 't009@edu.example.com', '在职'),
  ('T010', '郑宇航', '男', '1989-10-27', 37, '讲师',   'COL02', '13810000010', 't010@edu.example.com', '在职'),
  ('T011', '冯思琪', '女', '1995-01-16', 31, '助教',   'COL02', '13810000011', 't011@edu.example.com', '在职'),
  ('T012', '黄启明', '男', '1978-07-22', 48, '教授',   'COL03', '13810000012', 't012@edu.example.com', '在职'),
  ('T013', '林若汐', '女', '1985-03-08', 41, '副教授', 'COL03', '13810000013', 't013@edu.example.com', '在职'),
  ('T014', '徐子墨', '男', '1991-09-11', 35, '讲师',   'COL03', '13810000014', 't014@edu.example.com', '在职'),
  ('T015', '朱嘉欣', '女', '1997-04-25', 29, '助教',   'COL03', '13810000015', 't015@edu.example.com', '在职'),
  ('T016', '郭宏伟', '男', '1972-11-18', 54, '教授',   'COL04', '13810000016', 't016@edu.example.com', '在职'),
  ('T017', '何雪梅', '女', '1984-06-07', 42, '副教授', 'COL04', '13810000017', 't017@edu.example.com', '在职'),
  ('T018', '高俊杰', '男', '1993-12-29', 33, '讲师',   'COL04', '13810000018', 't018@edu.example.com', '在职')
ON DUPLICATE KEY UPDATE
  teacher_name = VALUES(teacher_name),
  title = VALUES(title),
  age = VALUES(age),
  status = VALUES(status);

-- ----------------------------------------------------------------------------
-- 6. 教室数据 (classroom)：16 间教室，混合多楼宇、大小容量、多媒体/非多媒体及维修状态
-- ----------------------------------------------------------------------------
INSERT INTO classroom (classroom_id, building, room_no, capacity, is_multimedia, room_type, status) VALUES
  ('R001', '教三楼', '301',  80, 1, '多媒体教室', '可用'),
  ('R002', '教三楼', '302',  80, 1, '多媒体教室', '可用'),
  ('R003', '教三楼', '305', 120, 1, '阶梯教室',   '可用'),
  ('R004', '教三楼', '308',  60, 1, '多媒体教室', '可用'),
  ('R005', '教三楼', '310',  40, 0, '普通教室',   '可用'),
  ('R006', '教三楼', '312', 100, 0, '普通教室',   '可用'),
  ('R007', '教二楼', '201',  30, 1, '多媒体教室', '可用'),
  ('R008', '教二楼', '205',  80, 1, '多媒体教室', '可用'),
  ('R009', '教四楼', '401', 100, 1, '阶梯教室',   '可用'),
  ('R010', '教四楼', '405', 120, 1, '阶梯教室',   '可用'),
  ('R011', '教四楼', '410',  45, 0, '普通教室',   '可用'),
  ('R012', '科研楼', '201',  60, 1, '计算机机房', '可用'),
  ('R013', '科研楼', '202',  60, 1, '计算机机房', '可用'),
  ('R014', '教一楼', '101', 180, 1, '阶梯教室',   '可用'),
  ('R015', '教一楼', '103',  50, 1, '专业实验室', '可用'),
  ('R016', '教一楼', '105',  60, 1, '多媒体教室', '维修中')
ON DUPLICATE KEY UPDATE
  capacity = VALUES(capacity),
  is_multimedia = VALUES(is_multimedia),
  room_type = VALUES(room_type),
  status = VALUES(status);

-- ----------------------------------------------------------------------------
-- 7. 存储过程批量生成 80 名学生数据 (S001 - S080)
--    每个行政班 10 人；2023 级（CLS01/CLS03/CLS05）标记 is_graduating = 1
--    同时包含少量非“在读”学籍样本（S078 休学、S079 留级）及多类家庭情况标签
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_seed_base_students;
DELIMITER $$
CREATE PROCEDURE sp_seed_base_students()
BEGIN
  DECLARE v_i INT DEFAULT 1;
  DECLARE v_stu_id VARCHAR(16);
  DECLARE v_stu_name VARCHAR(64);
  DECLARE v_gender ENUM('男','女');
  DECLARE v_birth DATE;
  DECLARE v_cls_idx INT;
  DECLARE v_cls_id VARCHAR(16);
  DECLARE v_major_id VARCHAR(16);
  DECLARE v_college_id VARCHAR(16);
  DECLARE v_grade SMALLINT UNSIGNED;
  DECLARE v_is_grad TINYINT(1);
  DECLARE v_status ENUM('在读','休学','复学','留级','退学','肄业','已毕业');
  DECLARE v_family VARCHAR(255);
  DECLARE v_surname VARCHAR(8);
  DECLARE v_given VARCHAR(16);

  WHILE v_i <= 80 DO
    SET v_stu_id = CONCAT('S', LPAD(v_i, 3, '0'));
    SET v_cls_idx = FLOOR((v_i - 1) / 10) + 1;
    SET v_cls_id = CONCAT('CLS', LPAD(v_cls_idx, 2, '0'));

    SELECT major_id, college_id, grade
      INTO v_major_id, v_college_id, v_grade
    FROM admin_class
    WHERE admin_class_id = v_cls_id;

    SET v_is_grad = IF(v_grade = 2023, 1, 0);
    SET v_gender = IF(MOD(v_i, 3) = 0, '女', '男');
    SET v_birth = DATE_ADD(CONCAT(v_grade - 18, '-01-01'), INTERVAL MOD(v_i * 37, 350) DAY);

    SET v_surname = ELT(MOD(v_i - 1, 16) + 1,
      '张','王','李','赵','陈','刘','杨','黄','周','吴','徐','孙','胡','朱','高','林');
    IF v_gender = '女' THEN
      SET v_given = ELT(MOD(v_i - 1, 6) + 1,
        '思涵','若彤','欣怡','诗琪','语嫣','梦瑶');
    ELSE
      SET v_given = ELT(MOD(v_i - 1, 6) + 1,
        '宇轩','嘉豪','子昂','明远','浩宇','泽楷');
    END IF;
    SET v_stu_name = CONCAT(v_surname, v_given);

    IF v_i = 78 THEN
      SET v_status = '休学';
    ELSEIF v_i = 79 THEN
      SET v_status = '留级';
    ELSE
      SET v_status = '在读';
    END IF;

    SET v_family = ELT(MOD(v_i - 1, 4) + 1,
      '城镇双职工家庭，经济状况良好',
      '农村务农家庭，普通经济水平',
      '城镇普通家庭，获国家助学金支持',
      '单亲家庭，申请勤工助学岗位');

    INSERT INTO student (
      student_id, student_name, gender, birth_date, grade,
      enrollment_status, is_graduating, family_info,
      phone, email, admin_class_id, major_id, college_id
    ) VALUES (
      v_stu_id, v_stu_name, v_gender, v_birth, v_grade,
      v_status, v_is_grad, v_family,
      CONCAT('1392000', LPAD(v_i, 4, '0')),
      CONCAT('s', LPAD(v_i, 3, '0'), '@edu.example.com'),
      v_cls_id, v_major_id, v_college_id
    )
    ON DUPLICATE KEY UPDATE
      student_name = VALUES(student_name),
      grade = VALUES(grade),
      enrollment_status = VALUES(enrollment_status),
      is_graduating = VALUES(is_graduating),
      family_info = VALUES(family_info),
      admin_class_id = VALUES(admin_class_id),
      major_id = VALUES(major_id),
      college_id = VALUES(college_id);

    SET v_i = v_i + 1;
  END WHILE;

  -- 回写各行政班级真实在籍人数
  UPDATE admin_class ac
  SET ac.student_count = (
    SELECT COUNT(*) FROM student s WHERE s.admin_class_id = ac.admin_class_id
  );
END$$
DELIMITER ;

CALL sp_seed_base_students();
DROP PROCEDURE IF EXISTS sp_seed_base_students;

-- 基础造数汇总核验
SELECT 'term' AS table_name, COUNT(*) AS row_count FROM term
UNION ALL SELECT 'college',     COUNT(*) FROM college
UNION ALL SELECT 'major',       COUNT(*) FROM major
UNION ALL SELECT 'admin_class', COUNT(*) FROM admin_class
UNION ALL SELECT 'teacher',     COUNT(*) FROM teacher
UNION ALL SELECT 'classroom',   COUNT(*) FROM classroom
UNION ALL SELECT 'student',     COUNT(*) FROM student;
