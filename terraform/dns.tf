# Zone must exist before kubernetes/infra/kube-netbird-router.yaml's
# NetworkRouter (dnsZoneRef: proxy.rjst.de) is synced by ArgoCD, otherwise
# the router fails - see kubernetes/README.adoc.
resource "netbird_dns_zone" "proxy" {
  name   = "proxy.rjst.de"
  domain = "proxy.rjst.de"
}
