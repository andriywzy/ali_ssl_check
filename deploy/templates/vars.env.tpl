# 复制本文件为 deploy/vars.env 并按实际资源填写。
# 使用前执行：source deploy/vars.env

# -------------------------------
# 基础配置
# -------------------------------
export ALIYUN_REGION="cn-hangzhou"
export ALIYUN_PROFILE="default"

# -------------------------------
# OSS（业务产物）
# -------------------------------
export OSS_BUCKET="your-oss-bucket"
export OSS_PREFIX="ssl-check"
export OSS_ENDPOINT="https://oss-cn-hangzhou.aliyuncs.com"
export OSS_REGION="cn-hangzhou"
export ALIDNS_REGION_ID="cn-hangzhou"

# -------------------------------
# FC 代码包（上传到 OSS 后由 FC 拉取）
# -------------------------------
export DOMAIN_INVENTORY_PACKAGE_PATH="dist/domain_inventory.zip"
export SSL_CHECKER_PACKAGE_PATH="dist/ssl_checker.zip"
export FC_CODE_OSS_BUCKET="${OSS_BUCKET}"
export FC_CODE_OBJECT_PREFIX="${OSS_PREFIX}/fc-code"

# -------------------------------
# RAM（角色与策略）
# -------------------------------
export ACCOUNT_ID="1234567890123456"
export RAM_ROLE_DOMAIN_INVENTORY="fc-domain-inventory-role"
export RAM_ROLE_SSL_CHECKER="fc-ssl-checker-role"
export RAM_POLICY_DOMAIN_INVENTORY="fc-domain-inventory-policy"
export RAM_POLICY_SSL_CHECKER="fc-ssl-checker-policy"
export RAM_ROLE_ARN_DOMAIN_INVENTORY="acs:ram::${ACCOUNT_ID}:role/${RAM_ROLE_DOMAIN_INVENTORY}"
export RAM_ROLE_ARN_SSL_CHECKER="acs:ram::${ACCOUNT_ID}:role/${RAM_ROLE_SSL_CHECKER}"

# -------------------------------
# FC3 Function
# -------------------------------
export FC_LOG_PROJECT="your-sls-project"
export FC_LOG_LOGSTORE="your-fc-logstore"
export FC_RUNTIME="python3.12"

export FC_DOMAIN_INVENTORY_FUNCTION_NAME="domain_inventory"
export FC_SSL_CHECKER_FUNCTION_NAME="ssl_checker"

export FC_DOMAIN_INVENTORY_MEMORY_MB="512"
export FC_DOMAIN_INVENTORY_TIMEOUT_SEC="300"
export FC_SSL_CHECKER_MEMORY_MB="1024"
export FC_SSL_CHECKER_TIMEOUT_SEC="600"

# FC 定时触发器（可选）
export FC_TRIGGER_TIMER_ENABLED="false"
export FC_TRIGGER_TIMER_NAME="domain-inventory-timer"
export FC_TRIGGER_TIMER_CRON_EXPRESSION="@every 24h"
export FC_TRIGGER_TIMER_ENABLE="true"
export FC_TRIGGER_TIMER_PAYLOAD="{}"

# -------------------------------
# SSL 检测参数（函数环境变量）
# -------------------------------
export EXPIRY_THRESHOLD_DAYS="10"
export SSL_PORT="443"
export DNS_TIMEOUT_SEC="5"
export TLS_TIMEOUT_SEC="8"
export CHECK_CONCURRENCY="20"

# 固定对象路径（与你当前实现保持一致）
export INVENTORY_CSV_OBJECT_KEY="${OSS_PREFIX}/inventory/domains.csv"
export INVENTORY_SUMMARY_OBJECT_KEY="${OSS_PREFIX}/inventory/summary.json"
export SSL_REPORT_CSV_OBJECT_KEY="${OSS_PREFIX}/ssl-report/ssl_report.csv"
export SSL_REPORT_SUMMARY_OBJECT_KEY="${OSS_PREFIX}/ssl-report/summary.json"

# -------------------------------
# SLS：日志重写（ETL）
# -------------------------------
export SLS_PROJECT="your-sls-project"
export SLS_SOURCE_LOGSTORE="your-fc-logstore"
export SLS_PROJECT_DESCRIPTION="ssl check observability project"
export SLS_SOURCE_LOGSTORE_TTL_DAYS="30"
export SLS_SOURCE_LOGSTORE_SHARD_COUNT="2"
export SLS_TARGET_LOGSTORE="ssl-expiring-alerts"
export SLS_TARGET_LOGSTORE_TTL_DAYS="30"
export SLS_TARGET_LOGSTORE_SHARD_COUNT="2"

export SLS_ETL_NAME="ssl-expiring-etl"
export SLS_ETL_DISPLAY_NAME="SSL Expiring Rewrite"
export SLS_ETL_DESCRIPTION="rewrite expiring ssl logs into dedicated logstore"
export SLS_ETL_FROM_TIME="0"
export SLS_ETL_ROLE_ARN="acs:ram::${ACCOUNT_ID}:role/aliyunlogetlrole"

# -------------------------------
# SLS：告警规则
# -------------------------------
export SLS_ALERT_NAME="ssl-cert-expiring-alert"
export SLS_ALERT_DISPLAY_NAME="SSL Certificate Expiring Alert"
export SLS_ALERT_DESCRIPTION="alert for expiring ssl certificates"
export SLS_ALERT_SEVERITY="6"
export SLS_ALERT_EVAL_INTERVAL="1d"
export SLS_ALERT_MUTE_FOR="5m"
export SLS_ALERT_DASHBOARD="internal-alert-analysis"
export SLS_ALERT_QUERY_TIMESPAN_TYPE="Truncated"
export SLS_ALERT_QUERY_START="-1d"
export SLS_ALERT_QUERY_END="absolute"

# 告警资源标识与名称（脚本会创建或更新）
export CONTENT_TEMPLATE_ID="ssl-check"
export CONTENT_TEMPLATE_NAME="证书临期模版"
export ACTION_POLICY_ID="ssl-check-action"
export ACTION_POLICY_NAME="证书临期行动策略"

# 通知目标（默认联系人组）
# 优先使用 ALERT_CONTACT_GROUP_ID；为空时按 ALERT_CONTACT_GROUP_NAME 自动解析 ID。
export ALERT_CONTACT_GROUP_ID=""
export ALERT_CONTACT_GROUP_NAME="Default Contact Group"
