# nft-forward

一个与云厂商无关的单文件脚本：**放行本机端口** + **单跳端口转发（DNAT）**，带交互式菜单和开机持久化。

只创建并独占一张表 `inet portfwd`，不碰 `/etc/nftables.conf`，不碰 Docker 的 iptables-nft 表。回滚永远是 `nft delete table inet portfwd`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `nft-portfwd.sh` | 全部逻辑：菜单、解析、校验、落地、开机持久化 |
| `ports.conf` | 规则清单（放行 / 转发 / 伪装开关） |

## 用法

```bash
sudo ./nft-portfwd.sh              # 交互式菜单（有终端时）
sudo ./nft-portfwd.sh --apply      # 直接应用规则清单
sudo ./nft-portfwd.sh --dry-run    # 只打印生成的 ruleset，不落地
sudo ./nft-portfwd.sh --flush      # 回滚：删表 + 卸开机服务
sudo ./nft-portfwd.sh --persist    # 装/更新开机服务（默认行为，显式写无害）
sudo ./nft-portfwd.sh --no-persist # 这次只改运行期，不碰开机服务
sudo ./nft-portfwd.sh --unpersist  # 只卸开机服务，规则留在内存里
sudo ./nft-portfwd.sh --snat       # 强制开启源地址伪装（覆盖清单里的 snat 指令）
sudo ./nft-portfwd.sh --no-snat    # 强制关闭伪装
sudo ./nft-portfwd.sh --conf FILE  # 指定规则清单
```

没给模式时：有终端进菜单，没终端按应用处理（开机服务走的是显式 `--apply`）。

幂等：重复执行会先删掉 `inet portfwd` 再重建，不会叠加规则。

## 菜单

```
 1) 查看当前生效规则      2) 查看规则清单
 3) 添加放行端口          4) 添加端口转发
 5) 删除一条规则          6) 切换源地址伪装
 7) 应用配置              8) 回滚
 9) 直接编辑规则清单     10) 开机自动生效
 0) 退出
```

顶部实时显示「规则条数 / 伪装状态 / 运行状态 / 开机自启」。菜单里每一项改动都先写进临时文件、跑一遍 `--dry-run` 校验，校验不过自动撤回，不会留下半套规则。

## 配置格式

```
allow 22 tcp                     # 放行本机端口；省略协议 = tcp + udp 都放行
allow 80,443 tcp
443 -> 203.0.113.10:443 tcp      # 本机 443 -> 目标 443
8443 -> example.com:8080         # 目标可写域名，加载时解析成 IPv4
snat off                         # 可选指令，关闭源地址伪装（默认 on）
```

优先级：命令行 `--snat` / `--no-snat` > 清单里的 `snat` 指令 > 默认 `on`。

解析失败（端口越界、目标解析不到 IPv4、同一协议同一端口重复定义、行无法解析）时**整份配置不落地**，旧规则保持原样。

## 行为细节

- **协议**：TCP / UDP 都支持，同端口号可分别配一条。
- **加载前先自检**：`flush_table` 之前会先用 `nft -c` 校验一遍生成的 ruleset（校验时把表名换成临时名字，否则表已存在会报 `File exists`）。所以一份被 nft 拒绝的配置**不会先把线上规则清空再失败**——那等于自己把防火墙拆了。`--dry-run` 同样会跑这一步，菜单的「校验」因此能拦住非法地址之类的错误。
- **空清单是合法状态**：所有规则删光后会生成一张只有空链的表，并打印一条警告。菜单因此可以删掉最后一条规则（`--flush` 则是连表带开机服务一起移除）。
- **命令行伪装开关不会写进开机服务**：`--snat` / `--no-snat` 与清单里的 `snat` 不一致时，本次只改运行期，开机服务保持原样并打印警告——否则重启后伪装状态会悄悄反转。要长期生效就改 `ports.conf` 里的 `snat on|off`。
- **地址族**：只做 IPv4 转发。目标写 IPv6 会直接报错退出（避免半套规则）。
- **`ip_forward`**：有转发规则时自动 `sysctl -w net.ipv4.ip_forward=1`，只改运行期。
- **`input` 链只管放行，policy 是 accept**：本工具不拦截任何流量。如果这台机上还有别的 base chain 在 `input` 上做 drop（Docker、ufw、Debian 默认 `nftables.conf` 都可能），那"放行"仍然由那张表说了算——本工具加的是 accept，救不回别处已经 drop 的包。要真正放行，得在管事的那个链里放行。
- **`iifname != "lo"`**：DNAT 只作用于外部入站，不会劫持本机进程访问自己的端口。
- **`counter`**：每条转发规则带命中计数，`nft list table inet portfwd` 能一眼区分「包没到」和「包到了但回程丢」。
- **回程**：默认对落地目标做 `masquerade`。这不是可选项——"公网客户端 → 转发节点 → 公网落地目标"下如果关掉它，落地目标的回包会直接发给客户端，客户端因为源 IP:port 对不上自己的连接而丢弃，表现为连上但永远没响应（实测：DNAT 计数器涨了 1 个包，curl 超时）。只有落地目标的回程本来就经过本机（例如目标在本机后端 / 目标的默认网关就是本机）时才用 `--no-snat` 换取真实源 IP。
- **forward 链**：policy accept，并放行 `ct status dnat` 与 `established,related`，在 forward 默认 drop 的主机上也能通。
- **持久化是默认行为**：每次应用都会装/更新 systemd oneshot 服务 `nft-portfwd.service`（`ExecStart` 带 `--no-persist`，避免开机时重装自己），开机执行 `--apply`，读同一份规则清单——所以改完规则重新应用即可，不用重装服务。`--no-persist` 让这一次只改运行期；`--unpersist` 卸掉服务但保留规则；`--flush` 两者一起清。没有 systemd 的机器上会自动跳过并提示，不影响规则生效。

## 已知非目标

- **hairpin / 同机回环**：本机进程连本机转发端口不会命中 DNAT（那是 `output` 链的事）。需要就写 `nft` 的 `output` 链 DNAT，本脚本不管。
- **IPv6 转发**、**应用层中继**（按域名/SNI 分流、多目标负载）都不做——后者要 sing-box / HAProxy 之类。
- **云安全组 / 上游防火墙**：脚本只改主机内 nftables，云厂商侧的安全组要自己放行。

## 设计记录

`docs/adr/` 里有三份决策记录，解释为什么是现在这样：

- `0001` 为什么用独立 table，绝不执行 `/etc/nftables.conf`
- `0002` 为什么转发默认必须开源地址伪装
- `0003` 为什么持久化用 systemd 单元而不是 `/etc/nftables.d/` 片段
