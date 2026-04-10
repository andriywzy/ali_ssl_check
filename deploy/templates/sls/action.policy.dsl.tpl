fire(type="sms", users=${ALERT_SMS_USERS_JSON}, groups=${ALERT_SMS_GROUPS_JSON}, template_id="${CONTENT_TEMPLATE_ID}", period="any")
fire(type="email", users=${ALERT_EMAIL_USERS_JSON}, groups=${ALERT_EMAIL_GROUPS_JSON}, template_id="${CONTENT_TEMPLATE_ID}", period="any")
