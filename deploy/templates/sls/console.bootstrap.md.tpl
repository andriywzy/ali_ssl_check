# SLS 控制台手工初始化（可选）

> 默认推荐使用 `deploy_cli.sh alert` 自动创建资源。本文件仅用于手工回退。

## 1. 导入告警内容模板

1. 进入日志服务控制台 > 告警中心 > 通知管理 > 内容模板。
2. 新建模板，名称建议：`${CONTENT_TEMPLATE_NAME}`。
3. 内容粘贴：`deploy/rendered/sls/notification.content.md`。
4. 保存模板。

## 2. 创建行动策略（短信/邮件）

1. 进入日志服务控制台 > 告警中心 > 通知管理 > 行动策略。
2. 新建行动策略，名称建议：`${ACTION_POLICY_NAME}`。
3. DSL 可粘贴：`deploy/rendered/sls/action.policy.dsl`。
4. 配置短信/邮件接收对象与分组后保存。

## 3. 重新渲染模板

```bash
source deploy/vars.env
./deploy/render_templates.sh
```

## 4. 用 CLI 创建或更新告警（自动解析真实 ID）

```bash
./deploy/deploy_cli.sh alert
```
