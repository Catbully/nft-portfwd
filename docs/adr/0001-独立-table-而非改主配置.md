# 0001 · 用独立 table `inet portfwd`，绝不执行 `/etc/nftables.conf`

## 状态

已采纳。

## 背景

两台实测过的目标主机代表了两种典型 VPS：

- 一台是 Docker 主机。`nft list tables` 里 5 张表全部由 **iptables-nft 生成**，每张都带 `# Warning: table ... is managed by iptables-nft, do not touch!`。`/etc/nftables.conf` 存在但服务 `inactive + disabled`，**从未生效**，而它的第一行是 `flush ruleset`。`nft -f /etc/nftables.conf` 会一次性清空 Docker 的全部表。
- 另一台是干净的 nftables 主机。`nftables.service` 已启用，`/etc/nftables.conf` 里有 `include "/etc/nftables.d/*.nft"`，已经存在一个端口放行的片段。

同一份脚本要能同时落到这两种机器上，而它们的"主配置"一个不能碰、一个可以 include。

## 决策

脚本只创建并独占一张表：`inet portfwd`（`fwd` 是 nft 保留字，用它会得到 `unexpected fwd, expecting string`）。

- 不读、不写、不执行 `/etc/nftables.conf`。
- 不改 `ip filter` / `ip nat` / `ip6 *` 等任何 iptables-nft 生成的表。
- 回滚 = `nft delete table inet portfwd`，一条命令，无副作用。
- 持久化是可选的 `--persist`，落点是独立的 systemd 单元，不是 `/etc/nftables.d/` 片段（见 ADR 0003）；两种情况都不去改主配置。

## 后果

好处：在任何有 nftables 的 VPS 上都能安全落地；在 Docker 主机上不会误伤容器网络；卸载干净到可以写进运维手册。

代价：

- 与 Docker 的 DNAT 是**并列**的两套 base chain，不是嵌套关系。同一端口号既被 Docker 映射又被本脚本转发时，谁生效取决于 base chain 的遍历顺序，不是配置顺序。这类冲突靠配置校验（同一协议同一端口只允许一条转发规则）拦不住，需要人工避免。
- 新增的 `forward` base chain 若写成 `policy drop`，会与 Docker 的 `FORWARD policy drop` 叠加，先到先丢。因此本脚本的 `forward` 链**保持 policy accept**，只做 `ct status dnat` 与 `established,related` 的显式放行，不做任何拦截。
- 放弃"统一在主配置里管理防火墙"的整洁性，换来的是绝不可能一条命令清空别人的规则集。

## 被否决的替代方案

- **直接改 `/etc/nftables.conf`**：在 Docker 主机上等于埋了一颗 `flush ruleset` 的雷；在那台干净主机上则要改动用户已有的 `lazy_vps_ports` 片段。风险不对称，收益只有"少一张表"。
- **走 iptables 前端**：Docker 主机的 `ip nat` 表已经是 iptables-nft 的领地，再往里加规则会和 Docker 的规则生命周期纠缠；而且 `iptables-nft` 与 `nft` 混用会产生难以排查的表归属问题。
- **并入现有 `inet filter` 表**：干净主机上已存在同名表，`nft add table inet filter` 会直接 `File exists` 失败；而 Docker 主机上根本没有这张表。同一份脚本无法同时适配。
