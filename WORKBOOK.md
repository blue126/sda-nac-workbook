# SD-Access Lab Workbook（Network as Code 版）

用 Catalyst Center + ISE 搭一个 SD-Access fabric。Task 7 起不点 GUI，用 Terraform 模块 `netascode/nac-catalystcenter` 0.6.0 加 YAML 下发。任务顺序参考 Mason Reimert 的 SDA workbook v1.0。**所有参数以现网为准**，和原 workbook 不同的地方在「现网差异」里写明。

状态：✅ 完成 ⏳ 进行中 ⬜ 未开始

## 0. 环境

### 拓扑

```
            家庭网关 OpenWrt 192.168.1.1（上网 / DNS）
                         │ 192.168.1.0/24（CatC .133、ISE .221、PNETLab .251）
                    e0/0 │ .99
                    ┌──────────┐
                    │ FUSION-1 │ AS 650002，DHCP / DNS 转发
                    └──────────┘
          e0/1 10.0.1.1 │      │ e0/2 10.0.2.1
                        │      │（BGP，GRT）
             HQ-BCP-1 ──┘      └── HQ-BCP-2      Border + Control Plane，AS 650003
                 │    ╲      ╱    │
             HQ-IN-1        HQ-IN-2              Intermediate（只跑 underlay）
                 │    ╱      ╲    │
             HQ-EDGE-1        HQ-EDGE-2          Edge
                 │                │
              WS-1-bob         WS-2-joe          Linux 客户端（802.1X）
```

### 平台

| 项 | 值 |
|---|---|
| 仿真平台 | PNETLab `192.168.1.251`，lab 文件 `/opt/unetlab/labs/sda-workbook/sda-workbook-catc323.unl`；仓库副本 [lab/sda-workbook-catc323.unl](lab/sda-workbook-catc323.unl)（启动配置里的 `enable secret` 已换成 `CHANGEME`，导入后自行修改） |
| 镜像 | 交换机 `cat9kvuadp-17.15.03`（4 vCPU / 18 GB）；FUSION-1 IOL `L3-AdvEnterpriseK9-M2 15.7(3)`；客户端 `linux-ubuntu-server-20.04`（需自备镜像） |
| Catalyst Center | `https://192.168.1.133`（2.3.x） |
| ISE | `ise.ccie.local` / `192.168.1.221`（standalone，PAN/MnT/PSN/pxGrid 同一节点） |
| 控制台 | `ssh ubuntu@192.168.1.251`，`~/con.py <port> <wait> "cmd" ...`（FUSION-1 = 30016） |
| 域名 | `ccie.local`：家庭网关 dnsmasq 上有 `ise.ccie.local → 192.168.1.221`（CatC 集成 ISE 时要能解析 ISE 的 FQDN） |

### 地址规划

| 用途 | 地址 |
|---|---|
| 管理 / 共享服务 | 192.168.1.0/24 |
| Fusion ↔ Border underlay | 10.0.1.0/30（BCP-1）、10.0.2.0/30（BCP-2） |
| Border ↔ Intermediate | 172.16.11/12/21/22.0/24（BCP-1–IN-1、BCP-1–IN-2、BCP-2–IN-1、BCP-2–IN-2） |
| Intermediate ↔ Edge | 172.17.11/12/21/22.0/24（IN-1–EN-1、IN-1–EN-2、IN-2–EN-1、IN-2–EN-2） |
| Loopback0（RLOC） | BCP-1/2 9.9.9.11/.12，IN-1/2 9.9.9.21/.22，EDGE-1/2 9.9.9.31/.32 |
| Global pool `SDA-Campus` | 10.254.0.0/16 |
| VLAN 100 客户端（anycast GW .1） | 10.254.100.0/24 |
| L3 handoff BCP-1 / BCP-2（VLAN 101 / 102） | 10.254.251.0/30、10.254.252.0/30 |

### NaC 工具链

| 项 | 值 |
|---|---|
| Terraform | ≥ 1.15（本机 1.17.1） |
| Provider | `CiscoDevNet/catalystcenter` ~> 0.6.6 |
| 模块 | `netascode/nac-catalystcenter/catalystcenter` 0.6.0，读 `data/*.nac.yaml` |
| 校验 | `nac-validate data/`（无 schema 时只查语法） |
| 凭据 | `terraform.tfvars`（已 gitignore，不进仓库） |

首次使用：

```bash
cp terraform.tfvars.example terraform.tfvars   # 填入 CatC 的用户名、密码
terraform init
```

