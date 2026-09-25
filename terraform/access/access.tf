# The groups are created by the NetBird operator
# (kubernetes/infra/kubectl/kube-netbird-access.yaml), so `infra` must have synced
# before this can be applied - the lookups fail otherwise.
data "netbird_group" "clients" {
  name = "kubernetes-clients"
}

data "netbird_group" "services" {
  name = "kubernetes-services"
}

# Ports of the exposed apps: 80 (ArgoCD, Grafana, Harbor, AKHQ), 4005 (Databasus),
# 7007 (Backstage), 8080 (Jenkins, Apicurio Registry), 8200 (Vault).
resource "netbird_policy" "kubernetes_access" {
  name        = "kubernetes-access"
  description = "kubernetes-clients may reach the exposed Kubernetes services"
  enabled     = true

  rule {
    name          = "kubernetes-access-tcp"
    action        = "accept"
    bidirectional = false
    enabled       = true
    protocol      = "tcp"
    sources       = [data.netbird_group.clients.id]
    destinations  = [data.netbird_group.services.id]
    ports         = ["80", "4005", "7007", "8080", "8200"]
  }
}
