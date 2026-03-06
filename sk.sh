#!/usr/bin/env bash
# sk - 一键多功能脚本菜单
# GitHub: https://github.com/sikiyz/toolScript/blob/main/sk.sh

set -euo pipefail

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# ---------- 日志函数 ----------
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ---------- 基础工具 ----------
is_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 运行此脚本（sudo -i 或者 su）"
    exit 1
  fi
}

check_internet() {
  if ! curl -s --connect-timeout 5 https://raw.githubusercontent.com >/dev/null; then
    log_error "网络连接失败，请检查网络"
    return 1
  fi
  return 0
}

# ---------- 下载工具 ----------
safe_download() {
  local url="$1"
  local output="$2"
  
  if is_cmd curl; then
    curl -fsSL "$url" -o "$output"
  elif is_cmd wget; then
    # 检查是否是 BusyBox wget
    if wget --help 2>&1 | grep -q "BusyBox"; then
      # BusyBox wget
      wget "$url" -O "$output"
    else
      # GNU wget
      wget -q "$url" -O "$output"
    fi
  else
    log_error "需要 curl 或 wget，请先安装"
    detect_pm
    pkg_install curl
    curl -fsSL "$url" -o "$output"
  fi
}

PM=""
detect_pm() {
  if is_cmd apt-get; then PM="apt"; fi
  if is_cmd dnf; then PM="dnf"; fi
  if is_cmd yum && [ -z "$PM" ]; then PM="yum"; fi
  if is_cmd zypper && [ -z "$PM" ]; then PM="zypper"; fi
  if is_cmd pacman && [ -z "$PM" ]; then PM="pacman"; fi
  if [ -z "$PM" ]; then
    log_warn "未识别的包管理器"
  fi
}

pkg_update() {
  case "$PM" in
    apt) apt-get update -y ;;
    dnf|yum) $PM makecache ;;
    zypper) zypper refresh ;;
    pacman) pacman -Sy ;;
  esac
}

pkg_install() {
  log_step "安装: $*"
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf|yum) $PM install -y "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) 
      log_warn "未识别的包管理器，尝试手动安装"
      return 1
      ;;
  esac
}

# ---------- 1. 安装 3x-ui ----------
install_3xui() {
  require_root
  log_step "开始安装 3x-ui..."
  check_internet || return 1
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

# ---------- 2. 安装 x-ui ----------
install_xui() {
  require_root
  log_step "开始安装 x-ui..."
  check_internet || return 1
  bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/master/install.sh)
}

# ---------- 3. Caddy 相关 ----------
caddy_arch_map() {
  local uarch
  uarch="$(uname -m)"
  case "$uarch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    *) echo "" ;;
  esac
}

install_caddy_repo_deb() {
  pkg_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /etc/apt/keyrings/caddy-stable.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | sed 's#deb #[signed-by=/etc/apt/keyrings/caddy-stable.gpg] deb #' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  pkg_update
  pkg_install caddy
}

install_caddy_repo_rpm() {
  if is_cmd dnf; then
    dnf -y install 'dnf-command(copr)' || true
    dnf -y copr enable @caddy/caddy || true
    dnf -y install caddy
  else
    return 1
  fi
}

install_caddy_binary() {
  local arch; arch="$(caddy_arch_map)"
  if [ -z "$arch" ]; then
    log_error "不支持的架构: $(uname -m)，请手动安装 Caddy"
    return 1
  fi
  
  pkg_install curl tar ca-certificates || true
  mkdir -p /usr/local/bin
  log_step "下载 Caddy 二进制..."
  
  if ! curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${arch}&id=caddy" | tar -xz -C /usr/local/bin caddy; then
    log_error "下载失败，尝试备用地址..."
    curl -fsSL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${arch}.tar.gz" | tar -xz -C /usr/local/bin caddy
  fi
  
  chmod +x /usr/local/bin/caddy
  
  # 创建 systemd 服务
  cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  
  mkdir -p /etc/caddy
  systemctl daemon-reload
  systemctl enable caddy --now
  log_info "Caddy 二进制安装完成！"
}

