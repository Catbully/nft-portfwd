#!/usr/bin/env bash
# nft-portfwd.sh — nftables 端口放行 + 单跳端口转发（DNAT），带交互式菜单
#
# 规则写在同目录的 ports.conf（--conf 可指定），用法见 ./nft-portfwd.sh --help。
# 只做 IPv4 单跳转发：不支持 IPv6 转发、hairpin、应用层中继。
#
# 三条约束的原因在 docs/adr/，这里只留结论：
#   1. 只碰自己那张 `inet portfwd` 表（`fwd` 是 nft 保留字，不能做表名）
#   2. 转发默认开 masquerade，否则回程绕过本机、表现为"连上但没响应"
#   3. 持久化用独立 systemd 单元，只写 After=、绝不写 Wants=nftables.service

# 刻意不用 set -e：菜单是交互循环，某次操作失败不该把整个程序带走。
# 关键步骤（nft 加载、sysctl、mktemp）逐个显式检查。
set -uo pipefail

# ---------------------------------------------------------------- 常量

FAMILY="inet"
TABLE="portfwd"                       # 见头部约束 1：不能叫 fwd
UNIT_NAME="nft-portfwd.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

# 本脚本的绝对路径。admin 类用户的 PATH 里常常没有 /usr/sbin，所以 nft/sysctl
# 一律取绝对路径兜底，避免 "command not found" 的假故障。
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
# SELF 已在上面的 readlink -f 里解析成真实路径，这里不再拼接
NFT="$(command -v nft || true)"; [ -n "$NFT" ] || NFT="/usr/sbin/nft"
SYSCTL="$(command -v sysctl || true)"; [ -n "$SYSCTL" ] || SYSCTL="/usr/sbin/sysctl"

CONF="$SELF_DIR/ports.conf"

# 运行模式与开关（参数解析阶段填充）
MODE=""                # ""=待定  menu=菜单  apply=非交互应用
DO_FLUSH=0
DO_PERSIST=1           # 默认持久化：应用后自动装/更新开机服务，--no-persist 可关
DO_UNPERSIST=0
DRY_RUN=0
CONF_SNAT="on"         # 来自规则清单里的 `snat on|off`
SNAT_FLAG=""           # 来自命令行 --snat / --no-snat，优先级最高

# ---------------------------------------------------------------- 小工具

die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
warn() { printf '注意: %s\n' "$*" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }
pause(){ printf '\n按回车返回菜单...'; read -r _ || true; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root，请用 sudo 运行"
}

# ---------------------------------------------------------------- 规则清单读取
#
# 规则清单是唯一真相。菜单只改它，落地永远走同一个 apply 流程，所以"菜单里看到的"
# 和"实际生效的"不会分叉。

# 有效规则行：去掉注释和空行，也去掉 snat 指令（它不是一条规则）。
# 输出 "<文件行号> <原始行内容>"，供删除操作定位。
active_lines() {
  awk '{ l=$0; sub(/#.*/,"",l); gsub(/^[ \t]+|[ \t]+$/,"",l);
         if (l=="") next;
         if (l ~ /^snat[ \t]+(on|off)$/) next;
         printf "%d %s\n", NR, $0 }' "$CONF"
}

rule_count() { active_lines | wc -l | tr -d ' '; }

# 当前伪装状态：清单里有 snat 指令就以它为准，否则默认 on。
snat_state() {
  # 和 parse_conf 一样先剥注释再匹配：`snat off  # 说明` 加载的是 off，
  # 菜单若显示 on，就会出现"连上了但没响应"的经典现场。
  local v
  v="$(awk '{ sub(/#.*/, "") } $1 == "snat" && ($2 == "on" || $2 == "off") { v = $2 } END { print v }' "$CONF" 2>/dev/null)"
  printf '%s' "${v:-on}"
}

table_loaded() { "$NFT" list table "$FAMILY" "$TABLE" >/dev/null 2>&1; }

boot_state() {
  if ! command -v systemctl >/dev/null 2>&1; then printf '无 systemd'; return; fi
  if systemctl is-enabled "$UNIT_NAME" >/dev/null 2>&1; then printf '开'; else printf '关'; fi
}

