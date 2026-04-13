# 模板化部署说明

本目录提供“参数文件 + 模板文件 + 渲染执行脚本”的完整部署方式，覆盖：

- FC 两个函数（`domain_inventory` / `ssl_checker`）
- SLS ETL 日志重写到新 Logstore
- SLS 告警规则
- 告警内容模板、行动策略（脚本自动创建/更新）

## 1. 准备参数

```bash
cp deploy/templates/vars.env.tpl deploy/vars.env
```

编辑 `deploy/vars.env`，至少确认以下变量：

- `OSS_BUCKET`, `OSS_PREFIX`
- `ACCOUNT_ID`
- `FC_RUNTIME`（FC3 推荐 `python3.12`）
- `FC_LOG_PROJECT`, `FC_LOG_LOGSTORE`
- `SLS_PROJECT`, `SLS_PROJECT_DESCRIPTION`
- `SLS_SOURCE_LOGSTORE`, `SLS_TARGET_LOGSTORE`
- `CONTENT_TEMPLATE_ID=ssl-check`
- `CONTENT_TEMPLATE_NAME=证书临期模版`
- `ACTION_POLICY_ID=ssl-check-action`
- `ACTION_POLICY_NAME=证书临期行动策略`
- `ALERT_CONTACT_GROUP_NAME=Default Contact Group`（可选填 `ALERT_CONTACT_GROUP_ID`）
- `SLS_ALERT_QUERY_TIMESPAN_TYPE=Relative`
- `SLS_ALERT_QUERY_START=-1d`
- `SLS_ALERT_QUERY_END=absolute`
- `SLS_ALERT_EVAL_INTERVAL=1d`
- `SLS_ALERT_DASHBOARD=internal-alert-analysis`

## 2. 渲染模板

```bash
source deploy/vars.env
./deploy/render_templates.sh
```

渲染输出目录：`deploy/rendered/`

## 3. 分阶段执行 CLI

```bash
./deploy/deploy_cli.sh ram
./deploy/deploy_cli.sh sls
./deploy/deploy_cli.sh fc
./deploy/deploy_cli.sh invoke
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

## 4. 自动创建告警模板与行动策略

`deploy_cli.sh alert` 会自动执行：

- 读取 `deploy/rendered/sls/notification.content.md`
- 读取 `deploy/rendered/sls/action.policy.dsl`
- 通过 SLS Resource API upsert：
  - `sls.alert.content_template`（`CONTENT_TEMPLATE_ID` + `CONTENT_TEMPLATE_NAME`）
  - `sls.alert.action_policy`（`ACTION_POLICY_ID` + `ACTION_POLICY_NAME`）
- 自动解析联系人组并关联到行动策略（默认 `Default Contact Group`）
- 然后创建或更新告警规则

前置依赖：

```bash
python3 -m pip install aliyun-log-python-sdk
```

如果你仍想走控制台手工方式，可参考：

- `deploy/rendered/sls/console.bootstrap.md`

## 5. 后续变更方式

只改模板文件和 `deploy/vars.env`，然后：

```bash
./deploy/render_templates.sh
./deploy/deploy_cli.sh sls
./deploy/deploy_cli.sh etl
./deploy/deploy_cli.sh alert
```

说明：`deploy_cli.sh etl` 会先自动执行 `sls` 资源预检（Project + source/target Logstore），并打印 ETL payload 实际使用的 source/target logstore 名称，便于排查变量配置问题。
脚本会在提交 SLS 请求前自动把模板 JSON 压缩成单行标准 JSON，避免 body 格式导致的 `LogStoreInfoInvalid`。
告警查询默认输出明细，最终提交给 SLS 的时间窗口会统一规整为 `Truncated / -1d / absolute`，固定间隔为 `1d`，避免旧变量导致控制台展示异常。

推荐告警创建顺序（避免“有告警无查询统计”）：

1. `./deploy/deploy_cli.sh invoke` 先产生日志。
2. `./deploy/deploy_cli.sh etl` 把 `expiring` 写入目标 Logstore。
3. 在目标 Logstore 用查询验证最近 1 天有数据：
   - `* | where status = "expiring" | select count(1)`
4. `./deploy/deploy_cli.sh alert` 创建/更新告警规则。