install_caddy() {
  require_root
  detect_pm
  log_step "开始安装 Caddy..."
  
  if [ "$PM" = "apt" ]; then
    install_caddy_repo_deb
  elif [ "$PM" = "dnf" ] || [ "$PM" = "yum" ]; then
    if ! install_caddy_repo_rpm; then
      log_warn "RPM 仓库安装失败，尝试二进制安装..."
      install_caddy_binary
    fi
  else
    log_warn "使用二进制安装..."
    install_caddy_binary
  fi
  
  if is_cmd caddy; then
    log_info "Caddy 安装成功！版本: $(caddy version 2>/dev/null || echo '未知')"
  else
    log_error "Caddy 安装失败！"
  fi
}

caddy_reverse_proxy() {
  require_root
  if ! is_cmd caddy; then
    log_error "请先安装 Caddy！"
    return 1
  fi
  
  echo -e "\n${CYAN}=== Caddy 一键反代配置 ===${NC}"
  read -p "请输入域名（如 example.com）: " domain
  read -p "请输入后端 IP（支持 IPv4/IPv6，如 127.0.0.1 或 [::1]）: " backend_ip
  read -p "请输入后端端口: " backend_port
  
  # 验证输入
  if [ -z "$domain" ] || [ -z "$backend_ip" ] || [ -z "$backend_port" ]; then
    log_error "输入不能为空！"
    return 1
  fi
  
  # 判断是否为 IPv6 地址
  if [[ "$backend_ip" =~ ^\[.*\]$ ]]; then
    upstream="${backend_ip}:${backend_port}"
  elif [[ "$backend_ip" =~ : ]]; then
    upstream="[${backend_ip}]:${backend_port}"
  else
    upstream="${backend_ip}:${backend_port}"
  fi
  
  # 创建 Caddyfile
  mkdir -p /etc/caddy
  cat > /etc/caddy/Caddyfile <<EOF
${domain} {
    reverse_proxy ${upstream} {
        header_up Host {http.reverse_proxy.upstream.hostport}
        header_up X-Real-IP {http.request.remote}
        header_up X-Forwarded-For {http.request.remote}
        header_up X-Forwarded-Proto {http.request.scheme}
    }
    
    encode gzip
    
    header {
        -Server
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer-when-downgrade
    }
    
    # TLS 自动申请证书
    tls {
        protocols tls1.2 tls1.3
    }
}
EOF
  
  # 重启 Caddy
  systemctl restart caddy
  sleep 2
  
  if systemctl is-active --quiet caddy; then
    log_info "反代配置完成！"
    echo -e "${YELLOW}域名: ${domain} -> ${upstream}${NC}"
    echo -e "${YELLOW}Caddy 配置文件: /etc/caddy/Caddyfile${NC}"
    echo -e "${YELLOW}查看状态: systemctl status caddy${NC}"
  else
    log_error "Caddy 启动失败，请检查配置"
    journalctl -u caddy --no-pager -n 20
  fi
}

uninstall_caddy() {
  require_root
  log_step "开始卸载 Caddy..."
  
  systemctl stop caddy 2>/dev/null || true
  systemctl disable caddy 2>/dev/null || true
  rm -f /etc/systemd/system/caddy.service
  systemctl daemon-reload
  
  detect_pm
  case "$PM" in
    apt) apt-get remove -y caddy ;;
    dnf) dnf remove -y caddy ;;
    yum) yum remove -y caddy ;;
    zypper) zypper remove -y caddy ;;
    pacman) pacman -R --noconfirm caddy ;;
    *) 
      rm -f /usr/local/bin/caddy
      rm -rf /etc/caddy
      rm -rf /var/lib/caddy
      ;;
  esac
  
  log_info "Caddy 卸载完成！"
}

