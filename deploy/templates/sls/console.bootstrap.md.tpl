# SLS 控制台一次性初始化（内容模板 + 行动策略）

> 本步骤只做一次，后续告警规则走 CLI 更新。完成后，把 ID 回填到 `deploy/vars.env`。

## 1. 导入告警内容模板

1. 进入日志服务控制台 > 告警中心 > 通知管理 > 内容模板。
2. 新建模板，名称建议：`${CONTENT_TEMPLATE_ID}`。
3. 内容粘贴：`deploy/rendered/sls/notification.content.md`。
4. 保存后记录模板 ID，回填：
   - `CONTENT_TEMPLATE_ID=<控制台模板ID>`

## 2. 创建行动策略（短信/邮件）

1. 进入日志服务控制台 > 告警中心 > 通知管理 > 行动策略。
2. 新建行动策略，名称建议：`${ACTION_POLICY_ID}`。
3. DSL 可粘贴：`deploy/rendered/sls/action.policy.dsl`。
4. 配置短信/邮件接收对象与分组后保存。
5. 保存后记录行动策略 ID，回填：
   - `ACTION_POLICY_ID=<控制台行动策略ID>`

## 3. 回填并重新渲染模板

```bash
source deploy/vars.env
./deploy/render_templates.sh
```

## 4. 用 CLI 创建或更新告警

```bash
./deploy/deploy_cli.sh alert
```
