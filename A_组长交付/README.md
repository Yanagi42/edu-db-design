# 教务系统数据库底座与课程模块对接指南（成员 A 交付）

本目录为成员 A（组长）交付的公共底座、课程管理核心模块及安全/优化全套文档与可运行 SQL（已在 MySQL 8.0.46 从零库完整实测跑通）。队友 **B / C / D / E** 直接导入 `01_base` 与 `02_course` 即可零阻塞开发本模块。

## 一、目录结构

```text
A_组长交付/
├── README.md                        # 本对接与快速导入指南
├── docs/
│   ├── 01_需求分析_A组长.md          # 阶段 1：公共实体契约、课程需求与概念 E-R 子图
│   ├── 02_系统设计_A组长.md          # 阶段 2：逻辑/物理设计、反范式权衡、RBAC/索引与全量数据字典
│   └── 03_测试与优化_A组长.md        # 阶段 3：12 项课程业务实测、视图隔离与 EXPLAIN 优化对比
└── sql/
    ├── 01_base_ddl.sql              # 公共底座建表（7 张共享主表，库名 edu_system）
    ├── 01_base_seed.sql             # 公共底座造数（4 学院/5 专业/8 班/18 教师/16 教室/80 学生）
    ├── 02_course_ddl.sql            # 课程管理建表（7 张表 + 函数 + 11 触发器 + 5 存储过程）
    ├── 02_course_seed.sql           # 课程管理造数（15 课程/18 教学班/15 排课/122 选课/调课/免听）
    ├── 02_course_test.sql           # 课程管理 12 项业务与事务回滚自动测试脚本
    └── 07_opt_rbac.sql              # 选做加分：RBAC 5 表 + 6 隔离视图 + 5 复合索引与压测对比
```

## 二、3 步快速导入本地 MySQL（MySQL 8.0+）

在 `A_组长交付/` 目录下依次执行（若需重建空库，先取消 `01_base_ddl.sql` 顶部 `DROP DATABASE` 注释）：

```bash
# 第 1 步：初始化公共底座（库 edu_system + 7 张主表 + 基础数据）
mysql -u root -p --default-character-set=utf8mb4 < sql/01_base_ddl.sql
mysql -u root -p --default-character-set=utf8mb4 < sql/01_base_seed.sql

# 第 2 步：初始化课程管理模块（7 张课程表 + 触发器/存储过程 + 课程数据）
mysql -u root -p --default-character-set=utf8mb4 < sql/02_course_ddl.sql
mysql -u root -p --default-character-set=utf8mb4 < sql/02_course_seed.sql

# 第 3 步（可选验收）：运行课程 12 项测试与安全/索引优化脚本（自动清理压测合成样本）
mysql -u root -p --default-character-set=utf8mb4 < sql/02_course_test.sql
mysql -u root -p --default-character-set=utf8mb4 < sql/07_opt_rbac.sql
```

## 三、公共主表主键与现成种子 ID 速查（供 B / C / D / E 建外键）

| 表名 | 主键及类型 | 预留关键字段（跨模块支撑） | 现成可用种子 ID |
| :--- | :--- | :--- | :--- |
| `college` | `college_id VARCHAR(16)` | `college_name` | `COL01`–`COL04`（`COL01` 计算机学院） |
| `major` | `major_id VARCHAR(16)` | `college_id`, `required_elective_credits` | `MAJ01`–`MAJ05` |
| `admin_class` | `admin_class_id VARCHAR(16)` | `grade`, `major_id`, `college_id`, `student_count` | `CLS01`–`CLS08`（`CLS01`/`03`/`05` 为 2023 毕业年级） |
| `student` | `student_id VARCHAR(16)` | `grade`, `enrollment_status`, `is_graduating`, `family_info`, `admin_class_id`, `major_id`, `college_id` | `S001`–`S080`（`S001`–`S010` 属 `CLS01` 毕业年级；`S078` 休学、`S079` 留级） |
| `teacher` | `teacher_id VARCHAR(16)` | `title`, `birth_date`, `age`, `college_id`, `status` | `T001`–`T018`（覆盖教授/副教授/讲师/助教） |
| `term` | `term_id VARCHAR(16)` | `academic_year`, `is_current`, `status` | `2025-1`、`2025-2`（已结束）；`2026-1`（当前进行中） |
| `classroom` | `classroom_id VARCHAR(16)` | `building`, `room_no`, `capacity`, `is_multimedia`, `room_type`, `status` | `R001`–`R016`（`R005`/`06`/`11` 非多媒体、`R007` 容量 30、`R016` 维修中） |
| `course` | `course_id VARCHAR(16)` | `credit`, `course_type`（必修/专业选修/公选）, `prereq_course_id`, `college_id` | `C001`–`C015` |
| `course_offering` | `offering_id VARCHAR(16)` | `course_id`, `term_id`, `target_class_id`, `capacity`, `enrolled_count`, `require_multimedia` | `O001`–`O006`（历史已结课）；`O007`–`O018`（`2026-1` 活跃班） |
| `offering_teacher` | `(offering_id, teacher_id)` | `teacher_role`（主讲/合讲/实验指导，支持评教多教师合讲） | 合讲班示例：`O007`、`O009`、`O013`、`O014` |
| `course_schedule` | `schedule_id BIGINT UNSIGNED` | 统一时间口径：`term_id` + `start_week`/`end_week`/`week_type` + `day_of_week` + `start_section`/`end_section` | `1` 到 `15`（跑完 `02_course_test.sql` 后为 `1` 到 `16`） |
| `enrollment` | `enrollment_id BIGINT UNSIGNED` | `UK (student_id, offering_id)`, `status`（已选/已退） | `S001`–`S077` 在历史与 `2026-1` 均有选课记录（直接供 B 录成绩、C 排考、D 评教） |

## 四、全组协作边界提醒

1. **严禁修改底座与课程原表**：B / C / D / E 仅通过外键引用上述表主键，不得 `ALTER` 或改写 `01_base_*` 与 `02_course_*` 原表结构。
2. **统一文件前缀独立提交**：B 用 `03_score_*`、C 用 `04_exam_room_*`、D 用 `05_thesis_eval_*`、E 用 `06_status_teacher_*`，确保最终按 `01` 到 `07` 顺序无冲突合包。
3. **统一时间与编码规范**：排考（C）与教室借用（C）请沿用 `term_id + start_week + end_week + week_type(全/单/双) + day_of_week(1–7) + start_section + end_section`，可直接复用 `fn_time_overlap` 函数；所有扩展表统一使用 `InnoDB`、`utf8mb4` 与 `utf8mb4_0900_ai_ci`。