caddy_menu() {
  while true; do
    echo -e "\n${CYAN}=== Caddy 菜单 ===${NC}"
    echo "1) 安装 Caddy"
    echo "2) 一键反代配置"
    echo "3) 查看 Caddy 状态"
    echo "4) 查看 Caddy 日志"
    echo "5) 卸载 Caddy"
    echo "0) 返回主菜单"
    read -p "请选择 [0-5]: " caddy_choice
    
    case $caddy_choice in
      1) install_caddy ;;
      2) caddy_reverse_proxy ;;
      3) systemctl status caddy ;;
      4) journalctl -u caddy -f ;;
      5) uninstall_caddy ;;
      0) break ;;
      *) log_error "无效选择！" ;;
    esac
  done
}

# ---------- 4. Warp 相关 ----------
warp_install() {
  require_root
  log_step "开始安装 Warp..."
  check_internet || return 1
  
  safe_download "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh" "menu.sh"
  
  if [ -f "menu.sh" ]; then
    chmod +x menu.sh
    bash menu.sh
  else
    log_error "下载 Warp 脚本失败"
    return 1
  fi
}

warp_menu() {
  if ! is_cmd warp; then
    log_warn "Warp 未安装，请先安装！"
    read -p "是否现在安装 Warp？[y/N]: " install_warp
    if [[ "$install_warp" =~ ^[Yy]$ ]]; then
      warp_install
    else
      return
    fi
  fi
  
  while true; do
    echo -e "\n${CYAN}=== Warp 菜单 ===${NC}"
    echo "1) 添加 IPv4"
    echo "2) 添加 IPv6"
    echo "3) 添加双栈"
    echo "4) 开关 Warp"
    echo "5) 查看状态"
    echo "6) 卸载 Warp"
    echo "0) 返回主菜单"
    read -p "请选择 [0-6]: " warp_choice
    
    case $warp_choice in
      1) warp 4 ;;
      2) warp 6 ;;
      3) warp d ;;
      4) warp o ;;
      5) warp status 2>/dev/null || echo "Warp 状态不可用" ;;
      6) warp u ;;
      0) break ;;
      *) log_error "无效选择！" ;;
    esac
  done
}

# ---------- 5. Komari 相关 ----------
install_komari() {
  require_root
  log_step "开始安装 Komari..."
  check_internet || return 1
  
  safe_download "https://raw.githubusercontent.com/komari-monitor/komari/main/install-komari.sh" "install-komari.sh"
  
  if [ -f "install-komari.sh" ]; then
    chmod +x install-komari.sh
    sudo ./install-komari.sh
  else
    log_error "下载 Komari 脚本失败"
    return 1
  fi
}

uninstall_komari() {
  require_root
  log_step "开始卸载 Komari..."
  
  echo "1) 官方卸载（使用安装脚本）"
  echo "2) Agent 卸载（仅卸载 agent）"
  read -p "请选择卸载方式 [1-2]: " komari_uninstall_choice
  
  case $komari_uninstall_choice in
    1)
      if [ -f "install-komari.sh" ]; then
        sudo ./install-komari.sh
      else
        log_warn "未找到 install-komari.sh，正在下载..."
        safe_download "https://raw.githubusercontent.com/komari-monitor/komari/main/install-komari.sh" "install-komari.sh"
        chmod +x install-komari.sh
        sudo ./install-komari.sh
      fi
      ;;
    2)
      sudo systemctl stop komari-agent 2>/dev/null || true
      sudo systemctl disable komari-agent 2>/dev/null || true
      sudo rm -f /etc/systemd/system/komari-agent.service
      sudo systemctl daemon-reload
      sudo rm -rf /opt/komari/agent /var/log/komari 2>/dev/null || true
      log_info "Komari Agent 卸载完成！"
      ;;
    *)
      log_error "无效选择！"
      ;;
  esac
}

komari_menu() {
  while true; do
    echo -e "\n${CYAN}=== Komari 菜单 ===${NC}"
    echo "1) 安装 Komari"
    echo "2) 卸载 Komari"
    echo "3) 查看 Komari 状态"
    echo "0) 返回主菜单"
    read -p "请选择 [0-3]: " komari_choice
    
    case $komari_choice in
      1) install_komari ;;
      2) uninstall_komari ;;
      3) systemctl status komari-agent 2>/dev/null || log_warn "Komari Agent 未运行" ;;
      0) break ;;
      *) log_error "无效选择！" ;;
    esac
  done
}

