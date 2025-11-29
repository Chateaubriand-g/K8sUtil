#!/bin/bash
# Debian Kubernetes 节点初始化脚本（含 containerd 镜像加速）
# 兼容性：Debian 11/12；Kubernetes 1.28.x（请按需修改 K8S_VERSION）
# Run as root (sudo -i)
set -euo pipefail

########## 配置区（按需修改） ##########
K8S_VERSION="1.28.0-1.1"
PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
CONTAINERD_MIRRORS_DOCKER=("https://docker.mirrors.ustc.edu.cn" "https://hub-mirror.c.163.com" "https://registry-1.docker.io")
CONTAINERD_MIRRORS_K8S=("https://registry.aliyuncs.com/google_containers")
CONTAINERD_MIRRORS_GCR=("https://gcr-mirror.qiniu.com")
CONTAINERD_MIRRORS_QUAY=("https://quay-mirror.qiniu.com")
APT_NONINTERACTIVE=DEBIAN_FRONTEND=noninteractive
##########################################

log() { echo -e "\e[1;32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*"; }

cleanup() {
  rc=$?
  if [ $rc -ne 0 ]; then
    err "脚本执行中出现错误（退出码 $rc），请查看上方日志。"
  fi
}
trap cleanup EXIT

# 0. 必要性检查
if [ "$(id -u)" -ne 0 ]; then
  err "此脚本必须以 root 身份运行。"
  exit 1
fi

if ! grep -q "Debian" /etc/os-release; then
  err "错误：这个脚本只适用于 Debian 系统。"
  exit 1
fi

# helper: ensure command exists
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "缺少命令: $1 。请先安装它再运行脚本。"
    exit 1
  fi
}

require_cmd lsb_release
require_cmd gpg
require_cmd awk
require_cmd sed
require_cmd modprobe

log "=== Debian Kubernetes 节点初始化（含镜像加速）=== "

##################
# 1. 禁用 Swap
##################
log "步骤 1/9: 禁用 Swap..."
swapoff -a || true
if grep -q "swap" /etc/fstab; then
  cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
  sed -i '/swap/ s/^\([^#]\)/#\1/' /etc/fstab
  log "/etc/fstab 中 swap 行已注释并备份"
else
  log "未发现 /etc/fstab 中的 swap 条目"
fi

##################
# 2. 加载内核模块
##################
log "步骤 2/9: 加载内核模块..."
modprobe overlay || warn "overlay 模块加载失败（可能已加载 / 不支持）"
modprobe br_netfilter || warn "br_netfilter 模块加载失败（可能已加载 / 不支持）"

cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
log "内核模块配置完成"

##################
# 3. sysctl 参数
##################
log "步骤 3/9: 配置内核参数..."
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF

sysctl --system >/dev/null
log "内核参数配置完成"

##################
# 4. 安装基础工具
##################
log "步骤 4/9: 安装依赖工具..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates lsb-release

##################
# 5. 安装 & 配置 containerd（含镜像加速） - 适配 containerd 2.2
##################
log "步骤 5/9: 安装和配置 containerd..."

# 安装 containerd（使用 Debian 源里的 containerd.io 或系统包）
apt update -y
apt install -y containerd.io

log "备份旧的 containerd 配置（若存在）"
mkdir -p /etc/containerd
if [ -f /etc/containerd/config.toml ]; then
  cp /etc/containerd/config.toml /etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)
fi

log "写入 containerd v2.x 兼容的 config.toml（version = 3）"
cat > /etc/containerd/config.toml <<EOF
version = 3

[debug]
  level = "info"

[grpc]
  address = "/run/containerd/containerd.sock"
  uid = 0
  gid = 0

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "${PAUSE_IMAGE}"

    [plugins."io.containerd.grpc.v1.cri".containerd]
      snapshotter = "overlayfs"
      default_runtime_name = "runc"
      disable_snapshot_annotations = true

    [plugins."io.containerd.grpc.v1.cri".registry]
      # 使用 certs.d 目录作为 registry 配置路径（hosts.toml）
      config_path = "/etc/containerd/certs.d"
EOF

log "创建 certs.d 并写入 hosts.toml（用于镜像加速）"
mkdir -p /etc/containerd/certs.d

# docker.io hosts.toml
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"
[host."${CONTAINERD_MIRRORS_DOCKER[0]}"]
  capabilities = ["pull","resolve"]
  skip_verify = true
[host."${CONTAINERD_MIRRORS_DOCKER[1]}"]
  capabilities = ["pull","resolve"]
  skip_verify = true
EOF

# registry.k8s.io hosts.toml
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<EOF
server = "https://registry.k8s.io"
[host."${CONTAINERD_MIRRORS_K8S[0]}"]
  capabilities = ["pull","resolve"]
  skip_verify = true
EOF

# gcr.io hosts.toml (如果需要)
mkdir -p /etc/containerd/certs.d/gcr.io
cat > /etc/containerd/certs.d/gcr.io/hosts.toml <<EOF
server = "https://gcr.io"
[host."${CONTAINERD_MIRRORS_GCR}"]
  capabilities = ["pull","resolve"]
  skip_verify = true
