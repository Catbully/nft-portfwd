# 0003 · 开机持久化用独立 systemd 单元，不用 `/etc/nftables.d/` 片段

## 状态

已采纳。

## 背景

规则只在运行期生效，重启即消失。有两条现成的路：

1. **`/etc/nftables.d/*.nft` 片段**：Debian 的 `nftables.service` 读 `/etc/nftables.conf`，后者通常 `include` 该目录。原生、零额外进程。
2. **独立 systemd oneshot 单元**：开机执行一次 `nft-portfwd.sh --apply`。

实测两台目标主机正好落在两端：

- 一台 `nftables.service` 是 `inactive + disabled`，`/etc/nftables.conf` 存在但**从未生效**，且首行是 `flush ruleset`。
- 另一台 `nftables.service` 已启用，`/etc/nftables.conf` 里已有 `include "/etc/nftables.d/*.nft"`。

片段方案在第一台上会**静默失效**：文件写进去了，谁也不会读它。用户以为持久化了，重启后才发现规则没了——比不持久化更糟，因为它伪装成成功。

## 决策

`--persist` 安装 `/etc/systemd/system/nft-portfwd.service`：

```ini
[Unit]
Description=nftables 端口放行/转发（<脚本路径>）
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=<脚本绝对路径>/nft-portfwd.sh --apply --conf <规则清单绝对路径>

[Install]
WantedBy=multi-user.target
```

关键点，每一条都对应一个具体故障：

- **只写 `After=nftables.service`，绝不写 `Wants=nftables.service`**。`Wants` 会把对方拉起来；在那台 `nftables.service` 被禁用的主机上，这等于开机执行一次 `nft --file /etc/nftables.conf`，而该文件首行是 `flush ruleset`——Docker 的五张 iptables-nft 表会被一次性清空，容器网络全断。`After` 只排序，不拉起。
- **`Wants=network-online.target`**：规则清单里可以写域名，脚本在加载时用 `getent ahostsv4` 解析。网络没起来就跑，域名解析失败，整份配置不落地。
- **`ExecStart` 用绝对路径**，不依赖当前目录。
- **`RemainAfterExit=yes`**：否则 oneshot 执行完就是 `inactive`，`systemctl is-active` 会误导人以为没生效。
- **`--flush` 连服务一起卸**。否则用户回滚了规则、重启后又回来了，与"回滚 = 彻底移除"的语义冲突。

## 后果

- 规则清单是唯一真相：装完服务后再改规则，只要重新应用即可，不用重装服务——开机时它读的就是同一份文件。
- 代价：在这类主机上 `systemctl restart nftables` 会执行 `flush ruleset`，把 `inet portfwd` 一起清掉，直到下次开机或手动再应用一次。这是宿主的配置决定的，脚本不碰它，所以只能写进文档。
- 放弃了"和系统防火墙配置统一管理"的整洁性，换来的是在任何有 systemd 的 VPS 上都能真正生效。

## 实现时踩到的坑（已修）

`flush_table()` 一度在里面调用 `remove_unit()`。而每次正常应用都要先清掉旧表，于是 `--persist` 装好的服务会被**下一次应用自己删掉**，症状是 `systemctl status` 报 `Unit could not be found`。现在内部清表只清表，卸服务只发生在 `--flush` 与 `--unpersist`。

## 被否决的替代方案

- **只用 `/etc/nftables.d/` 片段**：在 `nftables.service` 未启用的主机上静默失效（见上）。
- **同时支持两种并自动选择**：两套持久化机制意味着两处可能互相打架的状态，排查成本翻倍；而且判定条件（服务是否启用、主配置是否 include）本身就会随宿主配置漂移。
- **`crontab @reboot`**：没有依赖排序，会在网络和 nftables 都没就绪时执行；也没有状态可查。