# ---------- 6. Docker 安装 ----------
install_docker() {
  require_root
  detect_pm
  
  if is_cmd docker; then
    log_warn "Docker 已安装，版本: $(docker --version)"
    read -p "是否重新安装？[y/N]: " reinstall
    [[ "$reinstall" =~ ^[Yy]$ ]] || return
  fi
  
  log_step "开始安装 Docker..."
  
  # 卸载旧版本
  case "$PM" in
    apt)
      apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
      ;;
    dnf|yum)
      $PM remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
      ;;
  esac
  
  # 安装依赖
  pkg_install apt-transport-https ca-certificates curl gnupg lsb-release
  
  # 添加 Docker GPG 密钥
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  
  # 添加 Docker 仓库
  local distro
  if [ -f /etc/os-release ]; then
    distro="$(. /etc/os-release && echo "$ID")"
  else
    distro="ubuntu"
  fi
  
  # 根据不同的发行版设置仓库
  case "$PM" in
    apt)
      # 对于 Debian/Ubuntu 系统
      local codename
      if [ -f /etc/os-release ]; then
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
      else
        codename="$(lsb_release -cs)"
      fi
      
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro $codename stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      ;;
    dnf|yum)
      # 对于 RHEL/CentOS/Fedora 系统
      local repo_url="https://download.docker.com/linux/$distro"
      local gpg_url="https://download.docker.com/linux/$distro/gpg"
      
      # 创建仓库文件
      cat > /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=$repo_url/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=$gpg_url
EOF
      ;;
    zypper)
      # 对于 openSUSE/SLES 系统
      zypper addrepo -f https://download.docker.com/linux/$distro/docker-ce.repo
      ;;
    pacman)
      # 对于 Arch Linux 系统
      pkg_install docker docker-compose
      systemctl start docker
      systemctl enable docker
      log_info "Docker 安装完成（通过 pacman）"
      return 0
      ;;
  esac
  
  # 更新包缓存
  pkg_update
  
  # 安装 Docker
  case "$PM" in
    apt)
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    dnf|yum)
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose
      ;;
    zypper)
      pkg_install docker-ce docker-ce-cli containerd.io docker-compose
      ;;
  esac
  
  # 启动并设置开机自启
  systemctl start docker
  systemctl enable docker
  
  # 添加当前用户到 docker 组（如果非root）
  if [ "$(id -u)" -eq 0 ] && [ -n "$SUDO_USER" ]; then
    usermod -aG docker "$SUDO_USER"
    log_info "已将用户 $SUDO_USER 添加到 docker 组"
    log_warn "请重新登录或执行 'newgrp docker' 使更改生效"
  elif [ "$(id -u)" -ne 0 ]; then
    # 如果以非root用户运行，尝试添加到docker组
    if ! groups "$(whoami)" | grep -q docker; then
      sudo usermod -aG docker "$(whoami)" 2>/dev/null && \
      log_info "已将当前用户添加到 docker 组" || \
      log_warn "无法添加用户到 docker 组，请手动执行: sudo usermod -aG docker $(whoami)"
    fi
  fi
  
  # 配置 Docker 镜像加速（中国用户）
  if curl -s --connect-timeout 3 https://hub.docker.com >/dev/null; then
    # 网络正常，不配置镜像加速
    log_info "Docker Hub 访问正常"
  else
    log_warn "Docker Hub 访问较慢，配置镜像加速..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
    systemctl restart docker
  fi
  
  # 测试安装
  sleep 2  # 等待 Docker 服务完全启动
  
  if docker --version >/dev/null 2>&1; then
    log_info "Docker 安装成功！"
    echo -e "${YELLOW}版本: $(docker --version | cut -d' ' -f3- | cut -d',' -f1)${NC}"
    
    # 检查 Docker Compose
    if docker compose version >/dev/null 2>&1; then
      echo -e "${YELLOW}Docker Compose 版本: $(docker compose version | grep -oP 'version \K[^,]+')${NC}"
    elif docker-compose --version >/dev/null 2>&1; then
      echo -e "${YELLOW}Docker Compose 版本: $(docker-compose --version | grep -oP 'version \K[^,]+')${NC}"
    else
      echo -e "${YELLOW}Docker Compose: 未安装${NC}"
    fi
    
    # 运行测试容器
    log_step "运行测试容器..."
    if docker run --rm hello-world >/dev/null 2>&1; then
      log_info "Docker 测试通过！"
    else
      log_warn "Docker 测试失败，但安装已完成"
      log_warn "请检查 Docker 服务状态: systemctl status docker"
    fi
    
    # 显示 Docker 信息
    echo -e "\n${CYAN}=== Docker 信息 ===${NC}"
    docker info 2>/dev/null | grep -E "Server Version:|Containers:|Running:|Paused:|Stopped:|Images:|OSType:|Architecture:" | head -10
    
  else
    log_error "Docker 安装失败！"
    log_error "请检查日志: journalctl -u docker --no-pager -n 30"
    return 1
  fi
}