# ---------------------------------------------------------------- 开机持久化
#
# 单元内容逐条都有原因：
#   After=... nftables.service   只排序，不拉起对方（见头部约束 3）
#   Wants=network-online.target  规则清单允许写域名，解析需要网络就绪
#   RemainAfterExit=yes          oneshot 跑完否则显示 inactive，会误导人
#   ExecStart 用 --apply         保证非交互，不会在开机时卡在菜单上
#   并加 --no-persist            避免开机时又去重装/重启用自己

install_unit() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "这台机器没有 systemd，跳过开机服务（规则已在运行期生效）"
    return 0
  fi
  # 路径里有空格时 systemd 会把 ExecStart 拆成多个参数；`%` 是 systemd 的说明符前缀，
  # 必须写成 `%%`。两处都要转义后再放进单元文件。
  local EXE="${SELF//%/%%}" CONFQ="${CONF//%/%%}"
  cat > "$UNIT_PATH" <<UNITEOF
[Unit]
Description=nftables 端口放行/转发（$SELF）
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart="$EXE" --apply --no-persist --conf "$CONFQ"

[Install]
WantedBy=multi-user.target
UNITEOF
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 \
    || die "systemctl enable $UNIT_NAME 失败，开机不会自动恢复"
  info "已安装开机服务 $UNIT_NAME"
  info "  ExecStart=\"$SELF\" --apply --conf \"$CONF\""
}

remove_unit() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local link="/etc/systemd/system/multi-user.target.wants/$UNIT_NAME"
  # 也认那个 wants 软链：单元文件被手工删掉后软链会残留，只查文件会漏掉
  if [ -f "$UNIT_PATH" ] || [ -L "$link" ]; then
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH" "$link"
    systemctl daemon-reload
    info "已移除开机服务 $UNIT_NAME"
  fi
}

# ---------------------------------------------------------------- 解析规则清单
#
# 支持三种行：
#   allow 80,443 [tcp|udp]              放行本机端口；省略协议 = tcp + udp 都放行
#   8443 -> host:443 [tcp|udp]          端口转发；省略协议 = tcp
#   snat on|off                         伪装开关（可选，默认 on）
#
# 解析结果放进三个数组：ALLOW_LINES / FWD_LINES / TARGETS（后者用于生成 masquerade）。
# 任何一行不合法就整体失败——宁可不落地，也不要留半套规则。

ALLOW_LINES=()
FWD_LINES=()
TARGETS=()
declare -A SEEN_LOCAL=()   # "协议/本机端口" -> 首次出现的行号，用来拦重复定义

