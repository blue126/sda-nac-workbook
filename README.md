# SD-Access NaC Workbook

A hands-on lab that builds a Cisco SD-Access fabric with Catalyst Center and ISE, driven by
Network as Code: the Terraform module [`netascode/nac-catalystcenter`](https://registry.terraform.io/modules/netascode/nac-catalystcenter/catalystcenter)
and YAML data files.

- **[WORKBOOK.md](WORKBOOK.md)** – the lab guide (Chinese): topology, addressing, and every task with goal, reasoning, config and verification.
- `main.tf` – provider and module wiring.
- `data/*.nac.yaml` – the fabric, one file per stage.

Task order follows Mason Reimert's SDA workbook v1.0; all values here match the author's own PNETLab lab.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in Catalyst Center credentials
terraform init
terraform plan -out stage1.tfplan
terraform apply stage1.tfplan
```

`terraform.tfvars` and state files are gitignored.
