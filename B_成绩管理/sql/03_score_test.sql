-- B 成绩管理 9 项业务 + 1 项可选事务失败；在空库完成 01/02/03 seed 后运行一次
SET NAMES utf8mb4;
USE edu_system;

SELECT '1 学生学期单科成绩（S001，2026-1，C006）' AS test_case;
SELECT e.student_id,co.term_id,c.course_id,c.course_name,s.score_value,s.score_status
FROM score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id
JOIN course_offering co ON co.offering_id=e.offering_id JOIN course c ON c.course_id=co.course_id
WHERE e.student_id='S001' AND co.term_id='2026-1' AND c.course_id='C006';

SELECT '2 教师申请并经教务员审批修改本人教学班成绩' AS test_case;
SET @score_id := (SELECT s.score_id FROM score s JOIN enrollment e ON e.enrollment_id=s.enrollment_id
  WHERE e.student_id='S001' AND e.offering_id='O010');
SET @old_score := (SELECT score_value FROM score WHERE score_id=@score_id);
CALL sp_score_change_apply(@score_id,'T001',LEAST(@old_score+1,100),'试卷复核后更正');
SET @change_id := (SELECT MAX(request_id) FROM score_change_request WHERE score_id=@score_id);
CALL sp_score_change_approve(@change_id,'ADM01',1,'核对原卷，同意更正');
SELECT r.request_id,r.old_value,r.new_value,r.status,s.score_value,
  IF(r.status='已通过' AND s.score_value=r.new_value,'PASS','FAIL') AS verification
FROM score_change_request r JOIN score s ON s.score_id=r.score_id WHERE r.request_id=@change_id;

SELECT '3 某教师某学期课程全部有效修读学生成绩（含未录入）' AS test_case;
SELECT e.student_id,st.student_name,co.offering_id,s.score_value,s.exam_status,s.score_status
FROM offering_teacher ot JOIN course_offering co ON co.offering_id=ot.offering_id
JOIN enrollment e ON e.offering_id=co.offering_id AND e.status='已选'
JOIN student st ON st.student_id=e.student_id
LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
WHERE ot.teacher_id='T001' AND co.term_id='2026-1' AND co.course_id='C006'
ORDER BY e.student_id;

SELECT '4 学生某学期所有课程成绩（未发布不显示分数）' AS test_case;
SELECT e.student_id,co.term_id,c.course_name,c.credit,
  IF(s.score_status='已发布',s.score_value,NULL) AS visible_score,
  COALESCE(s.score_status,'未录入') AS progress
FROM enrollment e JOIN course_offering co ON co.offering_id=e.offering_id
JOIN course c ON c.course_id=co.course_id LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
WHERE e.student_id='S001' AND co.term_id='2026-1' AND e.status='已选'
ORDER BY c.course_id;

SELECT '5 T001/O010 成绩分布；缓考单列' AS test_case;
SELECT COUNT(*) AS roster_size,
  SUM(s.score_status='已发布' AND s.exam_status='正常') AS numeric_count,
  SUM(s.score_status='已发布' AND s.exam_status<>'正常') AS special_count,
  SUM(s.score_value<60 AND s.score_status='已发布') AS bucket_0_59,
  SUM(s.score_value>=60 AND s.score_value<70 AND s.score_status='已发布') AS bucket_60_69,
  SUM(s.score_value>=70 AND s.score_value<80 AND s.score_status='已发布') AS bucket_70_79,
  SUM(s.score_value>=80 AND s.score_value<90 AND s.score_status='已发布') AS bucket_80_89,
  SUM(s.score_value>=90 AND s.score_value<=100 AND s.score_status='已发布') AS bucket_90_100,
  ROUND(100*SUM(s.score_value>=60 AND s.score_status='已发布')/
    NULLIF(SUM(s.score_status='已发布' AND s.exam_status='正常'),0),2) AS pass_rate_pct
FROM enrollment e LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
WHERE e.offering_id='O010' AND e.status='已选';

