{
  "name": "${SLS_ETL_NAME}",
  "displayName": "${SLS_ETL_DISPLAY_NAME}",
  "description": "${SLS_ETL_DESCRIPTION}",
  "configuration": {
    "lang": "SPL",
    "logstore": "${SLS_SOURCE_LOGSTORE}",
    "roleArn": "${SLS_ETL_ROLE_ARN}",
    "fromTime": ${SLS_ETL_FROM_TIME},
    "toTime": 0,
    "script": "__ETL_SPL_PLACEHOLDER__",
    "sinks": [
      {
        "name": "ssl-expiring-sink",
        "project": "${SLS_PROJECT}",
        "endpoint": "${ALIYUN_REGION}.log.aliyuncs.com",
        "logstore": "${SLS_TARGET_LOGSTORE}",
        "roleArn": "${SLS_ETL_ROLE_ARN}",
        "datasets": [
          "__UNNAMED__"
        ]
      }
    ]
  }
}