之后每个阶段：

```bash
terraform plan -out stageN.tfplan
terraform apply stageN.tfplan
```

- 不想把密码写进文件：`terraform.tfvars` 里不填用户名和密码，改用环境变量 `CC_USERNAME` / `CC_PASSWORD`（provider 只认这两个名字），可以从密码管理器临时取，例如 `CC_PASSWORD=$(bw get password <条目>) terraform plan ...`。
- **本实验是 greenfield**：从一台刚部署好、只完成了 Task 1–6 的 CatC 开始，站点、地址池、fabric 等全部由 Terraform 创建，不在 GUI 里手工建。
- `terraform.tfstate` 也已 gitignore：state 里有 CatC 返回的对象 ID 等信息，放进公开仓库不合适。

> 注意：Terraform 要在沙箱外跑（Go TLS 不认沙箱代理证书，插件也起不来）。

#### 模块怎么保证顺序：两道「闸」

`terraform plan` 里会看到几个不对应任何 CatC 对象的资源：`terraform_data.before_fabric_template_deployments`、`terraform_data.fabric_configuration_complete` 和几个 `time_sleep`。`terraform_data` 是 Terraform 自带的空资源，只存在于 state 里，模块用它当**闸门**控制先后：

```
前置模板 → 闸 1 → 建 fabric → 闸 2 → 后置模板
```