port_ok() {   # 端口必须是 1..65535
  local p="$1"
  # 不允许前导 0：[ -ge ] 是算术比较，080 会被当成八进制而报错，0100 会被当成 64
  [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  [ "$p" -le 65535 ]
}

resolve_v4() {   # 主机名 -> IPv4 字面量；解析不到返回空
  local h="$1"
  if [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$h"; return 0
  fi
  getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}'
}

parse_conf() {
  [ -f "$CONF" ] || die "规则清单不存在: $CONF"

  local lineno=0 raw line ports proto p parts joined lport thost tport ip key
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # 去注释、压空白，剩下的才是规则本身
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    [ -z "$line" ] && continue

    # --- 指令：snat on|off ---
    if [[ "$line" =~ ^snat[[:space:]]+(on|off)$ ]]; then
      CONF_SNAT="${BASH_REMATCH[1]}"
      continue
    fi

    # --- 形式一：allow <port[,port...]> [tcp|udp] ---
    if [[ "$line" =~ ^allow[[:space:]]+([0-9]+(,[0-9]+)*)([[:space:]]+(tcp|udp))?$ ]]; then
      ports="${BASH_REMATCH[1]}"
      # 协议在第 4 组：第 2 组是 (,端口) 的重复，第 3 组带前导空格
      proto="${BASH_REMATCH[4]:-}"
      IFS=',' read -ra parts <<< "$ports"
      for p in "${parts[@]}"; do
        port_ok "$p" || die "第 $lineno 行: 端口非法 '$p'"
      done
      joined="$(IFS=','; echo "${parts[*]}" | sed 's/,/, /g')"
      if [ -n "$proto" ]; then
        ALLOW_LINES+=("$proto dport { $joined } accept")
      else
        # 省略协议 = 两个都放行
        ALLOW_LINES+=("tcp dport { $joined } accept")
        ALLOW_LINES+=("udp dport { $joined } accept")
      fi
      continue
    fi

    # --- 形式二：<本机端口> -> <目标主机>:<目标端口> [tcp|udp] ---
    if [[ "$line" =~ ^([0-9]+)[[:space:]]*-\>[[:space:]]*([A-Za-z0-9._:-]+):([0-9]+)([[:space:]]+(tcp|udp))?$ ]]; then
      lport="${BASH_REMATCH[1]}"
      thost="${BASH_REMATCH[2]}"
      tport="${BASH_REMATCH[3]}"
      proto="${BASH_REMATCH[5]:-tcp}"

      port_ok "$lport" || die "第 $lineno 行: 本机端口非法 '$lport'"
      port_ok "$tport" || die "第 $lineno 行: 目标端口非法 '$tport'"
      [[ "$thost" == *:* ]] && die "第 $lineno 行: 不支持 IPv6 目标（'$thost'），只做 IPv4"

      ip="$(resolve_v4 "$thost")"
      [ -n "$ip" ] || die "第 $lineno 行: 目标主机 '$thost' 解析不到 IPv4"
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "第 $lineno 行: '$thost' 解析结果 '$ip' 不是 IPv4"

      # 同一协议同一本机端口只能有一条转发规则，否则规则集语义取决于顺序
      key="$proto/$lport"
      [ -n "${SEEN_LOCAL[$key]:-}" ] && die "第 $lineno 行: $proto 端口 $lport 重复定义（第 ${SEEN_LOCAL[$key]} 行已用过）"
      SEEN_LOCAL[$key]="$lineno"

      # iifname != "lo"：只对真正的外部入站做 DNAT，不劫持本机进程访问自己的端口
      # counter：留一个命中计数，"包没到"和"包到了但回程丢"能一眼区分
      FWD_LINES+=("iifname != \"lo\" $proto dport $lport counter dnat ip to $ip:$tport")
      TARGETS+=("$ip")
      continue
    fi

    die "第 $lineno 行无法解析: $line"
  done < "$CONF"

  if [ "${#ALLOW_LINES[@]}" -eq 0 ] && [ "${#FWD_LINES[@]}" -eq 0 ]; then
    warn "规则清单里没有任何有效规则：会生成一张只有空链的表，本工具不再放行任何端口"
  fi
}

# ---------------------------------------------------------------- 生成 ruleset

build_ruleset() {   # 生成到 $TMP，失败返回非零
  # 优先级：命令行 --snat/--no-snat > 清单里的 snat 指令 > 默认 on
  local do_snat
  if [ -n "$SNAT_FLAG" ]; then
    [ "$SNAT_FLAG" = "on" ] && do_snat=1 || do_snat=0
  else
    [ "$CONF_SNAT" = "on" ] && do_snat=1 || do_snat=0
  fi

  local snat_rule="" uniq_targets
  if [ "$do_snat" -eq 1 ] && [ "${#TARGETS[@]}" -gt 0 ]; then
    uniq_targets="$(printf '%s\n' "${TARGETS[@]}" | sort -u | paste -sd, - | sed 's/,/, /g')"
    # 只对落地目标做伪装。用 `ct status dnat masquerade` 会连带伪装掉同机上
    # Docker 之类的其它 DNAT，属于越界。
    snat_rule="ip daddr { $uniq_targets } masquerade"
  fi

  {
    echo "table $FAMILY $TABLE {"
    # input：只管"放行"，policy accept，不在这里做任何拦截
    echo "  chain input {"
    echo "    type filter hook input priority filter; policy accept;"
    if [ "${#ALLOW_LINES[@]}" -gt 0 ]; then
      printf '    %s\n' "${ALLOW_LINES[@]}"
    fi
    echo "  }"
    # prerouting：没有转发规则就不生成 nat 链，避免挂一条空链
    if [ "${#FWD_LINES[@]}" -gt 0 ]; then
      echo ""
      echo "  chain prerouting {"
      echo "    type nat hook prerouting priority dstnat; policy accept;"
      printf '    %s\n' "${FWD_LINES[@]}"
      echo "  }"
    fi
    # forward：policy accept，只做放行。写成 drop 会与 Docker 的 FORWARD drop
    # 叠加，先到先丢，把容器网络掐死。
    echo "  chain forward {"
    echo "    type filter hook forward priority filter; policy accept;"
    echo "    ct status dnat accept"
    echo "    ct state established,related accept"
    echo "  }"
    if [ -n "$snat_rule" ]; then
      echo ""
      echo "  chain postrouting {"
      echo "    type nat hook postrouting priority srcnat; policy accept;"
      echo "    $snat_rule"
      echo "  }"
    fi
    echo "}"
  } > "$TMP"
}

# ---------------------------------------------------------------- 落地

flush_table() {
  # 只清表。卸开机服务是 --flush / --unpersist 的事——普通应用如果顺手把服务删了，
  # 持久化就会在下一次应用时自己消失。
  if "$NFT" list table "$FAMILY" "$TABLE" >/dev/null 2>&1; then
    "$NFT" delete table "$FAMILY" "$TABLE" || die "删除 table 失败"
    info "已删除 table $FAMILY $TABLE"
  else
    info "table $FAMILY $TABLE 不存在，无需删除"
  fi
}

# 用 nft 自己再校验一遍。bash 层的校验抓不到 nft 层面的错误（非法地址等），而
# flush_table 在加载之前就执行了——不先校验的话，一份坏 ruleset 会先把线上规则清空
# 再失败，等于自己把防火墙拆了。
#
# 校验时把表名换成一个临时名字：表已存在时 `nft -c` 会报 "File exists"，而表名不存在
# 时它只解析不建表，正好用来做纯语法/语义检查。
validate_ruleset() {
  local chk="$TMP.chk" err="$TMP.err"
  sed "s/^table $FAMILY $TABLE {/table $FAMILY ${TABLE}chk {/" "$TMP" > "$chk" \
    || die "生成校验用 ruleset 失败"
  if ! "$NFT" -c -f "$chk" 2>"$err"; then
    cat "$err" >&2
    die "nft 拒绝这份 ruleset（见上面的报错），未做任何改动"
  fi
  rm -f "$chk" "$err"
}

apply_rules() {
  TMP="$(mktemp)" || die "mktemp 失败"
  trap 'rm -f "$TMP"' EXIT

  parse_conf
  build_ruleset
  validate_ruleset

  echo "== 生成 ruleset（$CONF）=="
  cat "$TMP"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "== dry-run，未落地 =="
    return 0
  fi

  echo "== 应用 =="

  # 有转发规则才需要 ip_forward；只改运行期，开机由持久化单元再设一次
  if [ "${#FWD_LINES[@]}" -gt 0 ]; then
    local cur
    cur="$("$SYSCTL" -n net.ipv4.ip_forward)"
    if [ "$cur" != "1" ]; then
      "$SYSCTL" -w net.ipv4.ip_forward=1 >/dev/null || die "开启 ip_forward 失败"
      info "net.ipv4.ip_forward: $cur -> 1（运行期，重启失效）"
    else
      info "net.ipv4.ip_forward 已是 1"
    fi
  fi

  # 先删后建：保证重复执行是幂等的，不会叠加规则
  flush_table >/dev/null
  "$NFT" -f "$TMP" || die "nft 加载 ruleset 失败（上面的报错是 nft 原话）"
  info "已加载 table $FAMILY $TABLE"

  if [ "$DO_PERSIST" -eq 1 ]; then
    # 命令行的伪装开关只影响这一次运行，开机服务读的是清单本身。两者不一致时不去动
    # 服务，否则重启后伪装状态会悄悄反转（表现就是"连上了但没响应"）。
    if [ -n "$SNAT_FLAG" ] && [ "$SNAT_FLAG" != "$CONF_SNAT" ]; then
      warn "命令行伪装开关与清单里的 snat 不一致：本次只改运行期，开机服务保持原样"
      warn "要让开机也一致，请改 ports.conf 里的 snat on|off"
    else
      install_unit
    fi
  fi

  echo "== 生效规则 =="
  "$NFT" list table "$FAMILY" "$TABLE"
}

# =============================================================================
# 菜单部分
# =============================================================================

# 往候选文件追加一行。原文件最后一行若没有换行符（手工编辑很常见），先补一个，
# 否则新规则会被并进上一行的注释里——校验照样通过，规则却从未存在。
append_line() {
  local f="$1" l="$2"
  [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && printf '\n' >> "$f"
  printf '%s\n' "$l" >> "$f"
}

# 候选配置校验：先写临时文件、跑一遍 dry-run（内含 nft 自己的检查），
# 通过了才覆盖真正的清单。这样任何一次菜单操作都不会留下半套规则。
install_candidate() {
  local cand="$1" dry="$TMPD/dry"
  if ! "$SELF" --apply --conf "$cand" --dry-run >"$dry" 2>&1; then
    echo "!! 校验没通过，这次修改已撤回："
    grep -m2 '错误' "$dry" 2>/dev/null || sed -n '1,3p' "$dry"
    return 1
  fi
  cp -p "$cand" "$CONF" || { echo "!! 写入 $CONF 失败"; return 1; }
  echo "已写入 $CONF"
  return 0
}

offer_apply() {
  local a
  read -rp "现在应用生效？[Y/n] " a || return 0
  case "${a:-y}" in
    y|Y|yes|YES) "$SELF" --apply --conf "$CONF" ;;
    *) echo "已保存，未生效。回菜单选「应用配置」即可。" ;;
  esac
}

