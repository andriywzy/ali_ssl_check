* | where status = "expiring" | select cast(days_remaining as bigint) as days_remaining, fqdn, not_after_utc order by days_remaining asc limit 1000