# ---------- 系统信息 ----------
show_system_info() {
  echo -e "\n${CYAN}=== 系统信息 ===${NC}"
  echo -e "主机名: $(hostname)"
  echo -e "系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 2>/dev/null || uname -o)"
  echo -e "内核: $(uname -r)"
  echo -e "架构: $(uname -m)"
  echo -e "CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d':' -f2 | sed 's/^[ \t]*//')"
  echo -e "内存: $(free -h | awk '/^Mem:/ {print $2}')"
  
  # 获取 IP 地址
  local ipv4=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  local ipv6=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1)
  echo -e "IPv4: ${ipv4:-未检测到}"
  echo -e "IPv6: ${ipv6:-未检测到}"
  
  # 检查已安装的服务
  echo -e "\n${CYAN}=== 已安装服务 ===${NC}"
  local services=("docker" "caddy" "x-ui" "3x-ui" "warp" "komari-agent")
  for service in "${services[@]}"; do
    if is_cmd "$service" || systemctl is-active --quiet "$service" 2>/dev/null; then
      echo -e "${GREEN}✓${NC} $service"
    elif systemctl list-unit-files | grep -q "$service"; then
      echo -e "${YELLOW}○${NC} $service (已安装但未运行)"
    fi
  done
  
  # 显示 Docker 容器状态
  if is_cmd docker; then
    local container_count=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$container_count" -gt 0 ]; then
      echo -e "\n${CYAN}=== Docker 容器 ===${NC}"
      docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | head -10
    fi
  fi
}

# ---------- 主菜单 ----------
main_menu() {
  while true; do
    echo -e "\n${PURPLE}╔════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║           ${WHITE}SIKI 一键脚本菜单${PURPLE}           ║${NC}"
    echo -e "${PURPLE}╠════════════════════════════════════════╣${NC}"
    echo -e "${PURPLE}║ ${CYAN}1)${NC} 安装 3x-ui                          ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}2)${NC} 安装 x-ui                           ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}3)${NC} Caddy 相关                          ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}4)${NC} Warp 相关                           ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}5)${NC} Komari 相关                         ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}6)${NC} 安装 Docker                         ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}7)${NC} 系统信息                            ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}8)${NC} 更新脚本                            ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}9)${NC} 卸载脚本                            ${PURPLE}║${NC}"
    echo -e "${PURPLE}║ ${CYAN}0)${NC} 退出                                ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}GitHub: https://github.com/sikiyz/toolScript${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════${NC}"
    read -p "请选择 [0-9]: " main_choice
    
    case $main_choice in
      1) install_3xui ;;
      2) install_xui ;;
      3) caddy_menu ;;
      4) warp_menu ;;
      5) komari_menu ;;
      6) install_docker ;;
      7) show_system_info ;;
      8) update_script ;;
      9) uninstall_script ;;
      0) 
        echo -e "${GREEN}再见！${NC}"
        exit 0
        ;;
      *) log_error "无效选择！" ;;
    esac
  done
}