EOF

# quay.io hosts.toml (如果需要)
mkdir -p /etc/containerd/certs.d/quay.io
cat > /etc/containerd/certs.d/quay.io/hosts.toml <<EOF
server = "https://quay.io"
[host."${CONTAINERD_MIRRORS_QUAY}"]
  capabilities = ["pull","resolve"]
  skip_verify = true
EOF

# 确保 runc runtime 的 systemd cgroup 设置（写入 runtime options，如果不存在则追加）
if ! grep -q 'runc' /etc/containerd/config.toml; then
  cat >> /etc/containerd/config.toml <<'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
EOF
fi

log "重载 systemd 并重启 containerd"
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd || {
  err "containerd 启动失败，尝试输出 journal 日志（最后 200 行）:"
  journalctl -u containerd -n 200 --no-pager || true
  exit 1
}

sleep 2
if systemctl is-active --quiet containerd; then
  log "containerd 已启动"
else
  err "containerd 未能正常启动，请检查 /var/log/syslog 与 journalctl -u containerd"
  exit 1
fi

##################
# 6. 安装 Kubernetes 组件
##################
log "步骤 6/9: 安装 Kubernetes 组件..."

# 使用官方 pkgs.k8s.io 源（适用于大多数 Debian/Ubuntu 版本）
# mkdir -p /etc/apt/keyrings
# curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
#    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
#    https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" \
#    > /etc/apt/sources.list.d/kubernetes.list
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

# 更新并安装固定版本
apt update -y
apt install -y kubelet="${K8S_VERSION}" kubeadm="${K8S_VERSION}" kubectl="${K8S_VERSION}" || {
  err "安装 kubelet/kubeadm/kubectl 失败，请检查 apt 源和版本号（当前 K8S_VERSION=${K8S_VERSION}）"
  exit 1
}

# 防止自动升级
apt-mark hold kubelet kubeadm kubectl
log "Kubernetes 组件安装完成（版本：${K8S_VERSION}）"

##################
# 7. kubelet 配置（使用国内 pause 镜像）
##################
log "步骤 7/9: 配置 kubelet..."

mkdir -p /var/lib/kubelet
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS="--pod-infra-container-image=${PAUSE_IMAGE}"
EOF

systemctl daemon-reload
systemctl enable kubelet
log "kubelet 配置完成"

##################
# 8. cgroup 检查
##################
log "步骤 8/9: 检查 cgroup 配置..."

CGROUP_FS_TYPE=$(stat -fc %T /sys/fs/cgroup || echo "unknown")
if [ "$CGROUP_FS_TYPE" = "cgroup2fs" ]; then
  log "系统使用 cgroup v2"
else
  log "系统使用 cgroup v1 (type: ${CGROUP_FS_TYPE})"
fi

# containerd SystemdCgroup 值检查（从配置文件中读取）
if grep -q "SystemdCgroup" /etc/containerd/config.toml; then
  val=$(grep "SystemdCgroup" /etc/containerd/config.toml | tail -n1 | awk -F= '{gsub(/ /,"",$2); print $2}')
  log "containerd SystemdCgroup: ${val}"
else
  warn "未在 /etc/containerd/config.toml 中找到 SystemdCgroup 设置（已应用默认）"
fi

##################
# 9. 验证安装
##################
log "步骤 9/9: 验证安装..."

echo ""
echo "=== 安装验证 ==="
containerd --version && log "containerd 版本检查通过"
kubelet --version && log "kubelet 版本检查通过"
kubeadm version && log "kubeadm 版本检查通过"
kubectl version --client=true && log "kubectl 版本检查通过"

echo ""
echo "=== 服务状态 ==="
systemctl is-active containerd && log "containerd 服务运行正常"
systemctl is-enabled kubelet && log "kubelet 服务已启用"

echo ""
echo "=== 镜像加速配置摘要 ==="
echo "Docker Hub mirrors: ${CONTAINERD_MIRRORS_DOCKER[*]}"
echo "K8s 镜像: ${CONTAINERD_MIRRORS_K8S[*]}"
echo "GCR 镜像: ${CONTAINERD_MIRRORS_GCR}"
echo "Quay 镜像: ${CONTAINERD_MIRRORS_QUAY}"
echo "Pause 镜像: ${PAUSE_IMAGE}"

echo ""
log "=== Debian Kubernetes 节点初始化完成！ ==="
cat <<EOF
下一步建议：
1) 初始化 master 节点（示例）:
   kubeadm init --image-repository registry.aliyuncs.com/google_containers --pod-network-cidr=10.244.0.0/16

2) 在 worker 节点加入集群（使用 kubeadm join ...，来自 kubeadm init 输出）

3) 安装网络插件（例如 Flannel/Calico 等）:
   kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

注意事项：
- 若 containerd 未能启动，请查看: journalctl -u containerd -b
- certs.d/hosts.toml 的 skip_verify=true 用于镜像解析/加速；线下或生产环境可根据需要添加 CA/certs 或移除 skip_verify。
EOF

exit 0