SELECT '6 MAJ01/2023 全部历史不及格修读记录' AS test_case;
SELECT st.student_id,st.student_name,co.term_id,c.course_id,c.course_name,c.credit,s.score_value
FROM student st JOIN enrollment e ON e.student_id=st.student_id AND e.status='已选'
JOIN score s ON s.enrollment_id=e.enrollment_id AND s.score_status='已发布'
  AND s.exam_status='正常' AND s.score_value<60
JOIN course_offering co ON co.offering_id=e.offering_id JOIN course c ON c.course_id=co.course_id
WHERE st.major_id='MAJ01' AND st.grade=2023 ORDER BY st.student_id,co.term_id,c.course_id;

SELECT '7 S001 至今未通过课程学分，按课程去重' AS test_case;
WITH failed AS (
  SELECT DISTINCT co.course_id FROM enrollment e JOIN score s ON s.enrollment_id=e.enrollment_id
  JOIN course_offering co ON co.offering_id=e.offering_id
  WHERE e.student_id='S001' AND e.status='已选' AND s.score_status='已发布'
    AND s.exam_status='正常' AND s.score_value<60
), passed AS (
  SELECT DISTINCT co.course_id FROM enrollment e JOIN score s ON s.enrollment_id=e.enrollment_id
  JOIN course_offering co ON co.offering_id=e.offering_id
  WHERE e.student_id='S001' AND e.status='已选' AND s.score_status='已发布'
    AND s.exam_status='正常' AND s.score_value>=60
)
SELECT COALESCE(SUM(c.credit),0) AS outstanding_failed_credits
FROM failed f JOIN course c ON c.course_id=f.course_id
LEFT JOIN passed p ON p.course_id=f.course_id WHERE p.course_id IS NULL;

SELECT '8 毕业年级每人已获专业选修学分（零值保留）' AS test_case;
WITH earned AS (
  SELECT e.student_id,co.course_id,MAX(c.credit) AS credit
  FROM enrollment e JOIN score s ON s.enrollment_id=e.enrollment_id
  JOIN course_offering co ON co.offering_id=e.offering_id JOIN course c ON c.course_id=co.course_id
  WHERE e.status='已选' AND s.score_status='已发布' AND s.exam_status='正常'
    AND s.score_value>=60 AND c.course_type='专业选修'
  GROUP BY e.student_id,co.course_id
)
SELECT st.student_id,st.student_name,COALESCE(SUM(earned.credit),0) AS earned_elective_credits,
  m.required_elective_credits
FROM student st JOIN major m ON m.major_id=st.major_id
LEFT JOIN earned ON earned.student_id=st.student_id
WHERE st.is_graduating=1 GROUP BY st.student_id,st.student_name,m.required_elective_credits
ORDER BY st.student_id;

SELECT '额外：CLS01 2026-1 班级成绩排名（完整且已发布的数值成绩）' AS test_case;
WITH term_enrollment AS (
  SELECT e.enrollment_id,e.student_id FROM enrollment e
  JOIN course_offering co ON co.offering_id=e.offering_id
  WHERE e.status='已选' AND co.term_id='2026-1'
), per_student AS (
  SELECT st.student_id,st.student_name,COUNT(te.enrollment_id) AS enrolled_courses,
    SUM(CASE WHEN te.enrollment_id IS NULL OR
      (s.score_status='已发布' AND s.exam_status='正常') THEN 0 ELSE 1 END) AS incomplete_courses,
    ROUND(SUM(c.credit*s.score_value)/NULLIF(SUM(c.credit),0),2) AS weighted_average
  FROM student st LEFT JOIN term_enrollment te ON te.student_id=st.student_id
  LEFT JOIN enrollment e ON e.enrollment_id=te.enrollment_id
  LEFT JOIN course_offering co ON co.offering_id=e.offering_id
  LEFT JOIN course c ON c.course_id=co.course_id
  LEFT JOIN score s ON s.enrollment_id=e.enrollment_id
  WHERE st.admin_class_id='CLS01'
  GROUP BY st.student_id,st.student_name
)
SELECT student_id,student_name,
  IF(enrolled_courses>0 AND incomplete_courses=0,weighted_average,NULL) AS valid_average,
  IF(enrolled_courses>0 AND incomplete_courses=0,
    RANK() OVER (ORDER BY IF(enrolled_courses>0 AND incomplete_courses=0,weighted_average,NULL) DESC),NULL) AS class_rank,
  CASE WHEN enrolled_courses=0 THEN '无修读' WHEN incomplete_courses>0 THEN '成绩未齐或特殊状态'
       ELSE '参评' END AS ranking_status
