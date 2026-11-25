-- 从仓库根目录启动 mysql 后执行：
-- SOURCE C_考试教室交付/scripts/import_all.sql;
-- 用于新的课设测试实例；若团队库已导入 A，只执行 C 的三份脚本。
SOURCE A_组长交付/sql/01_base_ddl.sql;
SOURCE A_组长交付/sql/01_base_seed.sql;
SOURCE A_组长交付/sql/02_course_ddl.sql;
SOURCE A_组长交付/sql/02_course_seed.sql;
SOURCE C_考试教室交付/sql/04_exam_room_ddl.sql;
SOURCE C_考试教室交付/sql/04_exam_room_seed.sql;
SOURCE C_考试教室交付/sql/04_exam_room_test.sql;
