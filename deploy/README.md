# 模板化部署说明

本目录提供“参数文件 + 模板文件 + 渲染执行脚本”的完整部署方式，覆盖：

- FC 两个函数（`domain_inventory` / `ssl_checker`）
- SLS ETL 日志重写到新 Logstore
- SLS 告警规则
- 告警内容模板、行动策略（控制台一次初始化，ID 回填后由 CLI 持续维护）

## 1. 准备参数

```bash
cp deploy/templates/vars.env.tpl deploy/vars.env
```

编辑 `deploy/vars.env`，至少确认以下变量：

- `OSS_BUCKET`, `OSS_PREFIX`
- `ACCOUNT_ID`
- `SLS_PROJECT`, `SLS_SOURCE_LOGSTORE`, `SLS_TARGET_LOGSTORE`
- `CONTENT_TEMPLATE_ID`, `ACTION_POLICY_ID`（控制台初始化后回填）

## 2. 渲染模板

```bash
source deploy/vars.env
./deploy/render_templates.sh
```

渲染输出目录：`deploy/rendered/`

## 3. 分阶段执行 CLI

```bash
./deploy/deploy_cli.sh ram
./deploy/deploy_cli.sh fc
./deploy/deploy_cli.sh invoke
./deploy/deploy_cli.sh sls
./deploy/deploy_cli.sh etl
./deploy/deploy_cli.sh alert
```

或者一步执行：

```bash
./deploy/deploy_cli.sh all
```

## 3.1 每一步验证（便于调模板）

你可以在每个阶段后执行对应验证：

```bash
./deploy/verify_steps.sh local
./deploy/verify_steps.sh ram
./deploy/verify_steps.sh fc
./deploy/verify_steps.sh invoke
./deploy/verify_steps.sh sls
./deploy/verify_steps.sh etl
./deploy/verify_steps.sh alert
```

全链路验证：

```bash
./deploy/verify_steps.sh all
```

也可通过主脚本调用：

```bash
./deploy/deploy_cli.sh verify
```

## 4. 控制台一次初始化（内容模板 + 行动策略）

渲染后查看：

- `deploy/rendered/sls/notification.content.md`
- `deploy/rendered/sls/action.policy.dsl`
- `deploy/rendered/sls/console.bootstrap.md`

按 `console.bootstrap.md` 完成控制台初始化，再把 ID 回填到 `deploy/vars.env`。

## 5. 后续变更方式

只改模板文件和 `deploy/vars.env`，然后：

```bash
./deploy/render_templates.sh
./deploy/deploy_cli.sh etl
./deploy/deploy_cli.sh alert
```
