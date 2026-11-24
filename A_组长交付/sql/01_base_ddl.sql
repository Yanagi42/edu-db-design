-- ============================================================================
-- 文件名：01_base_ddl.sql
-- 负责成员：A（组长）
-- 说明：教务系统公共底座建表脚本（MySQL 8.0 / InnoDB / utf8mb4）
--       包含 7 张全组共享主表：学院、专业、行政班级、学生、教师、学期、教室。
--       成员 B/C/D/E 直接导入 01_base 与 02_course 后即可独立开发本模块，严禁修改原表。
-- 如需从零重建库，可取消下行注释：
-- DROP DATABASE IF EXISTS edu_system;
-- ============================================================================

SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS edu_system
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE edu_system;

-- ----------------------------------------------------------------------------
-- 1. 学院表 (college)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS college (
  college_id      VARCHAR(16)  NOT NULL COMMENT '学院编号（如 COL01）',
  college_name    VARCHAR(64)  NOT NULL COMMENT '学院名称',
  office_location VARCHAR(64)  NULL     COMMENT '学院办公地点',
  contact_phone   VARCHAR(32)  NULL     COMMENT '学院联系电话',
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (college_id),
  UNIQUE KEY uk_college_name (college_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='学院基础表';

-- ----------------------------------------------------------------------------
-- 2. 专业表 (major)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS major (
  major_id                  VARCHAR(16)      NOT NULL COMMENT '专业编号（如 MAJ01）',
  major_name                VARCHAR(64)      NOT NULL COMMENT '专业名称',
  college_id                VARCHAR(16)      NOT NULL COMMENT '所属学院编号',
  required_elective_credits DECIMAL(5,1)     NOT NULL DEFAULT 12.0 COMMENT '毕业要求专业选修课学分（供成绩/学籍模块核验）',
  duration_years            TINYINT UNSIGNED NOT NULL DEFAULT 4 COMMENT '标准学制（年）',
  created_at                DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (major_id),
  UNIQUE KEY uk_major_college_name (college_id, major_name),
  KEY idx_major_college (college_id),
  CONSTRAINT chk_major_elective_credits CHECK (required_elective_credits >= 0),
  CONSTRAINT chk_major_duration CHECK (duration_years BETWEEN 2 AND 8),
  CONSTRAINT fk_major_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='专业基础表';

-- ----------------------------------------------------------------------------
-- 3. 行政班级表 (admin_class)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_class (
  admin_class_id VARCHAR(16)       NOT NULL COMMENT '行政班级编号（如 CLS01）',
  class_name     VARCHAR(64)       NOT NULL COMMENT '班级名称（如 计科2023-1班）',
  grade          SMALLINT UNSIGNED NOT NULL COMMENT '入学年级（如 2023、2024）',
  major_id       VARCHAR(16)       NOT NULL COMMENT '所属专业编号',
  college_id     VARCHAR(16)       NOT NULL COMMENT '所属学院编号',
  student_count  SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '班级在籍人数',
  created_at     DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (admin_class_id),
  UNIQUE KEY uk_admin_class_name (class_name),
  KEY idx_admin_class_major_grade (major_id, grade),
  KEY idx_admin_class_college (college_id),
  CONSTRAINT chk_admin_class_grade CHECK (grade BETWEEN 2000 AND 2100),
  CONSTRAINT fk_admin_class_major FOREIGN KEY (major_id)
    REFERENCES major (major_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_admin_class_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='行政班级表';

-- ----------------------------------------------------------------------------
-- 4. 学生表 (student)
-- 预留字段说明：grade、enrollment_status、is_graduating、family_info 供 B/D/E 模块直接使用
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS student (
  student_id        VARCHAR(16)       NOT NULL COMMENT '学生学号（如 S001）',
  student_name      VARCHAR(64)       NOT NULL COMMENT '学生姓名',
  gender            ENUM('男','女')    NOT NULL COMMENT '性别',
  birth_date        DATE              NOT NULL COMMENT '出生日期',
  grade             SMALLINT UNSIGNED NOT NULL COMMENT '所在年级（如 2023、2024、2025）',
  enrollment_status ENUM('在读','休学','复学','留级','退学','肄业','已毕业')
                                      NOT NULL DEFAULT '在读' COMMENT '学籍状态（供学籍模块使用）',
  is_graduating     TINYINT(1)        NOT NULL DEFAULT 0 COMMENT '毕业年级标记（1=毕业年级，0=非毕业年级）',
  family_info       VARCHAR(255)      NULL     COMMENT '家庭情况（供学籍模块统计，视图层对教师/学生脱敏）',
  phone             VARCHAR(32)       NULL     COMMENT '联系电话',
  email             VARCHAR(100)      NULL     COMMENT '电子邮箱',
  admin_class_id    VARCHAR(16)       NOT NULL COMMENT '所属行政班级编号',
  major_id          VARCHAR(16)       NOT NULL COMMENT '所属专业编号',
  college_id        VARCHAR(16)       NOT NULL COMMENT '所属学院编号',
  created_at        DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (student_id),
  KEY idx_student_class (admin_class_id),
  KEY idx_student_major_grade (major_id, grade, is_graduating),
  KEY idx_student_college_status (college_id, enrollment_status),
  CONSTRAINT chk_student_grade CHECK (grade BETWEEN 2000 AND 2100),
  CONSTRAINT chk_student_graduating CHECK (is_graduating IN (0, 1)),
  CONSTRAINT fk_student_class FOREIGN KEY (admin_class_id)
    REFERENCES admin_class (admin_class_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_student_major FOREIGN KEY (major_id)
    REFERENCES major (major_id)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_student_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='学生基础信息表';

-- ----------------------------------------------------------------------------
-- 5. 教师表 (teacher)
-- 预留字段说明：title（职称）、birth_date/age（出生日期/年龄）供教师管理与评教模块使用
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS teacher (
  teacher_id   VARCHAR(16)                    NOT NULL COMMENT '教师工号（如 T001）',
  teacher_name VARCHAR(64)                    NOT NULL COMMENT '教师姓名',
  gender       ENUM('男','女')                 NOT NULL COMMENT '性别',
  birth_date   DATE                           NOT NULL COMMENT '出生日期',
  age          TINYINT UNSIGNED               NOT NULL COMMENT '年龄（供教师师资年龄结构统计）',
  title        ENUM('教授','副教授','讲师','助教') NOT NULL COMMENT '职称（供教师师资职称统计）',
  college_id   VARCHAR(16)                    NOT NULL COMMENT '所属学院编号',
  phone        VARCHAR(32)                    NULL     COMMENT '联系电话',
  email        VARCHAR(100)                   NULL     COMMENT '电子邮箱',
  status       ENUM('在职','离职','退休')      NOT NULL DEFAULT '在职' COMMENT '在职状态',
  created_at   DATETIME                       NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (teacher_id),
  KEY idx_teacher_college_title (college_id, title),
  CONSTRAINT chk_teacher_age CHECK (age BETWEEN 22 AND 80),
  CONSTRAINT fk_teacher_college FOREIGN KEY (college_id)
    REFERENCES college (college_id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教师基础信息表';

-- ----------------------------------------------------------------------------
-- 6. 学期表 (term)
-- 统一时间基准：全组排课、调课、排考、借教室均关联 term_id
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS term (
  term_id       VARCHAR(16)                           NOT NULL COMMENT '学期编号（如 2026-1、2025-2）',
  term_name     VARCHAR(64)                           NOT NULL COMMENT '学期全称',
  academic_year VARCHAR(16)                           NOT NULL COMMENT '所属学年（如 2026-2027）',
  semester_no   TINYINT UNSIGNED                      NOT NULL COMMENT '学期序号（1=秋，2=春，3=小学期）',
  start_date    DATE                                  NOT NULL COMMENT '学期开始日期',
  end_date      DATE                                  NOT NULL COMMENT '学期结束日期',
  total_weeks   TINYINT UNSIGNED                      NOT NULL DEFAULT 18 COMMENT '总教学周数',
  is_current    TINYINT(1)                            NOT NULL DEFAULT 0 COMMENT '是否当前学期（1=是，0=否）',
  status        ENUM('规划中','选课中','进行中','已结束') NOT NULL DEFAULT '进行中' COMMENT '学期状态',
  PRIMARY KEY (term_id),
  UNIQUE KEY uk_term_name (term_name),
  CONSTRAINT chk_term_semester_no CHECK (semester_no IN (1, 2, 3)),
  CONSTRAINT chk_term_total_weeks CHECK (total_weeks BETWEEN 1 AND 30),
  CONSTRAINT chk_term_is_current CHECK (is_current IN (0, 1)),
  CONSTRAINT chk_term_dates CHECK (end_date > start_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='教学学期基准表';

-- ----------------------------------------------------------------------------
-- 7. 教室表 (classroom)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS classroom (
  classroom_id  VARCHAR(16)       NOT NULL COMMENT '教室编号（如 R001）',
  building      VARCHAR(32)       NOT NULL COMMENT '教学楼名称（如 教三楼）',
  room_no       VARCHAR(16)       NOT NULL COMMENT '房间号（如 301）',
  capacity      SMALLINT UNSIGNED NOT NULL COMMENT '最大容纳人数',
  is_multimedia TINYINT(1)        NOT NULL DEFAULT 1 COMMENT '是否支持多媒体（1=支持，0=不支持）',
  room_type     ENUM('普通教室','多媒体教室','阶梯教室','计算机机房','专业实验室')
                                  NOT NULL DEFAULT '多媒体教室' COMMENT '教室类型',
  status        ENUM('可用','维修中','停用') NOT NULL DEFAULT '可用' COMMENT '教室可用状态',
  created_at    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (classroom_id),
  UNIQUE KEY uk_classroom_loc (building, room_no),
  KEY idx_classroom_cap_mm (capacity, is_multimedia, status),
  CONSTRAINT chk_classroom_capacity CHECK (capacity BETWEEN 10 AND 500),
  CONSTRAINT chk_classroom_multimedia CHECK (is_multimedia IN (0, 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='物理教室资源表';
