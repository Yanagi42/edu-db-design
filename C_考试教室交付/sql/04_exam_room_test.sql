-- 成员 C：8 项业务 + 异常、边界、事务自动断言；需先导入 A 与 C 的 seed。
-- 仅在课设测试库执行。不使用 --force；任一断言失败抛错并令客户端非零退出。
-- 成功写入测试用事务回滚；失败接口调用自带回滚；不改动 A 的数据。
SET NAMES utf8mb4;
USE edu_system;
DROP TEMPORARY TABLE IF EXISTS er_test_result;
CREATE TEMPORARY TABLE er_test_result (
  seq INT AUTO_INCREMENT PRIMARY KEY, test_name VARCHAR(150), result VARCHAR(8), detail VARCHAR(512)
) ENGINE=MEMORY DEFAULT CHARSET=utf8mb4;
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_er_test_assert$$
CREATE PROCEDURE sp_er_test_assert(IN p_name VARCHAR(150),IN p_actual BIGINT,IN p_expected BIGINT)
BEGIN
  DECLARE v_message VARCHAR(128);
  IF NOT (p_actual<=>p_expected) THEN
    SET v_message=CONCAT('FAIL ',p_name,': ',COALESCE(p_actual,'NULL'),' != ',p_expected);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT=v_message;
  END IF;
  INSERT INTO er_test_result(test_name,result,detail) VALUES(p_name,'PASS',CONCAT('actual=',p_actual,', expected=',p_expected));
END$$
DROP PROCEDURE IF EXISTS sp_er_test_error$$
CREATE PROCEDURE sp_er_test_error(IN p_name VARCHAR(150),IN p_sql TEXT,IN p_errno INT,IN p_prefix VARCHAR(100))
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_state CHAR(5) DEFAULT '00000';
  DECLARE v_text TEXT DEFAULT '';
  DECLARE v_message VARCHAR(128);
  SET @er_test_sql=p_sql;
  PREPARE er_test_stmt FROM @er_test_sql;
  BEGIN
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
      GET DIAGNOSTICS CONDITION 1 v_errno=MYSQL_ERRNO,v_state=RETURNED_SQLSTATE,v_text=MESSAGE_TEXT;
    EXECUTE er_test_stmt;
  END;
  DEALLOCATE PREPARE er_test_stmt;
  IF v_errno<>p_errno OR LEFT(v_text,CHAR_LENGTH(p_prefix))<>p_prefix THEN
    SET v_message=LEFT(CONCAT('FAIL ',p_name,': errno=',v_errno,' ',v_text),128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT=v_message;
  END IF;
  INSERT INTO er_test_result(test_name,result,detail) VALUES(p_name,'PASS',CONCAT('errno=',v_errno,', SQLSTATE=',v_state,', ',v_text));
END$$
-- 演示：第一条合法，第二条教室冲突；处理器回滚整笔，不能只回滚第二条。
DROP PROCEDURE IF EXISTS sp_er_test_rollback$$
CREATE PROCEDURE sp_er_test_rollback()
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_mid INT DEFAULT 0;
  DECLARE v_text TEXT DEFAULT '';
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
      GET DIAGNOSTICS CONDITION 1 v_errno=MYSQL_ERRNO,v_text=MESSAGE_TEXT;
      ROLLBACK;
    END;
    START TRANSACTION;
    CALL sp_er_lock_term('2026-1');
    INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit)
      VALUES('ERT_TX1','O011','2026-1','R007','T018',18,6,1,2,30);
    SELECT COUNT(*) INTO v_mid FROM exam WHERE exam_id='ERT_TX1';
    INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit)
      VALUES('ERT_TX2','O012','2026-1','R001','T018',17,1,1,2,50);
    COMMIT;
  END;
  CALL sp_er_test_assert('TX-第一步确实进入事务',v_mid,1);
  CALL sp_er_test_assert('TX-第二步准确命中业务冲突',IF(v_errno=1644 AND LEFT(v_text,12)='ER_ROOM_BUSY',1,0),1);
