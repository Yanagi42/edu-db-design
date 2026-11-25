-- B 成绩管理造数；依赖 01/02 DDL、seed 与 03_score_ddl.sql；从空库运行一次
SET NAMES utf8mb4;
USE edu_system;

-- 为现有有效修读记录生成成绩；保留 O010 作为整班提交/审核演示。
-- S003/O010 是缓考，无数值成绩；未录入则根本没有 score 行，不能当作 0 分。
INSERT INTO score(enrollment_id,recorded_by_teacher_id,score_value,exam_status,score_status,
  submitted_at,reviewed_by_admin_id,review_decision,reviewed_at,published_at)
SELECT e.enrollment_id,
  (SELECT ot.teacher_id FROM offering_teacher ot WHERE ot.offering_id=e.offering_id
   ORDER BY FIELD(ot.teacher_role,'主讲','合讲','实验指导'),ot.teacher_id LIMIT 1),
  IF(e.student_id='S003' AND e.offering_id='O010',NULL,
     45 + MOD(CAST(SUBSTRING(e.student_id,2) AS UNSIGNED)*17
       +CAST(SUBSTRING(e.offering_id,2) AS UNSIGNED)*7,56)),
  IF(e.student_id='S003' AND e.offering_id='O010','缓考','正常'),
  IF(e.offering_id='O010','草稿','已发布'),
  IF(e.offering_id='O010',NULL,'2026-09-15 10:00:00'),
  IF(e.offering_id='O010',NULL,'ADM01'),
  IF(e.offering_id='O010',NULL,'通过'),
  IF(e.offering_id='O010',NULL,'2026-09-16 10:00:00'),
  IF(e.offering_id='O010',NULL,'2026-09-16 10:00:00')
FROM enrollment e WHERE e.status='已选';

CALL sp_score_submit('O010','T001');
CALL sp_score_publish('O010','ADM01','通过','登分册核对无误');

SELECT COUNT(*) AS seeded_scores,
  SUM(score_status='已发布') AS published_scores,
  SUM(exam_status='缓考') AS deferred_exams
FROM score;
