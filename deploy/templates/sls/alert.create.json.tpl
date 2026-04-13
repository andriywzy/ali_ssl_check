{
  "name": "${SLS_ALERT_NAME}",
  "displayName": "${SLS_ALERT_DISPLAY_NAME}",
  "type": "Alert",
  "status": "Enabled",
  "description": "${SLS_ALERT_DESCRIPTION}",
  "configuration": {
    "version": "2.0",
    "type": "default",
    "dashboard": "${SLS_ALERT_DASHBOARD}",
    "queryList": [
      {
        "storeType": "log",
        "region": "${ALIYUN_REGION}",
        "project": "${SLS_PROJECT}",
        "store": "${SLS_TARGET_LOGSTORE}",
        "query": "__ALERT_QUERY_PLACEHOLDER__",
        "timeSpanType": "${SLS_ALERT_QUERY_TIMESPAN_TYPE}",
        "start": "${SLS_ALERT_QUERY_START}",
        "end": "${SLS_ALERT_QUERY_END}",
        "powerSqlMode": "auto"
      }
    ],
    "groupConfiguration": {
      "type": "no_group",
      "fields": []
    },
    "joinConfigurations": [],
    "annotations": [
      {
        "key": "title",
        "value": "SSL 证书临期告警"
      },
      {
        "key": "desc",
        "value": "最近 1 天检测到临期证书域名，请查看告警结果明细。"
      }
    ],
    "sendResolved": false,
    "autoAnnotation": true,
    "templateConfiguration": {
      "id": "__CONTENT_TEMPLATE_ID__"
    },
    "severityConfigurations": [
      {
        "severity": ${SLS_ALERT_SEVERITY},
        "evalCondition": {
          "condition": "",
          "countCondition": ""
        }
      }
    ],
    "threshold": 1,
    "noDataFire": false,
    "noDataSeverity": 6,
    "policyConfiguration": {
      "alertPolicyId": "sls.builtin.dynamic",
      "actionPolicyId": "__ACTION_POLICY_ID__",
      "repeatInterval": "${SLS_ALERT_MUTE_FOR}",
      "useDefault": false
    }
  },
  "schedule": {
    "type": "FixedRate",
    "interval": "${SLS_ALERT_EVAL_INTERVAL}",
    "runImmediately": true
  }
}