FROM per_student ORDER BY class_rank IS NULL,class_rank,student_id;

SELECT '9 直接写入 101 分须被 CHECK 拦截' AS test_case;
INSERT INTO enrollment(student_id,offering_id,status) VALUES('S080','O016','已选');
DROP PROCEDURE IF EXISTS sp_test_score_over_100;
DELIMITER $$
CREATE PROCEDURE sp_test_score_over_100()
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_errno=MYSQL_ERRNO;
  INSERT INTO score(enrollment_id,recorded_by_teacher_id,score_value)
    SELECT enrollment_id,'T017',101 FROM enrollment
    WHERE student_id='S080' AND offering_id='O016';
  SELECT v_errno AS mysql_errno,
    IF(v_errno=3819 AND NOT EXISTS(SELECT 1 FROM score s JOIN enrollment e
      ON e.enrollment_id=s.enrollment_id WHERE e.student_id='S080' AND e.offering_id='O016'),
      'PASS','FAIL') AS verification;
END$$
DELIMITER ;
CALL sp_test_score_over_100();
DROP PROCEDURE sp_test_score_over_100;
DELETE FROM enrollment WHERE student_id='S080' AND offering_id='O016';

SELECT '10 可选：审批更新成绩后异常，事务回滚且申请仍待审' AS test_case;
CALL sp_score_change_apply(@score_id,'T001',LEAST(@old_score+2,100),'模拟审批失败');
SET @rollback_request := (SELECT MAX(request_id) FROM score_change_request WHERE score_id=@score_id);
DROP PROCEDURE IF EXISTS sp_test_score_rollback;
DELIMITER $$
CREATE PROCEDURE sp_test_score_rollback(IN p_request_id BIGINT UNSIGNED)
BEGIN
  DECLARE v_score_id BIGINT UNSIGNED;
  DECLARE v_old DECIMAL(5,2);
  DECLARE v_new DECIMAL(5,2);
  DECLARE v_errno INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    GET DIAGNOSTICS CONDITION 1 v_errno=MYSQL_ERRNO;
    ROLLBACK;
    SELECT r.request_id,r.status,s.score_value,v_old AS before_value,v_errno AS mysql_errno,
      IF(r.status='待审核' AND s.score_value=v_old AND v_errno=1644,'PASS','FAIL') AS verification
    FROM score_change_request r JOIN score s ON s.score_id=r.score_id WHERE r.request_id=p_request_id;
  END;
  SELECT score_id,old_value,new_value INTO v_score_id,v_old,v_new
    FROM score_change_request WHERE request_id=p_request_id;
  START TRANSACTION;
  UPDATE score SET score_value=v_new WHERE score_id=v_score_id;
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='模拟审批后续步骤失败';
  UPDATE score_change_request SET status='已通过' WHERE request_id=p_request_id;
  COMMIT;
END$$
DELIMITER ;
CALL sp_test_score_rollback(@rollback_request);
DROP PROCEDURE sp_test_score_rollback;

SELECT '额外：申请查卷与核查流程' AS test_case;
CALL sp_score_recheck_apply(@score_id,'S001','申请核对卷面加分');
SET @recheck_id := (SELECT MAX(recheck_id) FROM score_recheck_request WHERE score_id=@score_id);
CALL sp_score_recheck_check(@recheck_id,'T001','已核对原卷与登分记录');
CALL sp_score_recheck_finish(@recheck_id,'ADM01','复核无须更改',NULL);
SELECT recheck_id,status,conclusion FROM score_recheck_request WHERE recheck_id=@recheck_id;