# ---------- 更新脚本 ----------
update_script() {
  log_step "正在更新脚本..."
  
  # 获取脚本当前路径
  local script_path
  if [ -L "$0" ]; then
    script_path="$(readlink -f "$0")"
  else
    script_path="$0"
  fi
  
  # 备份当前脚本
  local backup_path="${script_path}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$script_path" "$backup_path"
  log_info "已备份当前脚本到: $backup_path"
  
  # 从 GitHub 下载最新版本
  local github_url="https://raw.githubusercontent.com/sikiyz/toolScript/main/sk.sh"
  
  if safe_download "$github_url" "$script_path.tmp"; then
    # 检查下载的脚本是否有效
    if head -n 5 "$script_path.tmp" | grep -q "sk - 一键多功能脚本菜单"; then
      chmod +x "$script_path.tmp"
      mv "$script_path.tmp" "$script_path"
      log_info "脚本更新成功！"
      log_info "请重新运行脚本: sk"
      exit 0
    else
      log_error "下载的文件不是有效的脚本，恢复备份..."
      mv "$backup_path" "$script_path"
      rm -f "$script_path.tmp"
    fi
  else
    log_error "下载失败，请检查网络"
    rm -f "$script_path.tmp"
  fi
}

# ---------- 卸载脚本 ----------
uninstall_script() {
  require_root
  log_step "正在卸载脚本..."
  
  local script_path="/usr/local/bin/sk"
  
  if [ -f "$script_path" ]; then
    rm -f "$script_path"
    log_info "已移除: $script_path"
  fi
  
  # 从 shell 配置文件中移除别名
  local shell_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile")
  for file in "${shell_files[@]}"; do
    if [ -f "$file" ]; then
      sed -i '/alias sk=/d' "$file" 2>/dev/null
      log_info "已清理: $file"
    fi
  done
  
  log_info "脚本卸载完成！"
  log_info "您仍可以运行当前脚本文档，但无法使用 'sk' 命令"
}

# ---------- 安装脚本到系统 ----------
install_to_system() {
  require_root
  log_step "正在安装脚本到系统..."
  
  local install_path="/usr/local/bin/sk"
  local script_url="https://raw.githubusercontent.com/sikiyz/toolScript/main/sk.sh"
  
  # 检查是否已安装
  if [ -f "$install_path" ]; then
    log_warn "脚本已安装，是否重新安装？"
    read -p "重新安装？[y/N]: " reinstall
    [[ "$reinstall" =~ ^[Yy]$ ]] || return
  fi
  
  # 下载脚本
  if safe_download "$script_url" "$install_path"; then
    chmod +x "$install_path"
    log_info "脚本已安装到: $install_path"
    log_info "现在您可以直接输入 'sk' 运行脚本"
    
    # 创建别名
    local shell_rc=""
    if [ -n "$ZSH_VERSION" ]; then
      shell_rc="$HOME/.zshrc"
    elif [ -n "$BASH_VERSION" ]; then
      shell_rc="$HOME/.bashrc"
    fi
    
    if [ -n "$shell_rc" ] && [ -f "$shell_rc" ]; then
      if ! grep -q "alias sk=" "$shell_rc"; then
        echo -e "\n# sk 一键脚本别名" >> "$shell_rc"
        echo "alias sk='/usr/local/bin/sk'" >> "$shell_rc"
        log_info "已添加到 $shell_rc"
      fi
    fi
    
    # 显示使用说明
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           ${WHITE}安装完成！${GREEN}                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}使用方法:${NC}"
    echo -e "  直接运行: ${CYAN}sk${NC}"
    echo -e "  查看帮助: ${CYAN}sk help${NC}"
    echo -e "  更新脚本: ${CYAN}sk update${NC}"
    echo -e "${YELLOW}GitHub: https://github.com/sikiyz/toolScript${NC}"
    
  else
    log_error "下载脚本失败"
    log_error "请手动下载: wget https://raw.githubusercontent.com/sikiyz/toolScript/main/sk.sh"
    return 1
  fi
}

