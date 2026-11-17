output "url" {
  description = "In-cluster URL of the Prometheus server (plain HTTP inside the namespace; reach it through Grafana or a port-forward)."
  value       = "http://prometheus-server.${var.namespace}.svc:80"
}
