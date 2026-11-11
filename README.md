# SD-Access NaC Workbook

A hands-on lab that builds a Cisco SD-Access fabric with Catalyst Center and ISE, driven by
Network as Code: the Terraform module [`netascode/nac-catalystcenter`](https://registry.terraform.io/modules/netascode/nac-catalystcenter/catalystcenter)
and YAML data files.

- **[WORKBOOK.md](WORKBOOK.md)** – the lab guide (Chinese): topology, addressing, and every task with goal, reasoning, config and verification.
- `main.tf` – provider and module wiring; the `stage` variable selects which YAML files are loaded.
- `data/*.nac.yaml` – the fabric, one file per stage.
- `data/00_fusion.nac.yaml`, `data/03_fusion_handoff.nac.yaml` – the fusion router (Catalyst 8000V, outside Catalyst Center), managed with [`netascode/nac-iosxe`](https://registry.terraform.io/modules/netascode/nac-iosxe/iosxe).

Tasks are ordered by build stage. The topology is based on Mason Reimert's SDA workbook v1.0; all values here match the author's own PNETLab lab.

## Quick start

```bash
cp .env.example .env              # fill in all credentials (gitignored)
set -a; source .env; set +a
terraform init
terraform plan -var stage=0 -out stage0.tfplan   # then stage=1, 2, 3
terraform apply stage0.tfplan
```

`.env`, `terraform.tfvars` and state files are gitignored.