# ---------- 脚本入口 ----------
show_banner() {
  clear
  echo -e "${PURPLE}"
  echo "    ███████╗██╗██╗  ██╗██╗"
  echo "    ██╔════╝██║██║ ██╔╝██║"
  echo "    ███████╗██║█████╔╝ ██║"
  echo "    ╚════██║██║██╔═██╗ ██║"
  echo "    ███████║██║██║  ██╗██║"
  echo "    ╚══════╝╚═╝╚═╝  ╚═╝╚═╝"
  echo -e "${NC}"
  echo -e "${CYAN}    ╔══════════════════════════════╗${NC}"
  echo -e "${CYAN}    ║     ${WHITE}多功能一键脚本 v1.0${CYAN}     ║${NC}"
  echo -e "${CYAN}    ║   ${WHITE}Created by ${PURPLE}SIKI${WHITE}${CYAN}         ║${NC}"
  echo -e "${CYAN}    ╚══════════════════════════════╝${NC}"
  echo -e "${YELLOW}    GitHub: ${WHITE}sikiyz/toolScript${NC}"
  echo -e "${YELLOW}    ═══════════════════════════════${NC}"
  echo ""
}

# 检查是否首次运行
if [ ! -f "/usr/local/bin/sk" ] && [ "$0" != "/usr/local/bin/sk" ]; then
  show_banner
  echo -e "${CYAN}检测到首次运行，是否安装到系统？${NC}"
  echo -e "${YELLOW}安装后可以直接输入 'sk' 运行${NC}"
  echo -e "${YELLOW}══════════════════════════════════${NC}"
  read -p "是否安装？[Y/n]: " install_choice
  
  if [[ "$install_choice" =~ ^[Nn]$ ]]; then
    echo -e "${YELLOW}跳过安装，直接运行当前脚本...${NC}"
    sleep 1
  else
    install_to_system
    exit 0
  fi
fi

# 主程序
if [ "$#" -eq 0 ]; then
  show_banner
  main_menu
else
  # 支持命令行参数直接调用
  case "$1" in
    "3xui"|"1") install_3xui ;;
    "x-ui"|"2") install_xui ;;
    "caddy"|"3") caddy_menu ;;
    "warp"|"4") 
      if ! is_cmd warp; then
        warp_install
      else
        warp_menu
      fi
      ;;
    "komari"|"5") komari_menu ;;
    "docker"|"6") install_docker ;;
    "info"|"7") show_system_info ;;
    "update"|"8") update_script ;;
    "uninstall"|"9") uninstall_script ;;
    "install") install_to_system ;;
    "help"|"-h"|"--help")
      echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
      echo -e "${CYAN}║           ${WHITE}SIKI 脚本帮助${CYAN}               ║${NC}"
      echo -e "${CYAN}╠════════════════════════════════════════╣${NC}"
      echo -e "${CYAN}║ ${WHITE}用法: sk [选项]${CYAN}                       ║${NC}"
      echo -e "${CYAN}║                                        ║${NC}"
      echo -e "${CYAN}║ ${WHITE}选项:${CYAN}                                 ║${NC}"
      echo -e "${CYAN}║ ${CYAN}3xui 或 1${NC}     安装 3x-ui                 ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}x-ui 或 2${NC}      安装 x-ui                  ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}caddy 或 3${NC}     Caddy 菜单                ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}warp 或 4${NC}      Warp 菜单                 ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}komari 或 5${NC}    Komari 菜单               ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}docker 或 6${NC}    安装 Docker               ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}info 或 7${NC}      系统信息                  ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}update 或 8${NC}    更新脚本                  ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}uninstall 或 9${NC} 卸载脚本                  ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}install${NC}        安装脚本到系统            ${CYAN}║${NC}"
      echo -e "${CYAN}║ ${CYAN}help${NC}           显示帮助                  ${CYAN}║${NC}"
      echo -e "${CYAN}║                                        ║${NC}"
      echo -e "${CYAN}║ ${WHITE}无参数${NC}        显示主菜单                ${CYAN}║${NC}"
      echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
      echo -e "${YELLOW}GitHub: https://github.com/sikiyz/toolScript${NC}"
      ;;
    *)
      echo -e "${RED}未知选项: $1${NC}"
      echo "使用 'sk help' 查看帮助"
      exit 1
      ;;
  esac
fi
