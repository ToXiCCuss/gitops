# Zone must exist before kubernetes/infra/kubectl/kube-netbird-router.yaml's
# NetworkRouter (dnsZoneRef: k8sdev.rjst.de) is synced by ArgoCD, otherwise
# the router fails - see kubernetes/README.adoc.
resource "netbird_dns_zone" "proxy" {
  name   = "k8sdev.rjst.de"
  domain = "k8sdev.rjst.de"
}
