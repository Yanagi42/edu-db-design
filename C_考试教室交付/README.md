# 成员 C 交付：考试管理、教室管理

对应分工清单的 **考试 6 项 + 教室 2 项**，三阶段独立文档与 SQL 已齐备。基于 A 的公共底座和课程模块扩展，没有修改其他成员的文件、表结构或触发器。

自己逐条操作、截图验收请看 [手动测试指南](docs/04_手动测试指南_C考试教室.md)，其中列出了准备步骤、8项业务的SQL、预期报错和截图清单。

## 交付内容

```text
C_考试教室交付/
├── README.md
├── docs/
│   ├── 01_需求分析_C考试教室.md     # 三角色用例、8 项说明、2 张流程图、概念 E-R
│   ├── 02_系统设计_C考试教室.md     # 关系模式、约束、流程、事务、接口与物理设计
│   └── 03_测试文档_C考试教室.md     # 实测记录、问题修复、边界与答辩要点
├── sql/
│   ├── 04_exam_room_ddl.sql         # 4 表、4 视图、8 触发器、15 存储过程
│   ├── 04_exam_room_seed.sql        # 8 场考试、6 条借用、3 条缓考
│   └── 04_exam_room_test.sql        # 8 项业务，90 条自动断言，含事务回滚
├── scripts/
│   ├── import_all.sql              # 从仓库根目录 SOURCE，一次导入 A 底座与 C
│   └── verify_mysql.py             # 真实 MySQL 初始化模式独立复测，无第三方依赖
└── results/
    ├── 04_exam_room_summary.json    # 版本、两轮断言数、验证方式与限制
    ├── 04_exam_room_assertions_*.tsv # 两轮各 90 条 PASS，含错误码与原因
    ├── 04_exam_room_*exam*.tsv       # 学生/教师考表、考试名单
    ├── 04_exam_room_room_occupancy.tsv
    ├── 04_exam_room_shared_counts.tsv
    ├── 04_exam_room_metadata.tsv
    └── 04_exam_room_mysql.txt        # MySQL 实际执行日志
```

## 导入与验收

要求 **MySQL 8.0.16+**，与 A 保持 `InnoDB / utf8mb4 / utf8mb4_0900_ai_ci`。MariaDB 的版本号不能替代 MySQL 8 的兼容性要求。

建议使用独立的课设测试实例。脚本沿用组长的库名 `edu_system`，没有自动 `DROP DATABASE`。在已经导入 A 的团队库中只执行 C 的三份脚本，避免重新运行 A 的造数影响已有数据；验收使用未执行演示写入的种子基线。

从仓库根目录打开 MySQL 客户端：

```bash
mysql -u root -p --default-character-set=utf8mb4
```

新测试库一键导入依赖并验收：

```sql
SOURCE C_考试教室交付/scripts/import_all.sql;
```

已有 A 的 `01/02` 建表及种子数据时，仅执行：

```sql
SOURCE C_考试教室交付/sql/04_exam_room_ddl.sql;
SOURCE C_考试教室交付/sql/04_exam_room_seed.sql;
SOURCE C_考试教室交付/sql/04_exam_room_test.sql;
```

Windows 可在仓库根目录打开 CMD/终端再启动 `mysql`；`SOURCE` 中继续使用 `/`。在 Workbench 等工具中运行三份脚本时，按上述顺序逐份执行，客户端须支持 `DELIMITER`。命令行批量执行不要使用忽略错误的 `--force`。

## 已有验证与复测

实际使用 **MySQL Community Server 8.0.44** 从空库执行 A 的 4 份依赖脚本与 C 的三份脚本，90 条断言全部通过；再重复 C 的 DDL、seed、test，仍为 90/90。14 张公共表的行数保持不变。完整证据在 `results/`。

当前环境禁止创建数据库监听套接字，因此实际使用 MySQL 自身 `--initialize-insecure --init-file` 模式执行 SQL，由 `SIGNAL` 自动断言、`INTO OUTFILE` 导出实测记录。没有使用 MariaDB 模拟 MySQL，也没有把初始化模式结果称作普通客户端或双会话并发实测。

可用同样方法安全复测，不连接或修改现有数据库（需要可执行的 MySQL 8 服务端发行包及 Python 3）：

```bash
python3 C_考试教室交付/scripts/verify_mysql.py \
  --mysqld /path/to/mysql/bin/mysqld \
  --basedir /path/to/mysql
```

验证器创建临时数据目录，结束时删除；初始化线程无普通登录用户，只在临时 SQL 副本中补上 `root@localhost` 定义者，不修改交付脚本。结果会更新到 `results/`。标准客户端导入和双会话并发验证可在组内 MySQL 环境继续执行，步骤见测试文档。

## 给成员 E 的合稿说明

三份 `docs/` 分别合入三个阶段文档；Mermaid 图可在支持 Mermaid 的 Markdown 编辑器导出图片。合并 SQL 时保持依赖顺序：`01_base_ddl → 01_base_seed → 02_course_ddl → 02_course_seed → 04_exam_room_ddl → 04_exam_room_seed → 04_exam_room_test`。不要把所有成员的 DDL 跑完再统一导入 seed 后，反过来重跑 A 的 seed。

C 对象以 `er` 命名，考试主表为 `exam`、借用为 `room_booking`、缓考为 `exam_deferral`。只新增自有对象；借用和缓考的审批人字符串由 A 的身份层核验，本模块不创建账号或声称视图自动隔离本人。公共课程/选课稳定后排考；后续跨模块变更需要复核，详见设计文档的集成边界。
