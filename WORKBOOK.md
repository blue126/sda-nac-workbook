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
| 仿真平台 | PNETLab `192.168.1.251`，lab 文件 `/opt/unetlab/labs/sda-workbook/sda-workbook-catc323.unl` |
| 交换机镜像 | cat9kv-uadp；FUSION-1 为 IOL |
| Catalyst Center | `https://192.168.1.133`（2.3.x） |
| ISE | `192.168.1.221` |
| 控制台 | `ssh ubuntu@192.168.1.251`，`~/con.py <port> <wait> "cmd" ...`（FUSION-1 = 30016） |
| 域名 | `ccie.local` |

### 地址规划

| 用途 | 地址 |
|---|---|
| 管理 / 共享服务 | 192.168.1.0/24 |
| Fusion ↔ Border underlay | 10.0.1.0/30（BCP-1）、10.0.2.0/30（BCP-2） |
| Fabric underlay 链路 | 172.x.x.x `[按现网补充]` |
| Loopback0（RLOC） | 9.9.9.x `[按现网补充每台设备]` |
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
- CatC 上已有同名对象时，加 `CC_ALLOW_EXISTING_ON_CREATE=true` 让 provider 接管而不是报错。
- `terraform.tfstate` 也已 gitignore：state 里有 CatC 返回的对象 ID 等信息，放进公开仓库不合适。

> 注意：Terraform 要在沙箱外跑（Go TLS 不认沙箱代理证书，插件也起不来）。

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

### ⏳ Task 7 – 网络层级

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

### ⬜ Task 8 – 集成 ISE

**目标**：ISE 开 pxGrid，CatC 里加 ISE 为 AAA/PAN，重新 provision 后设备出现在 ISE 的 Network Devices 里。

**NaC**：`[待写：读 cc_system_settings.tf 后补]`

### ⬜ Task 9 – Building 的 AAA 设置

**目标**：SDA-Campus 的 client AAA 指向 ISE `192.168.1.221`。

**NaC**：`[待写]`

### ⏳ Task 11 – IP 地址池

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

### ⬜ Task 10 – 设备分配到站点并 provision

**目标**：六台设备分配到 SDA-Campus 并 provision。

**NaC**：`inventory.devices`（`name` 必填）`[待写：读 cc_device_provision.tf 后补]`

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

- 第二个 VN `Guest`，只能访问 fusion 之外的一个地址；
- 不支持 802.1X 的主机：用 host onboarding 给端口静态 SGT + open auth（不用 CLI）；
- handoff 改为 VRF-aware，在 fusion 上选择性泄漏一条 GRT 路由进 fabric；
- 让流量优先走 BCP-1，回程也一致。

## 排错记录

| 日期 | 现象 | 原因 / 处理 |
|---|---|---|
| 2026-11-11 | `terraform plan`：Unable to find username | 运行 plan 的 shell 里没有 `CC_USERNAME`；provider 只认 `CC_*` 变量名 |
| 2026-11-11 | apply 时 building 报 400 `NCND10502: Either latitude/longitude or address is ...` | CatC API 要求 building 带经纬度或地址；YAML 加 `latitude` / `longitude` |
| 2026-11-11 | stage1.tfplan 只有 7 个 `terraform_data` | plan 中途出错（plan 文件里 `errored: true`），不是 YAML 没读到；要看 plan 的完整报错输出 |
