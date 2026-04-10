检测到临期证书域名。

总数：{{ len(alert.query_results[0].results) }}

| fqdn | days_remaining | not_after_utc |
| --- | ---: | --- |
{% for row in alert.query_results[0].results %}
| {{ row.fqdn }} | {{ row.days_remaining }} | {{ row.not_after_utc }} |
{% endfor %}
