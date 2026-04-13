{
  "functionName": "${FC_DOMAIN_INVENTORY_FUNCTION_NAME}",
  "description": "domain inventory from alidns and authoritative dns",
  "runtime": "${FC_RUNTIME}",
  "handler": "domain_inventory.index.handler",
  "memorySize": ${FC_DOMAIN_INVENTORY_MEMORY_MB},
  "timeout": ${FC_DOMAIN_INVENTORY_TIMEOUT_SEC},
  "role": "${RAM_ROLE_ARN_DOMAIN_INVENTORY}",
  "logConfig": {
    "project": "${FC_LOG_PROJECT}",
    "logstore": "${FC_LOG_LOGSTORE}"
  },
  "code": {
    "ossBucketName": "${FC_CODE_OSS_BUCKET}",
    "ossObjectName": "${FC_CODE_OBJECT_PREFIX}/${FC_DOMAIN_INVENTORY_FUNCTION_NAME}.zip"
  },
  "environmentVariables": {
    "OSS_BUCKET": "${OSS_BUCKET}",
    "OSS_PREFIX": "${OSS_PREFIX}",
    "OSS_ENDPOINT": "${OSS_ENDPOINT}",
    "OSS_REGION": "${OSS_REGION}",
    "ALIDNS_REGION_ID": "${ALIDNS_REGION_ID}",
    "DNS_TIMEOUT_SEC": "${DNS_TIMEOUT_SEC}",
    "INVENTORY_CSV_OBJECT_KEY": "${INVENTORY_CSV_OBJECT_KEY}",
    "INVENTORY_SUMMARY_OBJECT_KEY": "${INVENTORY_SUMMARY_OBJECT_KEY}"
  }
}