END$$
DELIMITER ;
SET @er_before_exam=(SELECT COUNT(*) FROM exam);
SET @er_before_booking=(SELECT COUNT(*) FROM room_booking);
SET @er_before_deferral=(SELECT COUNT(*) FROM exam_deferral);

SELECT 'EX01 合法排考' AS test_group;

START TRANSACTION;

INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES('ERT_OK','O011','2026-1','R007','T018',18,6,1,2,30,1);

SET @er_actual=(SELECT COUNT(*) FROM exam WHERE exam_id='ERT_OK');

CALL sp_er_test_assert('EX01-合法排考写入',@er_actual,1);

ROLLBACK;

SET @er_actual=(SELECT COUNT(*) FROM exam WHERE exam_id='ERT_OK');

CALL sp_er_test_assert('EX01-回滚无残留',@er_actual,0);

SELECT 'EX02 排考冲突与异常拦截' AS test_group;

START TRANSACTION;

CALL sp_er_test_error('EX02-考试占用教室且节次端点重叠','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R001'',''T018'',17,1,2,3,30,0)',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('EX02-正常课程占用教室','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R001'',''T018'',2,1,1,2,30,0)',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('EX02-已通过借用占用教室','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R008'',''T018'',17,6,3,4,30,0)',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('EX02-监考与已有监考冲突','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T006'',17,1,1,2,30,0)',1644,'ER_TEACHER_BUSY');

CALL sp_er_test_error('EX02-监考与本人授课冲突','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T001'',2,1,1,2,30,0)',1644,'ER_TEACHER_BUSY');

CALL sp_er_test_error('EX02-跨班选修学生考试冲突','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',17,2,3,4,30,0)',1644,'ER_STUDENT_BUSY');

CALL sp_er_test_error('EX02-选课学生与课程冲突','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',2,2,5,6,30,0)',1644,'ER_STUDENT_BUSY');

CALL sp_er_test_error('EX02-物理教室容量不足','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R007'',''T018'',18,6,1,2,40,0)',1644,'ER_ROOM_CAPACITY');

CALL sp_er_test_error('EX02-实际选课人数大于考位','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',18,6,1,2,2,0)',1644,'ER_EXAM_SEATS');

CALL sp_er_test_error('EX02-维修教室','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R016'',''T018'',18,6,1,2,30,0)',1644,'ER_ROOM_UNAVAILABLE');

CALL sp_er_test_error('EX02-多媒体要求','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R005'',''T018'',18,6,1,2,30,1)',1644,'ER_ROOM_MULTIMEDIA');

CALL sp_er_test_error('EX02-超出学期总周数','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',19,6,1,2,30,0)',1644,'ER_SLOT');

CALL sp_er_test_error('EX02-星期越界','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',18,8,1,2,30,0)',1644,'ER_SLOT');

CALL sp_er_test_error('EX02-节次倒置','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T018'',18,6,4,3,30,0)',1644,'ER_SLOT');

CALL sp_er_test_error('EX02-教学班与学期不一致','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2025-1'',''R014'',''T018'',18,6,1,2,30,0)',1644,'ER_OFFERING_TERM');

CALL sp_er_test_error('EX02-监考教师不存在','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O011'',''2026-1'',''R014'',''T999'',18,6,1,2,30,0)',1644,'ER_INVIGILATOR');

CALL sp_er_test_error('EX02-重复安排同一教学班','INSERT INTO exam(exam_id,offering_id,term_id,classroom_id,invigilator_id,exam_week,day_of_week,start_section,end_section,seat_limit,require_multimedia) VALUES(''ERT_BAD'',''O007'',''2026-1'',''R014'',''T018'',18,6,1,2,30,0)',1062,'Duplicate entry');

CALL sp_er_test_error('EX02-改排同样接受冲突校验','UPDATE exam SET classroom_id=''R001'',day_of_week=1,start_section=1,end_section=2 WHERE exam_id=''ERX002''',1644,'ER_ROOM_BUSY');

SET @er_actual=(SELECT COUNT(*) FROM exam WHERE exam_id='ERX002' AND classroom_id='R002' AND start_section=3);

CALL sp_er_test_assert('EX02-非法改排保留原安排',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM exam WHERE exam_id='ERT_BAD');

CALL sp_er_test_assert('EX02-全部非法排考无残留',@er_actual,0);

ROLLBACK;

SELECT 'EX03 学生个人考表' AS test_group;

SELECT * FROM v_er_student_exam WHERE student_id='S011' AND term_id='2026-1' ORDER BY exam_week,day_of_week,start_section;

SET @er_actual=(SELECT COUNT(*) FROM v_er_student_exam WHERE student_id='S011' AND term_id='2026-1');

CALL sp_er_test_assert('EX03-S011个人考表四场',@er_actual,4);

SET @er_actual=(SELECT COUNT(*) FROM v_er_student_exam WHERE student_id='S011' AND exam_id='ERX001' AND attendance_status='缓考' AND seat_no IS NULL);

CALL sp_er_test_assert('EX03-已通过缓考显示并无座位',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM v_er_student_exam WHERE student_id='S012' AND exam_id='ERX002' AND attendance_status='应考');

CALL sp_er_test_assert('EX03-待审缓考仍须应考',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM v_er_student_exam WHERE student_id='S008' AND offering_id='O016');

CALL sp_er_test_assert('EX03-已退课不出现在考表',@er_actual,0);

SELECT 'EX04 教师考表（任课/合讲/监考）' AS test_group;

SELECT * FROM v_er_teacher_exam WHERE teacher_id IN ('T001','T002','T006','T008') ORDER BY teacher_id,exam_week,day_of_week,start_section;

SET @er_actual=(SELECT COUNT(*) FROM v_er_teacher_exam WHERE teacher_id='T002' AND exam_id='ERX001' AND is_instructor=1 AND is_invigilator=0);

CALL sp_er_test_assert('EX04-合讲教师可查本班考试',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM v_er_teacher_exam WHERE teacher_id='T006' AND exam_id='ERX001' AND is_invigilator=1 AND is_instructor=0);

CALL sp_er_test_assert('EX04-非任课监考教师可查',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM v_er_teacher_exam WHERE teacher_id='T008');

CALL sp_er_test_assert('EX04-不同教师角色均被覆盖',@er_actual,2);

SET @er_actual=(SELECT COUNT(*) FROM (SELECT teacher_id,exam_id FROM v_er_teacher_exam GROUP BY teacher_id,exam_id HAVING COUNT(*)>1) d);

CALL sp_er_test_assert('EX04-每位教师每场无重复',@er_actual,0);

START TRANSACTION;

UPDATE exam SET invigilator_id='T001' WHERE exam_id='ERX001';

SET @er_actual=(SELECT COUNT(*) FROM v_er_teacher_exam WHERE teacher_id='T001' AND exam_id='ERX001' AND is_instructor=1 AND is_invigilator=1);

CALL sp_er_test_assert('EX04-任课兼监考仍仅一行',@er_actual,1);

ROLLBACK;

SELECT 'EX05 考试名单与座位' AS test_group;

SELECT * FROM v_er_exam_roster WHERE exam_id='ERX001' ORDER BY student_id;

SET @er_actual=(SELECT COUNT(*) FROM v_er_exam_roster WHERE exam_id='ERX001');

CALL sp_er_test_assert('EX05-本班完整名单十人',@er_actual,10);

SET @er_actual=(SELECT COUNT(*) FROM v_er_exam_roster WHERE exam_id='ERX001' AND attendance_status='应考');

CALL sp_er_test_assert('EX05-应考九人缓考一人',@er_actual,9);

SET @er_actual=(SELECT MAX(seat_no) FROM v_er_exam_roster WHERE exam_id='ERX001');

CALL sp_er_test_assert('EX05-应考座位连续到九',@er_actual,9);

SET @er_actual=(SELECT COUNT(*) FROM v_er_exam_roster WHERE exam_id='ERX001' AND student_id='S013' AND attendance_status='应考' AND seat_no IS NOT NULL);

CALL sp_er_test_assert('EX05-驳回缓考仍应考有座位',@er_actual,1);

SET @er_actual=(SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name IN ('v_er_student_exam','v_er_teacher_exam','v_er_exam_roster') AND column_name IN ('family_info','phone','birth_date','email'));

CALL sp_er_test_assert('EX05-不暴露家庭电话等隐私列',@er_actual,0);

SELECT 'EX06 缓考申请与审批' AS test_group;

START TRANSACTION;

INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) SELECT 'ERT_D1','ERX002',enrollment_id,'因病申请' FROM enrollment WHERE student_id='S014' AND offering_id='O008';

SET @er_actual=(SELECT COUNT(*) FROM exam_deferral WHERE deferral_id='ERT_D1' AND approval_status='待审核');

CALL sp_er_test_assert('EX06-合法申请从待审开始',@er_actual,1);

UPDATE exam_deferral SET approval_status='已通过',reviewer='ADMIN_C',review_time=CURRENT_TIMESTAMP,review_comment='课设测试审批' WHERE deferral_id='ERT_D1';

SET @er_actual=(SELECT COUNT(*) FROM v_er_exam_roster WHERE exam_id='ERX002' AND student_id='S014' AND attendance_status='缓考' AND seat_no IS NULL);

CALL sp_er_test_assert('EX06-审批同步改变考试名单',@er_actual,1);

CALL sp_er_test_error('EX06-重复申请拦截','INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) SELECT ''ERT_D2'',''ERX002'',enrollment_id,''重复申请'' FROM enrollment WHERE student_id=''S014'' AND offering_id=''O008''',1062,'Duplicate entry');

CALL sp_er_test_error('EX06-重复审批拦截','UPDATE exam_deferral SET approval_status=''已通过'',reviewer=''ADMIN_C'',review_time=CURRENT_TIMESTAMP,review_comment=''课设测试审批'' WHERE deferral_id=''ERT_D1''',1644,'ER_DEFERRAL_STATE');

CALL sp_er_test_error('EX06-非本场选课拦截','INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) SELECT ''ERT_D3'',''ERX001'',enrollment_id,''跨课程申请'' FROM enrollment WHERE student_id=''S001'' AND offering_id=''O010''',1644,'ER_DEFERRAL_ENROLLMENT');

CALL sp_er_test_error('EX06-已退课申请拦截','INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) SELECT ''ERT_D4'',''ERX007'',enrollment_id,''已退课申请'' FROM enrollment WHERE student_id=''S008'' AND offering_id=''O016''',1644,'ER_DEFERRAL_ENROLLMENT');

CALL sp_er_test_error('EX06-初始状态不可直接已通过','INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason,approval_status) SELECT ''ERT_D5'',''ERX002'',enrollment_id,''绕过审批'',''已通过'' FROM enrollment WHERE student_id=''S015'' AND offering_id=''O008''',1644,'ER_INITIAL_STATUS');

CALL sp_er_test_error('EX06-申请原因不能为空','INSERT INTO exam_deferral(deferral_id,exam_id,enrollment_id,reason) SELECT ''ERT_D6'',''ERX002'',enrollment_id,'' '' FROM enrollment WHERE student_id=''S015'' AND offering_id=''O008''',3819,'Check constraint');

CALL sp_er_test_error('EX06-审批人必填','UPDATE exam_deferral SET approval_status=''已通过'',review_time=CURRENT_TIMESTAMP,review_comment=''同意'' WHERE deferral_id=''ERD002''',3819,'Check constraint');

CALL sp_er_test_error('EX06-终态不可退回待审','UPDATE exam_deferral SET approval_status=''待审核'' WHERE deferral_id=''ERD003''',1644,'ER_DEFERRAL_STATE');

CALL sp_er_test_error('EX06-审批历史不可删除','DELETE FROM exam_deferral WHERE deferral_id=''ERD003''',1644,'ER_HISTORY');

ROLLBACK;

SET @er_actual=(SELECT COUNT(*) FROM exam_deferral);

CALL sp_er_test_assert('EX06-测试结束恢复缓考记录数',@er_actual,3);

SELECT 'ROOM01 教室借用审批与释放' AS test_group;

START TRANSACTION;

INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES('ERT_B1',NULL,'T006','2026-1','R014',18,18,'全',6,5,6,40,1,'课程设计测试借用');

SET @er_actual=(SELECT COUNT(*) FROM v_er_room_occupancy WHERE source_id='BK:ERT_B1');

CALL sp_er_test_assert('ROOM01-待审不占用',@er_actual,0);

UPDATE room_booking SET approval_status='已通过',reviewer='ADMIN_C',review_time=CURRENT_TIMESTAMP,review_comment='课设测试审批' WHERE booking_id='ERT_B1';

SET @er_actual=(SELECT COUNT(*) FROM v_er_room_occupancy WHERE source_id='BK:ERT_B1');

CALL sp_er_test_assert('ROOM01-通过后占用',@er_actual,1);

INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES('ERT_B2',NULL,'T006','2026-1','R014',18,18,'全',6,5,6,40,1,'课程设计测试借用');

CALL sp_er_test_error('ROOM01-审批时二次冲突检查','UPDATE room_booking SET approval_status=''已通过'',reviewer=''ADMIN_C'',review_time=CURRENT_TIMESTAMP,review_comment=''课设测试审批'' WHERE booking_id=''ERT_B2''',1644,'ER_ROOM_BUSY');

SET @er_actual=(SELECT COUNT(*) FROM room_booking WHERE booking_id='ERT_B2' AND approval_status='待审核' AND reviewer IS NULL AND review_time IS NULL);

CALL sp_er_test_assert('ROOM01-失败审批保留待审',@er_actual,1);

UPDATE room_booking SET approval_status='已取消',cancelled_by='T006',cancel_time=CURRENT_TIMESTAMP,cancel_reason='活动改期' WHERE booking_id='ERT_B1';

SET @er_actual=(SELECT COUNT(*) FROM v_er_room_occupancy WHERE source_id='BK:ERT_B1');

CALL sp_er_test_assert('ROOM01-取消后释放占用',@er_actual,0);

SET @er_actual=(SELECT COUNT(*) FROM room_booking WHERE booking_id='ERT_B1' AND reviewer='ADMIN_C' AND review_time IS NOT NULL AND cancelled_by='T006' AND cancel_time IS NOT NULL);

CALL sp_er_test_assert('ROOM01-取消保留审批与取消留痕',@er_actual,1);

UPDATE room_booking SET approval_status='已通过',reviewer='ADMIN_C',review_time=CURRENT_TIMESTAMP,review_comment='课设测试审批' WHERE booking_id='ERT_B2';

SET @er_actual=(SELECT COUNT(*) FROM v_er_room_occupancy WHERE source_id='BK:ERT_B2');

CALL sp_er_test_assert('ROOM01-释放后另一申请可通过',@er_actual,1);

CALL sp_er_test_error('ROOM01-已通过不可重复审批','UPDATE room_booking SET approval_status=''已通过'',reviewer=''ADMIN_C'',review_time=CURRENT_TIMESTAMP,review_comment=''课设测试审批'' WHERE booking_id=''ERT_B2''',1644,'ER_BOOKING_STATE');

CALL sp_er_test_error('ROOM01-取消不可覆盖审批历史','UPDATE room_booking SET approval_status=''已取消'',cancelled_by=''T006'',cancel_time=CURRENT_TIMESTAMP,cancel_reason=''取消'',reviewer=''OTHER'' WHERE booking_id=''ERT_B2''',1644,'ER_REVIEW_IMMUTABLE');

CALL sp_er_test_error('ROOM01-审批后不可暗改时间','UPDATE room_booking SET day_of_week=7 WHERE booking_id=''ERT_B2''',1644,'ER_BOOKING_IMMUTABLE');

CALL sp_er_test_error('ROOM01-借用历史不可删除','DELETE FROM room_booking WHERE booking_id=''ERT_B2''',1644,'ER_HISTORY');

CALL sp_er_test_error('ROOM01-双申请人拦截','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',''S011'',''T006'',''2026-1'',''R014'',18,18,''全'',6,5,6,40,1,''课程设计测试借用'')',1644,'ER_APPLICANT');

CALL sp_er_test_error('ROOM01-无申请人拦截','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',NULL,NULL,''2026-1'',''R014'',18,18,''全'',6,5,6,40,1,''课程设计测试借用'')',1644,'ER_APPLICANT');

CALL sp_er_test_error('ROOM01-不可借用学籍状态','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',''S078'',NULL,''2026-1'',''R014'',18,18,''全'',6,5,6,40,1,''课程设计测试借用'')',1644,'ER_APPLICANT');

CALL sp_er_test_error('ROOM01-借用人数超容量','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',NULL,''T006'',''2026-1'',''R007'',18,18,''全'',6,5,6,40,1,''课程设计测试借用'')',1644,'ER_ROOM_CAPACITY');

CALL sp_er_test_error('ROOM01-借用设备不满足','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',NULL,''T006'',''2026-1'',''R005'',18,18,''全'',6,5,6,20,1,''课程设计测试借用'')',1644,'ER_ROOM_MULTIMEDIA');

CALL sp_er_test_error('ROOM01-借用单双周空集合','INSERT INTO room_booking(booking_id,applicant_student_id,applicant_teacher_id,term_id,classroom_id,start_week,end_week,week_type,day_of_week,start_section,end_section,headcount,require_multimedia,purpose) VALUES(''ERT_B3'',NULL,''T006'',''2026-1'',''R014'',18,18,''单'',6,5,6,40,1,''课程设计测试借用'')',1644,'ER_SLOT_EMPTY');

ROLLBACK;

CALL sp_er_test_error('ROOM01-正式审批接口拒绝课程占用','CALL sp_er_review_booking(''ERB006'',''已通过'',''ADMIN_C'',''冲突检查'')',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('ROOM01-正式审批接口拒绝已占用借用','CALL sp_er_review_booking(''ERB002'',''已通过'',''ADMIN_C'',''冲突检查'')',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('ROOM01-正式接口拒绝无效决定','CALL sp_er_review_booking(''ERB002'',''随意'',''ADMIN_C'',''错误决定'')',1644,'ER_DECISION');

CALL sp_er_test_error('ROOM01-正式接口拒绝空决定','CALL sp_er_review_booking(''ERB002'',NULL,''ADMIN_C'',''空决定'')',1644,'ER_DECISION');

CALL sp_er_test_error('ROOM01-正式接口拒绝未知申请','CALL sp_er_review_booking(''MISSING'',''已通过'',''ADMIN_C'',''未知申请'')',1644,'ER_NOT_FOUND');

CALL sp_er_test_error('EX06-正式缓考接口拒绝重复审批','CALL sp_er_review_deferral(''ERD001'',''已通过'',''ADMIN_C'',''重复'')',1644,'ER_DEFERRAL_STATE');

CALL sp_er_test_error('EX06-正式申请接口拒绝未选课','CALL sp_er_apply_deferral(''ERT_INVALID'',''ERX001'',''S001'',''未选课申请'')',1644,'ER_DEFERRAL_ENROLLMENT');

CALL sp_er_test_error('EX02-正式排考接口回滚冲突','CALL sp_er_schedule_exam(''ERT_API'',''O011'',''2026-1'',''R001'',''T018'',17,1,1,2,30,0)',1644,'ER_ROOM_BUSY');

CALL sp_er_test_error('EX02-正式改排接口回滚冲突','CALL sp_er_reschedule_exam(''ERX002'',''R001'',''T007'',17,1,1,2,60,1)',1644,'ER_ROOM_BUSY');

SELECT 'ROOM02 空闲教室查询与单双周边界' AS test_group;

CALL sp_er_free_rooms('2026-1',17,17,'全',1,1,2,40,1);

CALL sp_er_free_rooms('2026-1',17,17,'全',6,3,4,40,1);

CALL sp_er_free_rooms('2026-1',17,17,'全',6,5,6,40,1);

SET @er_actual=(SELECT COUNT(DISTINCT occupancy_kind) FROM v_er_room_occupancy);

CALL sp_er_test_assert('ROOM02-课程考试借用均进入占用口径',@er_actual,3);

SET @er_actual=(SELECT COUNT(*) FROM v_er_room_occupancy WHERE source_id IN ('BK:ERB002','BK:ERB003','BK:ERB004','BK:ERB006'));

CALL sp_er_test_assert('ROOM02-待审驳回取消不占用',@er_actual,0);

SET @er_actual=(SELECT fn_time_overlap(1,8,'单',4,7,8,1,8,'双',4,7,8));

CALL sp_er_test_assert('ROOM02-单双周互斥',@er_actual,0);

SET @er_actual=(SELECT fn_time_overlap(1,2,'单',4,7,8,2,3,'全',4,7,8));

CALL sp_er_test_assert('ROOM02-交集仅偶周不与单周冲突',@er_actual,0);

SET @er_actual=(SELECT fn_time_overlap(2,3,'双',4,7,8,3,4,'全',4,7,8));

CALL sp_er_test_assert('ROOM02-交集仅奇周不与双周冲突',@er_actual,0);

SET @er_actual=(SELECT fn_time_overlap(1,8,'全',4,7,8,1,8,'全',4,9,10));

CALL sp_er_test_assert('ROOM02-相邻不重叠节次',@er_actual,0);

SET @er_actual=(SELECT fn_time_overlap(1,8,'全',4,7,8,1,8,'全',4,8,9));

CALL sp_er_test_assert('ROOM02-节次端点重叠',@er_actual,1);

CALL sp_er_test_error('ROOM02-查询范围不能超学期','CALL sp_er_free_rooms(''2026-1'',19,19,''全'',1,1,2,40,1)',1644,'ER_SLOT');

CALL sp_er_test_error('ROOM02-查询参数不能为NULL','CALL sp_er_free_rooms(''2026-1'',17,17,''全'',1,1,2,NULL,1)',1644,'ER_RESOURCE');

SELECT 'TX 排考批量事务失败回滚' AS test_group;

CALL sp_er_test_rollback();

SET @er_actual=(SELECT COUNT(*) FROM exam WHERE exam_id IN ('ERT_TX1','ERT_TX2'));

CALL sp_er_test_assert('TX-第一步与第二步均无残留',@er_actual,0);

SET @er_actual=(SELECT COUNT(*) FROM exam);

CALL sp_er_test_assert('END-考试行数恢复',@er_actual,8);

SET @er_actual=(SELECT COUNT(*) FROM room_booking);

CALL sp_er_test_assert('END-借用行数恢复',@er_actual,6);

SET @er_actual=(SELECT COUNT(*) FROM exam_deferral);

CALL sp_er_test_assert('END-缓考行数恢复',@er_actual,3);

SET @er_actual=(SELECT COUNT(*) FROM room_booking WHERE booking_id IN ('ERB002','ERB006') AND approval_status='待审核' AND reviewer IS NULL);

CALL sp_er_test_assert('END-有效种子申请状态未改变',@er_actual,2);

SELECT * FROM er_test_result ORDER BY seq;

SELECT COUNT(*) AS assertions,SUM(result='PASS') AS passed,COUNT(DISTINCT SUBSTRING_INDEX(test_name,'-',1)) AS test_groups FROM er_test_result;

DROP PROCEDURE sp_er_test_assert;

DROP PROCEDURE sp_er_test_error;

DROP PROCEDURE sp_er_test_rollback;
