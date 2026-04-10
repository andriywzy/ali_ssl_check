{
  "triggerName": "${FC_TRIGGER_TIMER_NAME}",
  "description": "timer trigger for domain inventory",
  "triggerType": "timer",
  "triggerConfig": {
    "cronExpression": "${FC_TRIGGER_TIMER_CRON_EXPRESSION}",
    "enable": ${FC_TRIGGER_TIMER_ENABLE},
    "payload": "${FC_TRIGGER_TIMER_PAYLOAD}"
  }
}