do_show_live() {
  hr
  if table_loaded; then
    "$NFT" list table "$FAMILY" "$TABLE"
  else
    echo "当前没有已加载的规则（table $FAMILY $TABLE 不存在）。"
  fi
  hr
  pause
}

do_show_conf() {
  hr
  echo "规则清单：$CONF"
  echo "源地址伪装：$(snat_state)"
  hr
  cat -n "$CONF"
  hr
  pause
}

do_add_allow() {
  local ports proto line
  hr
  read -rp "要放行的端口（可逗号分隔，如 80,443）：" ports || return
  ports="$(printf '%s' "$ports" | tr -d ' ')"
  if ! [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    echo "端口格式不对：'$ports'"; pause; return
  fi
  read -rp "协议 [tcp / udp，回车=两个都放行]：" proto || return
  proto="$(printf '%s' "$proto" | tr 'A-Z' 'a-z')"
  case "$proto" in
    ""|tcp|udp) ;;
    *) echo "协议只能是 tcp 或 udp"; pause; return ;;
  esac

  line="allow $ports"
  [ -n "$proto" ] && line="$line $proto"

  cp -p "$CONF" "$TMPD/c" || { echo "读取 $CONF 失败"; pause; return; }
  append_line "$TMPD/c" "$line"
  echo "新增规则：$line"
  install_candidate "$TMPD/c" && offer_apply
  pause
}

