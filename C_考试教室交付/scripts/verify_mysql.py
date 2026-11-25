#!/usr/bin/env python3
"""用真实 MySQL 的初始化模式从空库验证 A+C；不启动监听、不修改现有库。

示例：python3 verify_mysql.py --mysqld /path/to/bin/mysqld --basedir /path/to/mysql
仅依赖 Python 标准库。结果写入 ../results；运行失败时返回非零退出码。
"""
import argparse
import csv
import json
import re
import subprocess
import tempfile
from pathlib import Path


MODULE = Path(__file__).resolve().parents[1]
REPO = MODULE.parent
BASE_FILES = [
    'A_组长交付/sql/01_base_ddl.sql',
    'A_组长交付/sql/01_base_seed.sql',
    'A_组长交付/sql/02_course_ddl.sql',
    'A_组长交付/sql/02_course_seed.sql',
]
C_FILES = [
    'C_考试教室交付/sql/04_exam_room_ddl.sql',
    'C_考试教室交付/sql/04_exam_room_seed.sql',
]
SHARED = ['college', 'major', 'admin_class', 'student', 'teacher', 'term', 'classroom',
          'course', 'course_offering', 'offering_teacher', 'course_schedule', 'enrollment',
          'schedule_change', 'course_exemption']


def read_files(paths):
    return '\n'.join((REPO / p).read_text(encoding='utf-8') for p in paths) + '\n'


def literal(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "''") + "'"


def export(query, path):
    # MySQL SELECT ... INTO OUTFILE accepts INTO at the end (before the semicolon).
    return query.rstrip(';\n') + ' INTO OUTFILE ' + literal(path) + ';\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mysqld', required=True, type=Path)
    parser.add_argument('--basedir', required=True, type=Path)
    parser.add_argument('--output-dir', type=Path, default=MODULE / 'results')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='edu-er-verify-') as directory:
        work = Path(directory)
        sql = read_files(BASE_FILES)
        sql += 'CREATE TEMPORARY TABLE er_shared_counts (table_name VARCHAR(64),rows_before INT,rows_after INT);\n'
        for table in SHARED:
            sql += f"INSERT INTO er_shared_counts SELECT '{table}',COUNT(*),NULL FROM `{table}`;\n"
        sql += read_files(C_FILES)
        tests = (MODULE / 'sql/04_exam_room_test.sql').read_text(encoding='utf-8')
        for run in (1, 2):
            if run == 2:
                sql += read_files(C_FILES)  # 不覆盖公共 DDL、seed；仅验证 C 重复执行。
            sql += tests + '\n'
            sql += export('SELECT seq,test_name,result,detail FROM er_test_result ORDER BY seq', work / f'assertions_{run}.tsv')
        for table in SHARED:
            sql += f"UPDATE er_shared_counts SET rows_after=(SELECT COUNT(*) FROM `{table}`) WHERE table_name='{table}';\n"
        exports = {
            'student_exam': "SELECT * FROM v_er_student_exam WHERE student_id='S011' AND term_id='2026-1' ORDER BY exam_week,day_of_week,start_section",
            'teacher_exam': "SELECT * FROM v_er_teacher_exam WHERE teacher_id IN ('T001','T002','T006','T008') ORDER BY teacher_id,exam_week,day_of_week,start_section",
            'exam_roster': "SELECT * FROM v_er_exam_roster WHERE exam_id='ERX001' ORDER BY student_id",
            'room_occupancy': 'SELECT * FROM v_er_room_occupancy ORDER BY source_id',
            'shared_counts': 'SELECT * FROM er_shared_counts ORDER BY table_name',
            'metadata': "SELECT VERSION(),@@version_comment,@@default_storage_engine,(SELECT COUNT(*) FROM exam),(SELECT COUNT(*) FROM room_booking),(SELECT COUNT(*) FROM exam_deferral)",
        }
        for name, query in exports.items():
            sql += export(query, work / f'{name}.tsv')
        # 初始化线程没有普通连接的 CURRENT_USER，必须指定已经建立的 root 定义者。
        # 只对临时副本增加 DEFINER；提交的 SQL 原文件保持由导入用户定义的通常行为。
        sql = re.sub(r'\bCREATE (FUNCTION|PROCEDURE|TRIGGER)\b', r'CREATE DEFINER=`root`@`localhost` \1', sql)
        sql = sql.replace('CREATE OR REPLACE VIEW', 'CREATE OR REPLACE DEFINER=`root`@`localhost` VIEW')
        init_file = work / 'verify.sql'
        init_file.write_text(sql, encoding='utf-8')
        error_log = work / 'mysql.txt'
        cmd = [str(args.mysqld.resolve()), '--no-defaults', '--initialize-insecure',
               '--basedir=' + str(args.basedir.resolve()), '--datadir=' + str(work / 'data'),
               '--mysqlx=OFF', '--secure-file-priv=' + str(work),
               '--init-file=' + str(init_file), '--log-error=' + str(error_log)]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        log = error_log.read_text(encoding='utf-8') if error_log.exists() else ''
        if result.returncode or '[ERROR]' in log:
            print(result.stdout + result.stderr + log)
            raise SystemExit('MySQL 验证失败；未更新成功验收记录。')
        runs = []
        for run in (1, 2):
            with (work / f'assertions_{run}.tsv').open(encoding='utf-8') as stream:
                rows = list(csv.reader(stream, delimiter='\t'))
            if not rows or any(row[2] != 'PASS' for row in rows):
                raise SystemExit(f'第 {run} 轮断言记录缺失或未全部通过')
            runs.append(len(rows))
        with (work / 'shared_counts.tsv').open(encoding='utf-8') as stream:
            if any(row[1] != row[2] for row in csv.reader(stream, delimiter='\t')):
                raise SystemExit('公共表行数被改变')
        for artifact in work.glob('*.tsv'):
            (output / ('04_exam_room_' + artifact.name)).write_bytes(artifact.read_bytes())
        (output / '04_exam_room_mysql.txt').write_text(log, encoding='utf-8')
        summary = {
            'mysql': (work / 'metadata.tsv').read_text(encoding='utf-8').strip().split('\t'),
            'assertions_per_run': runs,
            'all_passed': True,
            'repeat_ddl_seed_and_tests': True,
            'shared_table_row_counts_preserved': True,
            'execution_mode': 'MySQL initialize-insecure + init-file; no listener',
            'temporary_definer': 'root@localhost (initialization thread only)',
            'concurrency_tested': False,
            'normal_client_import_tested': False,
        }
        (output / '04_exam_room_summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        print('结果目录：', output)


if __name__ == '__main__':
    main()