**闸 1**：所有「建 fabric 之前要推的模板」推完，闸才开（[cc_templates.tf#L661-L665](https://github.com/netascode/terraform-catalystcenter-nac-catalystcenter/blob/v0.6.0/cc_templates.tf#L661-L665)）：

```hcl
resource "terraform_data" "before_fabric_template_deployments" {
  input = {
    for key, deployment in catalystcenter_deploy_template.regular_template_deploy_before_fabric : key => deployment.id
  }
}
```

fabric site 依赖这一道闸，不用逐个依赖每个模板部署（[cc_fabric.tf#L260-L267](https://github.com/netascode/terraform-catalystcenter-nac-catalystcenter/blob/v0.6.0/cc_fabric.tf#L260-L267)）：

```hcl
resource "catalystcenter_fabric_site" "fabric_site" {
  # ...
  depends_on = [ /* building、AAA 设置等 */, terraform_data.before_fabric_template_deployments]
}
```

**闸 2**：fabric 的所有资源（transit、VN、anycast gateway、fabric 设备、L3 handoff……）建完，闸才开（[cc_fabric.tf#L1388-L1425](https://github.com/netascode/terraform-catalystcenter-nac-catalystcenter/blob/v0.6.0/cc_fabric.tf#L1388-L1425)）：

```hcl
resource "terraform_data" "fabric_configuration_complete" {
  depends_on = [
    catalystcenter_transit_network.transit,
    catalystcenter_fabric_l3_virtual_network.l3_vn,
    catalystcenter_anycast_gateway.anycast_gateway,
    catalystcenter_fabric_device.border_device,
    # ……共三十多项
  ]
}
```

「建 fabric 之后才推」的模板依赖闸 2，所以一定等 fabric 全部建完（[cc_templates.tf#L667-L709](https://github.com/netascode/terraform-catalystcenter-nac-catalystcenter/blob/v0.6.0/cc_templates.tf#L667-L709)）：

```hcl
resource "catalystcenter_deploy_template" "regular_template_deploy_after_fabric" {
  # ...
  depends_on = [ /* provision 等 */, terraform_data.fabric_configuration_complete]
}
```

本实验没有模板，两道闸都是空的，一建就开。`time_sleep.provision_device_wait` 则是 provision 之后固定等一会儿，让 CatC 处理完任务。state 里那些 `*_validation` 也是 `terraform_data`，带 precondition，配置会造成危险改动（比如误删 VN）时让 plan 直接报错。

---

## Part 1 – Underlay 与设备纳管（CLI）

### ✅ Task 1 – 数据中心路由

**目标**：共享服务网段能被 fusion 学到。

**现网差异**：没有 DC-SW-1。共享服务（CatC、ISE）直接在家庭网段 192.168.1.0/24，FUSION-1 e0/0 接入，默认路由指向 192.168.1.1，BGP 里 `network 192.168.1.0` 宣告。

### ✅ Task 2 – Fusion 路由

**目标**：Fusion（AS 650002）和两台 border（AS 650003）在 GRT 建 eBGP，只做 underlay 可达，不涉及 overlay VN。

```
router bgp 650002
 network 192.168.1.0
 neighbor 10.0.1.2 remote-as 650003
 neighbor 10.0.2.2 remote-as 650003
```

**验证**：`show ip bgp summary`，两个邻居 Established。

### ✅ Task 3 – Fabric 内部 underlay

**目标**：所有 fabric 内链路和 Loopback0 跑 IS-IS，loopback 全互通。

**原理**：SD-Access 的 underlay 只要求 RLOC（Loopback0 /32）可达、MTU 足够（VXLAN 多 50 字节）。IS-IS 是 LAN Automation 默认用的协议，不依赖 IP 就能起邻居。

**验证**：`show isis neighbors`；从任意节点 `ping 9.9.9.x source lo0`。

### ✅ Task 4 – 重分发

**目标**：border 上 IS-IS ↔ BGP 双向重分发，并把 border 自己的 loopback 宣告进 BGP（它们是本地直连，不会经 IS-IS 重分发出来）。

**验证**：从 edge 的 Loopback0 ping 通 CatC 和 ISE。

### ✅ Task 5 – 设备引导

**目标**：让 CatC 能纳管 BCP / EDGE 节点。每台配置：

- SNMP RW community
- `aaa new-model`，exec authorization 方法列表
- 本地最高权限用户（用户名、密码见 Bitwarden，**不写进本文件**）
- VTY 只允许 SSH、本地认证、privilege 15
- `netconf-yang`
- hostname，`ip domain name ccie.local`

### ✅ Task 6 – 发现设备

**目标**：用 CatC Discovery 把 fabric 设备加入 inventory，勾选 NETCONF。

**现网**：六台都在 inventory 里（BCP-1/2、IN-1/2、EDGE-1/2）。

---

## Part 2 – 站点与网络设置（NaC）

### ✅ Task 7 – 网络层级

**目标**：Area `USA` → Building `SDA-Campus`。

**文件**：`data/01_sites_pools.nac.yaml`

```yaml
catalyst_center:
  sites:
    areas:
      - name: USA
        buildings:
          - name: SDA-Campus
            country: United States   # provider 必填
            latitude: 37.41          # CatC 要求经纬度或地址二选一（NCND10502）
            longitude: -121.95
```

**原理**：模块把树展开成 `Global/USA`、`Global/USA/SDA-Campus`。`managed_sites` 为空且 `manage_global_settings: false` 时，YAML 里出现的所有站点都会被管理。

### ✅ Task 8 – 集成 ISE

**目标**：ISE 开 pxGrid，CatC 里加 ISE 为 AAA/PAN，重新 provision 后设备出现在 ISE 的 Network Devices 里。

**NaC**：`ise.tf`（直接用 provider 资源，不走模块）

- `catalystcenter_authentication_policy_server`：把 ISE 加为 AAA/PAN，RADIUS 1812/1813，启用 pxGrid；`cisco_ise_dtos` 里带 ISE 的 FQDN 和管理员账号，CatC 用它登录 ISE 建立信任。
- `catalystcenter_integrate_ise`：接受 ISE 证书，完成 pxGrid 握手。
- 凭据来自 `terraform.tfvars` 的 `ise_*` 变量，变量声明为 `ephemeral`，并用 write-only 参数（`*_wo`）下发：值发给 CatC，但**不写进 state**。改了密码就把 `ise_secrets_version` 加 1。

**为什么不用模块**：模块 0.6.0 在 `cc_system_settings.tf` 里组装了 ISE 的用户名、密码、FQDN（`local.cisco_ise_dtos`），但没有传给资源，结果 CatC 里有 ISE 条目却连不上 ISE。

**前提**：ISE 上开启 pxGrid 服务；ISE 的 FQDN 能被 CatC 解析。

**验证**：CatC → System → Settings → Authentication and Policy Servers，ISE 状态 ACTIVE；ISE → pxGrid Services 里 CatC 客户端已批准。Task 10 provision 之后，设备出现在 ISE 的 Network Devices 里。

### ✅ Task 9 – Building 的 AAA 设置

**目标**：SDA-Campus 的 client AAA 指向 ISE `192.168.1.221`。

**NaC**：`data/02_aaa_devices.nac.yaml`

```yaml
            network_settings:
              client_and_endpoint_aaa:
                server_type: ISE
                protocol: RADIUS
                primary_ip: 192.168.1.221
```

只设 client/endpoint AAA（802.1X 认证用户和终端）；设备登录的 network AAA 本实验不配。ISE 必须先集成（Task 8），否则 CatC 拒绝把它设为 AAA。

### ✅ Task 11 – IP 地址池

**目标**：Global pool `SDA-Campus` 10.254.0.0/16，Building 下预留三个子池。

```yaml
catalyst_center:
  sites:
    global:
      network_settings:
        ip_pools:
          - name: SDA-Campus
            ip_address_space: IPv4
            ip_pool_cidr: 10.254.0.0/16
    areas:
      - name: USA
        buildings:
          - name: SDA-Campus
            network_settings:
              ip_pools_reservations:
                - name: SDA-Campus-VLAN-100
                  global_pool: SDA-Campus
                  subnet: 10.254.100.0
                  prefix_length: 24
                  gateway: 10.254.100.1
                  dhcp_servers: [192.168.1.99]
                  dns_servers: [192.168.1.99]
                - name: SDA-Campus-L3-Handoff-1
                  global_pool: SDA-Campus
                  subnet: 10.254.251.0
                  prefix_length: 30
                - name: SDA-Campus-L3-Handoff-2
                  global_pool: SDA-Campus
                  subnet: 10.254.252.0
                  prefix_length: 30
```

**现网差异**：原 workbook 的客户端用静态 IP。这里改为 DHCP，服务器放在 FUSION-1（见下）。

#### 附：FUSION-1 上的 DHCP / DNS（✅ 已配置并保存）

**为什么放在 fusion**：SD-Access 的 DHCP 服务器一般在 fabric 外的共享服务区。流程：

1. Edge 作为 relay，GIADDR 填 anycast gateway（10.254.100.1），插入 option 82（含 edge 的 RLOC）；
2. 服务器按 GIADDR 选池，回包时**原样带回 option 82**；
3. Border 收到回包，根据 option 82 里的 RLOC 送回正确的 edge（因为所有 edge 共用同一个 GIADDR）。

所以服务器必须支持回显 option 82，且有到 10.254.100.0/24 的路由（Task 16 之后经 handoff 学到）。家庭网关的 dnsmasq 对 option 82 子选项的兼容性不确定，没采用。

```
ip dhcp excluded-address 10.254.100.1 10.254.100.9
ip dhcp pool CORP-VLAN-100
 network 10.254.100.0 255.255.255.0
 default-router 10.254.100.1
 dns-server 192.168.1.99
 domain-name ccie.local
 lease 0 12
ip domain lookup
ip name-server 192.168.1.1
ip dns server
```

**验证**：`show ip dhcp pool`；Task 17 之后 `show ip dhcp binding`。

### ✅ Task 10 – 设备分配到站点并 provision

**目标**：六台设备分配到 SDA-Campus 并 provision。

**NaC**：`data/02_aaa_devices.nac.yaml` 的 `inventory.devices`

| 设备 | 角色 | 状态 |
|---|---|---|
| HQ-BCP-1/2 | BORDER ROUTER | PROVISION |
| HQ-EDGE-1/2 | ACCESS | PROVISION |
| HQ-IN-1/2 | DISTRIBUTION | ASSIGN（只跑 underlay，分配到站点但不 provision） |

- 模块按 CatC 里的 hostname 找设备。设备配了 `ip domain name ccie.local`，CatC 显示的是 `HQ-BCP-1.ccie.local`，所以用 `fqdn_name` 写全名，`name` 写短名。
- `device_ip` 是发现时用的 Loopback0。
- provision 会把站点的网络设置（AAA、DHCP/DNS 等）推到设备上，这一步之后设备出现在 ISE 的 Network Devices 里。

**执行顺序**：AAA 依赖 ISE 已集成，首次先单独 apply ISE：

```bash
terraform apply -target=catalystcenter_integrate_ise.ise
terraform plan -out stage2.tfplan
terraform apply stage2.tfplan
```

**验证**：Inventory 里 4 台 fabric 节点 Provision Status 为 Success；`show run | s aaa|radius` 能看到 ISE。

---

## Part 3 – Fabric（NaC）

所有 fabric 内容放在 `fabric.fabric_sites[]` 下。

### ⬜ Task 12 – Fabric site

**目标**：SDA-Campus 建 fabric site，认证模板 Closed Authentication，控制平面用 LISP/BGP（`pub_sub_enabled: false`，模块默认值）。

### ⬜ Task 13 – Transit

**目标**：IP-based transit `TO-FUSION`，AS 650002（模块默认 IP_BASED_TRANSIT + BGP）。

### ⬜ Task 14 – VN

**目标**：L3 VN `CORP`，关联 fabric site。

### ⬜ Task 15 – Fabric 设备角色与 L3 handoff

| 设备 | 角色 | Handoff |
|---|---|---|
| HQ-BCP-1 | Border + Control Plane | VLAN 101，L3-Handoff-1，local AS 650003 → 650002 |
| HQ-BCP-2 | Border + Control Plane | VLAN 102，L3-Handoff-2，local AS 650003 → 650002 |
| HQ-EDGE-1/2 | Edge | — |

要点：不勾选「Do not import internal routes」；handoff 里要同时选 transit、外部接口和 IP pool。

### ⬜ Task 16 – Fusion 侧 handoff（CLI）

**目标**：FUSION-1 上建 .101 / .102 子接口，和两台 border 建 BGP。fusion 侧不做 VRF：GRT 的路由全部漏进 CORP VN。

```
interface Ethernet0/? .101
 encapsulation dot1Q 101
 ip address 10.254.251.2 255.255.255.252
interface Ethernet0/? .102
 encapsulation dot1Q 102
 ip address 10.254.252.2 255.255.255.252
router bgp 650002
 neighbor 10.254.251.1 remote-as 650003
 neighbor 10.254.252.1 remote-as 650003
```

`[接口编号、border 侧地址以 CatC 实际下发为准]`

**验证**：fusion 学到 10.254.100.0/24；border `show bgp vpnv4 unicast vrf CORP` 有 192.168.1.0/24。

### ⬜ Task 17 – Anycast gateway

**目标**：VLAN 100，使用 `SDA-Campus-VLAN-100`（模块按 `ip_pool_name` 关联）。

**验证**：edge 上 `show run int vlan 100` 有 `ip helper-address 192.168.1.99`；客户端拿到 10.254.100.x。

---

## Part 4 – 微分段与身份（ISE / CatC）

### ⬜ Task 18 – TrustSec 迁移

把 TrustSec 策略管理从 ISE 迁到 CatC（Group-Based Policy）。

### ⬜ Task 19 – 安全策略

| SRC \ DST | Employees | Contractors | Developers |
|---|---|---|---|
| Employees | `[ ]` | `[ ]` | `[ ]` |
| Contractors | `[ ]` | `[ ]` | `[ ]` |
| Developers | `[ ]` | `[ ]` | `[ ]` |

`[按实验设计填 permit / deny]`

### ⬜ Task 20 – ISE 用户组

`SDA_Employees`、`SDA_Contractors`、`SDA_Developers`

### ⬜ Task 21 – ISE 本地用户

| 用户 | 组 | 客户端 |
|---|---|---|
| bob | SDA_Employees | WS-1-bob |
| joe | SDA_Contractors | WS-2-joe |
| susan | SDA_Contractors | `[现网无此客户端]` |
| kim | SDA_Developers | `[现网无此客户端]` |

密码不写进本文件。

### ⬜ Task 22 – 授权结果

Access-Accept，下发 VLAN 100。

### ⬜ Task 23 – Policy set

停用默认 policy set；新建一个用本地身份库认证、按身份组匹配并下发对应 SGT 的 policy set。

### ⬜ Task 24 – 客户端 802.1X

Linux 客户端装 `wpasupplicant`，用 PEAP 配置 `/etc/wpa_supplicant/wpa_supplicant.conf`，然后：

```bash
sudo wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant.conf -D wired -i <fabric 侧网卡>
sudo dhclient <fabric 侧网卡>
```

**现网差异**：地址用 DHCP，不手配静态 IP。

### ⬜ Task 25 – 验证

- 按 Task 19 的矩阵互 ping，确认策略生效；
- 客户端 ping ISE、CatC，验证 handoff；
- Edge：`show lisp instance-id * ethernet database`、`show cts role-based permissions`、`show access-session`。

---

## 附加任务（可选）

- **待探索：LAN Automation 做 underlay**。只手工配 border 作为种子设备，intermediate 和 edge 由 CatC 通过 PnP 自动生成 IS-IS underlay 并纳管，取代 Task 3–6 的手工部分；NaC 用模块的 `cc_lan_automation.tf`。需先验证 cat9kv 是否支持。

- **待探索：全新 ISE 用 ZTP bootstrap**。ISE 3.1 起支持 Zero-Touch Provisioning：第一次开机前把 key=value 配置交给安装程序，跳过交互式 `setup`。本 lab 的 ISE 是装好后改 hostname / domain 的，所以踩了 pxGrid 证书 CN 不一致的坑（见排错记录）；用 ZTP 的话，主机名、内部 CA 和 pxGrid 证书一开始就是 `ise.ccie.local`，API 也直接开好。
  1. **建 VM**：Terraform（`proxmox-vm` 模块）按 ISE 规格建 VM，挂安装 ISO。
  2. **ZTP 配置**：常见字段 `hostname`、`ipv4_addr`、`ipv4_mask`、`ipv4_default_gw`、`domain`、`primarynameserver`、`ntpserver`、`timezone`、`username` / `password`，以及服务开关 `ersapi`、`openapi`、`pxGrid`、`pxGrid_Cloud`。打包成 `.img` 挂到**第二个光驱**，或者在 OVA / 云部署里用 user data 传入。密码不进 Git，和 `terraform.tfvars` 一样由用户填。
  3. **起来之后**：策略对象（Task 20–23）用 `nac-ise` / `CiscoDevNet/ise` provider；persona、证书、多节点注册用 OpenAPI 或 Ansible `cisco.ise`；CatC 集成就是 `ise.tf`。仍需手工的主要是 license（评估版 90 天）。
  - 注意：字段名和镜像文件名（`ise-ztp.img` / `ise_config.img`）因版本而异，以对应版本的安装指南为准；没找到 KVM / Proxmox 专门的 ZTP 步骤，`.img` 怎么挂需按安装指南 KVM 章节验证；社区报告过 VMware 上 UEFI 卡住、改 BIOS 才好。
  - 参考：[ISE ZTP（Cisco Community）](https://community.cisco.com/t5/security-documents/ise-zero-touch-provisioning-ztp/ta-p/4541606)、[SNS VM 须知](https://community.cisco.com/t5/security-knowledge-base/ise-what-we-need-to-know-about-sns-vm/ta-p/5274022)、[Deploy ISE 3.4](https://www.cisco.com/c/en/us/support/docs/security/identity-services-engine-34/223285-deploy-identity-services-engine-ise.html)、[VMware ZTP 卡住](https://community.cisco.com/t5/network-access-control/ise-3-1-auto-install-on-vmware-with-iso-hangs/m-p/4871993)。

- 第二个 VN `Guest`，只能访问 fusion 之外的一个地址；
- 不支持 802.1X 的主机：用 host onboarding 给端口静态 SGT + open auth（不用 CLI）；
- handoff 改为 VRF-aware，在 fusion 上选择性泄漏一条 GRT 路由进 fabric；
- 让流量优先走 BCP-1，回程也一致。

## 排错记录

| 日期 | 现象 | 原因 / 处理 |
|---|---|---|
| 2026-11-11 | `terraform plan`：Unable to find username | 运行 plan 的 shell 里没有 `CC_USERNAME`；provider 只认 `CC_*` 变量名 |
| 2026-11-11 | apply 时 building 报 400 `NCND10502: Either latitude/longitude or address is ...` | CatC API 要求 building 带经纬度或地址；YAML 加 `latitude` / `longitude` |
| 2026-11-11 | 作者环境里有之前在 GUI 手工建的 USA / SDA-Campus，与 greenfield 前提不符 | 一次性清理：`terraform destroy`，再在 GUI 删掉残留，回到干净状态后按正常流程重跑。（另一种做法是 provider 的 `allow_existing_on_create` 接管存量对象，属于 brownfield 迁移，本实验不用） |
| 2026-11-11 | stage1.tfplan 只有 7 个 `terraform_data` | plan 中途出错（plan 文件里 `errored: true`），不是 YAML 没读到；要看 plan 的完整报错输出 |
| 2026-11-11 | `catalystcenter_integrate_ise`：`WAITING_USER_INPUT ... certificate ... not yet trusted` | 时序问题：接受证书的请求在 CatC 进入等待确认状态之前就发出了。再 apply 一次即可 |
| 2026-11-11 | `catalystcenter_integrate_ise`：`FQDN ise.ccie.local doesn't match the common name contained in the system certificate` | ISE 改过主机名，admin 证书（443）已是新 CN，但 pxGrid 证书（8910）仍是旧主机名，由旧的内部 CA 签发。ISE → Certificates → CSR → 用途选 ISE Root CA → Replace ISE Root CA Certificate chain；然后按报错要求重建 CatC 里的 ISE 条目：`terraform apply -replace='catalystcenter_authentication_policy_server.ise[0]' -target=catalystcenter_integrate_ise.ise`。检查方法：`openssl s_client -connect <ise>:8910` 看 CN |
