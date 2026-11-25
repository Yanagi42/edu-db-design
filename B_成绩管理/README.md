# B 成绩管理交付与联调

基于 A 组长提交 `053fd11` 的 MySQL 8 公共底座及课程模块，仅新增 `score`、`score_change_request`、`score_recheck_request` 三张业务表。文档位于 `docs/`，脚本位于 `sql/`；不修改 A 的表结构和存储过程。

## 从空库运行顺序

在仓库根目录，使用 **MySQL 8** 客户端执行。macOS 安装包的客户端路径是 `/usr/local/mysql/bin/mysql`，不带完整路径的 `mysql` 当前仍指向 Homebrew MariaDB，运行时可把以下命令的 `mysql` 替换成该绝对路径：

从空库按以下顺序执行。若首次运行在 B 的 `score_change_request` 建表处中断，先确认学生 80 人、教学班 18 个、`score` 表为空且两张申请表不存在，再从修订后的 `03_score_ddl.sql` 继续。不要在已有业务数据的库中重复执行造数脚本。

```bash
mysql -u root -p --default-character-set=utf8mb4 < A_组长交付/sql/01_base_ddl.sql
mysql -u root -p --default-character-set=utf8mb4 < A_组长交付/sql/01_base_seed.sql
mysql -u root -p --default-character-set=utf8mb4 < A_组长交付/sql/02_course_ddl.sql
mysql -u root -p --default-character-set=utf8mb4 < A_组长交付/sql/02_course_seed.sql
mysql -u root -p --default-character-set=utf8mb4 < B_成绩管理/sql/03_score_ddl.sql
mysql -u root -p --default-character-set=utf8mb4 < B_成绩管理/sql/03_score_seed.sql
mysql -u root -p --default-character-set=utf8mb4 < B_成绩管理/sql/03_score_test.sql
```

如要运行 A 的 `02_course_test.sql`，先在独立空库验证其 12 项，再重建空库进行 B 测试；该脚本会新增有效选课并改变预期造数。`07_opt_rbac.sql` 在所有业务模块之后执行，切勿在有非测试数据的库中随意运行其压测数据清理过程。

脚本以一次性从空库执行为目标。`03_score_test.sql` 会审批一条修改申请并留下一条待审核的回滚演示申请；重复执行前请重建测试库。正式提交时保存 MySQL 版本、每条脚本执行结果和异常拦截截图。

## 当前验证状态

2026-11-25 已在 MySQL Community Server 8.0.46 上从 A 已完成的现场继续执行 B 的 DDL、造数和测试。本地实测日志为 `test-output/mysql8-run-20261125-153441.log`：121 条成绩均已发布，含 1 条缓考；10 项编号测试均有输出，未出现 `FAIL` 或 MySQL 执行错误。第 2、9、10 项由 SQL 输出 `PASS`；其余项目需按结果人工核对。第 3 项未实际覆盖“完全未录入成绩”，第 4 项未实际覆盖“未发布时隐藏分数”。

已知跨模块争议见 `docs/00_A模块接口审查与联调清单.md`；其中先修课及格口径、登录身份绑定、成绩历史学分口径尚待全组统一。B 的过程接受业务 ID，但没有可信数据库登录账号映射，不能单独证明个人权限隔离。
