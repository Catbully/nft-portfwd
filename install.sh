#!/bin/sh
# 安装 nft-portfwd：脚本装到 /opt/nft-portfwd，并在 /usr/local/bin/nft 放一个透传包装，
# 让裸 `nft` 打开菜单、带参数的 `nft ...` 仍然是真正的 nft。
#
#   curl -fsSL https://raw.githubusercontent.com/Catbully/nft-portfwd/main/install.sh | sudo sh
set -eu

RAW="https://raw.githubusercontent.com/Catbully/nft-portfwd/main"
DIR="/opt/nft-portfwd"
WRAP="/usr/local/bin/nft"
REAL="/usr/sbin/nft"

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }
[ -x "$REAL" ] || { echo "找不到 $REAL，本脚本只支持 nft 装在这个路径的系统" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "需要 curl" >&2; exit 1; }

mkdir -p "$DIR"
curl -fsSL "$RAW/nft-portfwd.sh" -o "$DIR/nft-portfwd.sh"
curl -fsSL "$RAW/ports.conf" -o "$DIR/ports.conf"
chmod +x "$DIR/nft-portfwd.sh"

# 包装放在 /usr/local/bin（PATH 里排在 /usr/sbin 前面）。只在"无参数 + 有终端"时进菜单，
# 其余情况原样 exec 真二进制：脚本、systemd、Docker 调 nft 时都带参数，不受影响。
cat > "$WRAP" <<EOF
#!/bin/sh
# 裸 nft（无参数且在终端里）打开菜单；其余一律透传给真正的 nft。
if [ \$# -eq 0 ] && [ -t 0 ]; then
  if [ "\$(id -u)" -eq 0 ]; then exec $DIR/nft-portfwd.sh
  else exec sudo $DIR/nft-portfwd.sh; fi
fi
exec $REAL "\$@"
EOF
chmod +x "$WRAP"

echo "已安装："
echo "  $DIR/nft-portfwd.sh"
echo "  $WRAP"
echo "现在输入 nft 即可打开菜单（bash 里之前用过 nft 的话，先执行 hash -r）"