do_add_forward() {
  local lp th tp proto line
  hr
  read -rp "本机端口（外部访问这个端口）：" lp || return
  read -rp "目标主机（IP 或域名）：" th || return
  read -rp "目标端口：" tp || return
  read -rp "协议 [tcp / udp，回车=tcp]：" proto || return
  proto="$(printf '%s' "$proto" | tr 'A-Z' 'a-z')"
  [ -n "$proto" ] || proto="tcp"
  case "$proto" in
    tcp|udp) ;;
    *) echo "协议只能是 tcp 或 udp"; pause; return ;;
  esac

  line="$lp -> $th:$tp $proto"

  cp -p "$CONF" "$TMPD/c" || { echo "读取 $CONF 失败"; pause; return; }
  append_line "$TMPD/c" "$line"
  echo "新增规则：$line"
  install_candidate "$TMPD/c" && offer_apply
  pause
}

do_delete() {
  local n target_ln rows
  hr
  rows="$(active_lines)"
  if [ -z "$rows" ]; then
    echo "规则清单是空的。"; pause; return
  fi
  # 显示时把开头的文件行号去掉，只留规则本身
  echo "$rows" | awk '{ $1=""; sub(/^ /,""); printf "  %2d) %s\n", NR, $0 }'
  hr
  read -rp "要删除第几条（回车取消）：" n || return
  [ -z "$n" ] && return
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "请输入序号"; pause; return; }

  target_ln="$(echo "$rows" | awk -v want="$n" 'NR==want{print $1}')"
  [ -n "$target_ln" ] || { echo "没有第 $n 条"; pause; return; }

  echo "将删除：$(echo "$rows" | awk -v want="$n" 'NR==want{$1=""; sub(/^ /,""); print}')"
  cp -p "$CONF" "$TMPD/c" || { echo "读取 $CONF 失败"; pause; return; }
  sed -i "${target_ln}d" "$TMPD/c"
  install_candidate "$TMPD/c" && offer_apply
  pause
}

