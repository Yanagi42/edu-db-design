-- C 模块种子：依赖 A 的 01/02 DDL 与 seed，再执行本模块 DDL。
-- 可重复执行：已存在的 C 编号不覆盖，不删除申请历史，不更改公共数据。
SET NAMES utf8mb4;
USE edu_system;
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_er_seed$$
CREATE PROCEDURE sp_er_seed()
BEGIN
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX001') THEN
    CALL sp_er_schedule_exam('ERX001','O007','2026-1','R001','T006',17,1,1,2,60,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX002') THEN
    CALL sp_er_schedule_exam('ERX002','O008','2026-1','R002','T007',17,1,3,4,60,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX003') THEN
    CALL sp_er_schedule_exam('ERX003','O009','2026-1','R003','T008',17,2,1,2,60,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX004') THEN
    CALL sp_er_schedule_exam('ERX004','O010','2026-1','R004','T009',17,2,3,4,40,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX005') THEN
    CALL sp_er_schedule_exam('ERX005','O013','2026-1','R008','T010',17,3,1,2,50,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX006') THEN
    CALL sp_er_schedule_exam('ERX006','O018','2026-1','R002','T011',17,4,1,2,60,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX007') THEN
    CALL sp_er_schedule_exam('ERX007','O016','2026-1','R010','T012',17,5,1,2,80,1);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam WHERE exam_id='ERX008') THEN
    CALL sp_er_schedule_exam('ERX008','O017','2026-1','R006','T013',17,5,3,4,60,0);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB001') THEN
    CALL sp_er_apply_booking('ERB001',NULL,'T001','2026-1','R008',17,17,'全',6,3,4,40,1,'教学研讨会');
    CALL sp_er_review_booking('ERB001','已通过','ADMIN_C','人数与设备符合要求，教室无占用');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB002') THEN
    CALL sp_er_apply_booking('ERB002','S011',NULL,'2026-1','R008',17,17,'全',6,3,4,20,1,'学生学习交流，待审批冲突示例');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB003') THEN
    CALL sp_er_apply_booking('ERB003','S031',NULL,'2026-1','R005',17,17,'全',6,5,6,20,0,'社团活动');
    CALL sp_er_review_booking('ERB003','已驳回','ADMIN_C','活动材料不齐全');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB004') THEN
    CALL sp_er_apply_booking('ERB004',NULL,'T003','2026-1','R009',17,17,'全',6,5,6,40,1,'教师培训');
    CALL sp_er_review_booking('ERB004','已通过','ADMIN_C','培训借用通过');
    CALL sp_er_cancel_booking('ERB004','T003','培训改期，释放教室');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB005') THEN
    CALL sp_er_apply_booking('ERB005',NULL,'T007','2026-1','R006',1,8,'双',4,7,8,40,0,'双周学术沙龙，与单周课程互斥');
    CALL sp_er_review_booking('ERB005','已通过','ADMIN_C','单双周互不冲突');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM room_booking WHERE booking_id='ERB006') THEN
    CALL sp_er_apply_booking('ERB006','S011',NULL,'2026-1','R001',1,16,'全',1,1,2,20,1,'待审申请不占用，审批时检查课程冲突');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam_deferral WHERE deferral_id='ERD001') THEN
    CALL sp_er_apply_deferral('ERD001','ERX001','S011','因病住院，申请缓考');
    CALL sp_er_review_deferral('ERD001','已通过','ADMIN_C','证明齐全，同意缓考');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam_deferral WHERE deferral_id='ERD002') THEN
    CALL sp_er_apply_deferral('ERD002','ERX002','S012','参加校级竞赛，申请缓考');
  END IF;
  IF NOT EXISTS(SELECT 1 FROM exam_deferral WHERE deferral_id='ERD003') THEN
    CALL sp_er_apply_deferral('ERD003','ERX001','S013','个人事务申请缓考');
    CALL sp_er_review_deferral('ERD003','已驳回','ADMIN_C','不符合缓考条件，按时参加考试');
  END IF;
END$$
CALL sp_er_seed()$$
DROP PROCEDURE sp_er_seed$$
DELIMITER ;
SELECT 'C_SEED' AS stage,
  (SELECT COUNT(*) FROM exam) AS exams,
  (SELECT COUNT(*) FROM room_booking) AS bookings,
  (SELECT COUNT(*) FROM exam_deferral) AS deferrals;
