*
| where functionName = 'ssl_check'
| parse-regexp message, '(\{.*\})' as alert_json
| parse-json alert_json
| where event = 'certificate_below_threshold' and status = 'expiring'
| project
    __time__,
    fqdn,
    status,
    days_remaining,
    not_after_utc