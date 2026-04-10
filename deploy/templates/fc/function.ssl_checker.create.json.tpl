{
  "functionName": "${FC_SSL_CHECKER_FUNCTION_NAME}",
  "description": "ssl checker from oss inventory csv",
  "runtime": "${FC_RUNTIME}",
  "handler": "ssl_checker.index.handler",
  "memorySize": ${FC_SSL_CHECKER_MEMORY_MB},
  "timeout": ${FC_SSL_CHECKER_TIMEOUT_SEC},
  "role": "${RAM_ROLE_ARN_SSL_CHECKER}",
  "code": {
    "ossBucketName": "${FC_CODE_OSS_BUCKET}",
    "ossObjectName": "${FC_CODE_OBJECT_PREFIX}/${FC_SSL_CHECKER_FUNCTION_NAME}.zip"
  },
  "environmentVariables": {
    "OSS_BUCKET": "${OSS_BUCKET}",
    "OSS_PREFIX": "${OSS_PREFIX}",
    "OSS_ENDPOINT": "${OSS_ENDPOINT}",
    "OSS_REGION": "${OSS_REGION}",
    "EXPIRY_THRESHOLD_DAYS": "${EXPIRY_THRESHOLD_DAYS}",
    "SSL_PORT": "${SSL_PORT}",
    "TLS_TIMEOUT_SEC": "${TLS_TIMEOUT_SEC}",
    "CHECK_CONCURRENCY": "${CHECK_CONCURRENCY}",
    "INVENTORY_CSV_OBJECT_KEY": "${INVENTORY_CSV_OBJECT_KEY}",
    "INVENTORY_SUMMARY_OBJECT_KEY": "${INVENTORY_SUMMARY_OBJECT_KEY}",
    "SSL_REPORT_CSV_OBJECT_KEY": "${SSL_REPORT_CSV_OBJECT_KEY}",
    "SSL_REPORT_SUMMARY_OBJECT_KEY": "${SSL_REPORT_SUMMARY_OBJECT_KEY}"
  }
}