do_toggle_snat() {
  local cur new a
  cur="$(snat_state)"
  hr
  echo "当前：源地址伪装 = $cur"
  echo "  开 = 落地目标看到本机 IP（公网→公网中转必须开，否则回程绕过本机、连不通）"
  echo "  关 = 落地目标看到客户端真实 IP（只有目标回程本来就经过本机时才可用）"
  hr
  [ "$cur" = "on" ] && new="off" || new="on"
  read -rp "切换成 $new？[y/N] " a || return
  case "$a" in
    y|Y|yes|YES) ;;
    *) return ;;
  esac

  grep -vE '^[[:space:]]*snat[[:space:]]+(on|off)[[:space:]]*$' "$CONF" > "$TMPD/c" || true
  printf 'snat %s\n' "$new" >> "$TMPD/c"
  echo "源地址伪装 -> $new"
  install_candidate "$TMPD/c" && offer_apply
  pause
}

do_toggle_boot() {
  local st a
  st="$(boot_state)"
  hr
  case "$st" in
    开)
      echo "当前：开机自动生效 = 开"
      echo "开机时执行本脚本的 --apply --no-persist，读的是同一份 $CONF。"
      echo "注意：持久化是默认行为，卸掉之后下次「应用配置」会再装回来。"
      read -rp "取消开机自动生效？[y/N] " a || return
      case "$a" in y|Y|yes|YES) "$SELF" --unpersist ;; *) return ;; esac
      ;;
    关)
      echo "当前：开机自动生效 = 关"
      echo "会装一个 systemd 服务，开机时重新执行 --apply（读同一份规则清单）。"
      read -rp "开启？[y/N] " a || return
      case "$a" in y|Y|yes|YES) "$SELF" --persist --conf "$CONF" ;; *) return ;; esac
      ;;
    *)
      echo "这台机器没有 systemd，无法设置开机自动生效。"
      ;;
  esac
  hr
  pause
}

do_apply() {
  hr
  "$SELF" --apply --conf "$CONF"
  hr
  pause
}

do_flush() {
  local a
  hr
  read -rp "确认删除已加载的全部规则（并卸掉开机服务）？[y/N] " a || return
  case "$a" in
    y|Y|yes|YES) "$SELF" --flush --conf "$CONF" ;;
    *) echo "已取消" ;;
  esac
  hr
  pause
}

do_edit() {
  hr
  cp -p "$CONF" "$TMPD/c" || { echo "读取 $CONF 失败"; pause; return; }
  local ed=()
  read -r -a ed <<< "${EDITOR:-vi}"
  "${ed[@]}" "$CONF"
  if cmp -s "$CONF" "$TMPD/c"; then
    echo "没有改动。"; pause; return
  fi
  if ! "$SELF" --apply --conf "$CONF" --dry-run >"$TMPD/dry" 2>&1; then
    echo "!! 手改的内容校验没通过，已恢复修改前的版本："
    grep -m3 '错误' "$TMPD/dry" 2>/dev/null || sed -n '1,3p' "$TMPD/dry"
    cp -p "$TMPD/c" "$CONF"
    pause
    return
  fi
  echo "校验通过。"
  offer_apply
  pause
}

menu() {
  local choice loaded
  TMPD="$(mktemp -d)" || die "mktemp 失败"
  trap 'rm -rf "$TMPD"' EXIT

  # 菜单的每次改动都靠重新调用自己来做校验，脚本不可执行时整条链路都是死的
  [ -x "$SELF" ] || die "菜单需要 $SELF 可执行（chmod +x $SELF）"

  while true; do
    if table_loaded; then loaded="已加载"; else loaded="未加载"; fi
    clear 2>/dev/null || true
    echo "=============== nftables 端口放行 / 转发 ==============="
    ST="$(snat_state)"
    echo " 规则清单：$(rule_count) 条    源地址伪装：$ST    运行状态：$loaded    开机自启：$(boot_state)"
    hr
    echo "  1) 查看当前生效规则"
    echo "  2) 查看规则清单"
    echo "  3) 添加放行端口"
    echo "  4) 添加端口转发"
    echo "  5) 删除一条规则"
    echo "  6) 切换源地址伪装（当前 $ST）"
    echo "  7) 应用配置"
    echo "  8) 回滚（删除已加载的全部规则）"
    echo "  9) 直接编辑规则清单"
    echo " 10) 开机自动生效（当前 $(boot_state)）"
    echo "  0) 退出"
    hr
    read -rp "选择：" choice || exit 0
    case "$choice" in
      1) do_show_live ;;
      2) do_show_conf ;;
      3) do_add_allow ;;
      4) do_add_forward ;;
      5) do_delete ;;
      6) do_toggle_snat ;;
      7) do_apply ;;
      8) do_flush ;;
      9) do_edit ;;
      10) do_toggle_boot ;;
      0|q|Q) echo "再见。"; exit 0 ;;
      "") ;;
      *) echo "没有这个选项：$choice"; pause ;;
    esac
  done
}

