# Bookstore — Full-Stack MERN Application : Azure 3-Tier IaaS + Physical Homelab
A self-hosted bookstore app deployed two ways: once on a 4-machine physical LAN, and once on Azure | both documented end-to-end.

![Azure 3_Tier-Bookstore](3_tier_bookstore.svg)

## Azure 3-Tier IaaS Architecture

**Medium series:** [https://medium.com/@guptetanish/3-tier-azure-iaas-mern-bookstore-part-1-network-foundation-vnet-subnets-nsgs-bastion-ff0edd697a62]

Traffic flow:
Internet → Application Gateway (WAF) → Web VMSS (Nginx) → Internal Load Balancer → App VMSS (Node.js) → CosmosDB (private endpoint, no public IP)

Key decisions:
- Zero public IPs on app or database tier | all internal traffic via private IPs
- VMSS instances self-configure on boot via startup scripts + Key Vault (no secrets in image)
- UAMI-based auth for Key Vault and Blob Storage — no stored credentials anywhere
- NAT Gateway handles outbound internet from web and app subnets 
- ILB health probes require explicit AzureLoadBalancer NSG rule | learned the hard way when => app VMSS instances showed unhealthy despite the Node.js process running correctly


## Distributed Homelab | 4-Machine Physical LAN


**Medium series:** [https://medium.com/@guptetanish/from-localhost-to-lan-mern-application-on-a-4-machine-lan-part-0-architecture-and-design-927d79b3c147]

4-machine physical network running the same MERN bookstore application:
Nginx (TLS + LB) => 2x Node.js app servers => MongoDB Atlas

Key decisions:
- Nginx handles both TLS termination and round-robin load balancing on a single machine
- UFW per-source allowlists instead of broad port rules
- Node.js runs as a dedicated system user with no shell (mirrors Azure least-privilege pattern)
- Centralised Prometheus + Grafana via Docker Compose; Docker/UFW iptables bypass resolved with ufw-docker