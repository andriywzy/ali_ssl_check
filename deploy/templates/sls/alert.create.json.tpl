{
  "name": "${SLS_ALERT_NAME}",
  "displayName": "${SLS_ALERT_DISPLAY_NAME}",
  "description": "${SLS_ALERT_DESCRIPTION}",
  "configuration": {
    "version": "2.0",
    "type": "default",
    "muteUntil": 0,
    "queryList": [
      {
        "project": "${SLS_PROJECT}",
        "store": "${SLS_TARGET_LOGSTORE}",
        "storeType": "log",
        "query": "__ALERT_QUERY_PLACEHOLDER__",
        "chartTitle": "expiring cert domains",
        "ui": "table"
      }
    ],
    "groupConfiguration": {
      "type": "default"
    },
    "joinConfigurations": [],
    "sendResolved": false,
    "autoAnnotation": true,
    "templateConfiguration": {
      "id": "${CONTENT_TEMPLATE_ID}",
      "type": "markdown",
      "lang": "zh"
    },
    "severityConfigurations": [
      {
        "severity": ${SLS_ALERT_SEVERITY},
        "evalCondition": {
          "condition": "$0 > 0",
          "countCondition": "__count__ > 0"
        }
      }
    ],
    "threshold": 1,
    "noDataFire": false,
    "noDataSeverity": 6,
    "policyConfiguration": {
      "alertPolicyId": "sls.builtin.dynamic",
      "actionPolicyId": "${ACTION_POLICY_ID}",
      "repeatInterval": "${SLS_ALERT_MUTE_FOR}"
    }
  },
  "schedule": {
    "type": "FixedRate",
    "interval": "${SLS_ALERT_EVAL_INTERVAL}",
    "runImmediately": true
  }
}