# =============================================================================
# 入口：参数解析与分发
# =============================================================================

usage() {
  cat <<'USAGE'
用法：
  sudo ./nft-portfwd.sh                 # 交互式菜单（有终端时）
  sudo ./nft-portfwd.sh --apply         # 直接应用规则清单
  sudo ./nft-portfwd.sh --dry-run       # 只打印生成的 ruleset，不落地
  sudo ./nft-portfwd.sh --flush         # 回滚：删表 + 卸开机服务
  sudo ./nft-portfwd.sh --persist       # 应用 + 装开机服务（默认行为，显式写无害）
  sudo ./nft-portfwd.sh --no-persist    # 这次只改运行期，不碰开机服务
  sudo ./nft-portfwd.sh --unpersist     # 卸掉开机服务（规则留在内存里）
  sudo ./nft-portfwd.sh --snat          # 强制开启源地址伪装
  sudo ./nft-portfwd.sh --no-snat       # 强制关闭源地址伪装
  sudo ./nft-portfwd.sh --conf FILE     # 指定规则清单

没给模式时：有终端进菜单，没终端按应用处理。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --menu)      MODE=menu ;;
    --apply)     MODE=apply ;;
    --flush)     MODE=apply; DO_FLUSH=1 ;;
    --persist)   MODE=apply; DO_PERSIST=1 ;;
    --no-persist) MODE=apply; DO_PERSIST=0 ;;
    --unpersist) MODE=apply; DO_UNPERSIST=1 ;;
    --snat)      MODE="${MODE:-apply}"; SNAT_FLAG=on ;;
    --no-snat)   MODE="${MODE:-apply}"; SNAT_FLAG=off ;;
    --dry-run)   MODE=apply; DRY_RUN=1 ;;
    --conf)      shift; [ $# -gt 0 ] || die "--conf 需要一个文件参数"; CONF="$1" ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "未知参数: $1（用 --help 看用法）" ;;
  esac
  shift
done

# 规则清单路径必须是绝对的：开机服务在 cwd=/ 下运行，相对路径到开机时就找不到文件了
if [ -f "$CONF" ]; then
  CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
fi

need_root
[ -x "$NFT" ] || die "找不到 nft 可执行文件"
# 没给模式时的默认：有终端进菜单，没终端按应用处理（开机服务走的是显式 --apply）
if [ -z "$MODE" ]; then
  if [ -t 0 ] && [ -t 1 ]; then MODE=menu; else MODE=apply; fi
fi

# --- 非交互模式 ---
if [ "$MODE" = "apply" ]; then
  # 回滚：删表 + 卸服务（"回滚"的语义是彻底移除，不是停用）
  if [ "$DO_FLUSH" -eq 1 ]; then
    echo "== 回滚 =="
    if [ "$DRY_RUN" -eq 1 ]; then
      info "（dry-run）将删除 table $FAMILY $TABLE，并移除开机服务 $UNIT_NAME"
    else
      flush_table
      remove_unit
    fi
    exit 0
  fi

  # 只取消开机持久化，规则继续留在内存里
  if [ "$DO_UNPERSIST" -eq 1 ]; then
    echo "== 取消开机持久化 =="
    if [ "$DRY_RUN" -eq 1 ]; then
      info "（dry-run）将移除 $UNIT_PATH 并 disable $UNIT_NAME"
    else
      remove_unit
    fi
    exit 0
  fi

  apply_rules
  exit 0
fi

# --- 交互模式 ---
menu
