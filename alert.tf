resource "google_monitoring_notification_channel" "email_notification" {
  display_name = "Email Notification"
  type         = "email"

  labels = {
    email_address = var.email_address
  }
}


resource "google_monitoring_alert_policy" "dataproc_queue_fast_burn_promql" {
  display_name = "Dataproc Queue Fast Burn Alert"
  combiner     = "OR"

  conditions {
    display_name = "Fast-burn queue: 14.4x burn rate detected (pending > 2 within ~4 min)"
    condition_prometheus_query_language {
      query                     = <<-EOT
(avg_over_time(dataproc_googleapis_com:cluster_yarn_apps{status="pending"}[1h]) > 2)
and
(avg_over_time(dataproc_googleapis_com:cluster_yarn_apps{status="pending"}[5m]) > 2)
EOT
      duration                  = "0s"
      disable_metric_validation = true
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_notification.name]

  documentation {
    content   = "YARN pending applications exceeded 2. This is a fast-burn alert: avg_over_time([1h]) with duration=0s fires within ~4 minutes once pending spikes, equivalent to a 14.4x burn rate (60 min / 4.17 min). The cluster cannot schedule new applications fast enough — likely resource exhaustion or a scheduling deadlock."
    mime_type = "text/markdown"
  }
}