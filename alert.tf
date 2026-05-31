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
    display_name = "Sustained Queue build up for 1h AND Active Queue build up for 5min"
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
    content   = "YARN pending applications have exceeded 2 for over an hour and are still actively queuing. The cluster is unable to scale fast enough or is deadlocked."
    mime_type = "text/markdown"
  }
}