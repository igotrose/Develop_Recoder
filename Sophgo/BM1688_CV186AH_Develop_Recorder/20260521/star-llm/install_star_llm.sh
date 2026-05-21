#!/bin/bash
set -e
set -o pipefail

# ==================== 配置项 ====================
INSTALL_DIR="/opt/tunstar/star-llm"
VENV_DIR="$INSTALL_DIR/star-llm-env"
USER="linaro"
GROUP="linaro"
PYTHON_VERSION="3.10"
UV_INSTALL_URL="https://astral.sh/uv/install.sh"
PYPI_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
MODEL_FILE="/data/qwen3.5-2b-int4-autoround_w4bf16_seq2048_bm1688_2core_dynamic_20260415_212627.bmodel"
TAR_FILE="/data/star-llm.tar"
SERVICE_FILE="$INSTALL_DIR/star-llm.service"
TARGET_MODEL="$INSTALL_DIR/models/$(basename $MODEL_FILE)"

# ==================== 彩色输出 ====================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

info() { echo -e "${BLUE}[INFO] $1${RESET}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
error() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

# ==================== 工具函数：计算MD5 ====================
get_md5() {
  local file="$1"
  md5sum "$file" | awk '{print $1}'
}

# ==================== 开始安装 ====================
clear
info "================================================"
info "      Star-LLM 一键全自动安装脚本 (Ubuntu22.04)"
info "        ✅ 智能检测 | 模型校验 | 交互选择 ✅"
info "================================================"
echo ""

# 0. 安装 memory_edit
info "[0/13] 安装 memory_edit..."
sudo apt install -y /data/memory_edit_v2.12.deb > /dev/null 2>&1
success "memory_edit 安装完成"

# 1. 更新系统源
info "[1/13] 更新系统软件源..."
sudo apt update -y > /dev/null 2>&1
info "[2/13] 升级系统软件包..."
sudo apt upgrade -y > /dev/null 2>&1
success "系统源更新完成"

# 2. 检测 curl
info "[3/13] 检测 curl 依赖..."
if ! command -v curl &> /dev/null; then
    info "curl 未安装，开始安装..."
    sudo apt install -y curl > /dev/null 2>&1
    success "curl 安装完成"
else
    warn "curl 已存在，跳过安装"
fi

# 3. 检测 uv
info "[4/13] 检测 uv 包管理器..."
if ! command -v uv &> /dev/null; then
    info "uv 未安装，开始安装..."
    curl -LsSf $UV_INSTALL_URL | sh > /dev/null 2>&1
    source $HOME/.local/bin/env
    success "uv 安装完成"
else
    warn "uv 已存在，跳过安装"
    source $HOME/.local/bin/env > /dev/null 2>&1 || true
fi

# 4. 创建目录
info "[5/13] 创建安装目录并授权..."
sudo mkdir -p $INSTALL_DIR/models
sudo chown -R $USER:$GROUP $INSTALL_DIR
success "目录创建完成：$INSTALL_DIR"

# 5. 检测虚拟环境
info "[6/13] 检测 Python 虚拟环境..."
if [ ! -d "$VENV_DIR" ]; then
    info "虚拟环境未创建，开始初始化..."
    cd $INSTALL_DIR
    uv venv star-llm-env --python $PYTHON_VERSION > /dev/null 2>&1
    success "虚拟环境创建完成"
else
    warn "虚拟环境已存在，跳过初始化"
fi
source $VENV_DIR/bin/activate
success "虚拟环境已激活"

# 6. 安装依赖
info "[7/13] 安装 Python 依赖包（请勿中断）..."
uv pip install --upgrade pip --index-url $PYPI_MIRROR > /dev/null 2>&1
uv pip install fastapi==0.115.0 uvicorn==0.32.0 pydantic==2.8.2 numpy==1.26.4 pillow==12.2.0 transformers==5.5.4 qwen-vl-utils==0.0.14 torch==2.6.0 torchvision==0.21.0 -i $PYPI_MIRROR > /dev/null 2>&1
success "Python 依赖安装完成"

# ==================== 模型文件智能校验与拷贝（修复版） ====================
info "[8/13] 模型文件校验与拷贝..."
# 检查源模型是否存在
[ -f "$MODEL_FILE" ] || error "源模型文件不存在：$MODEL_FILE"

# 标记是否需要拷贝
NEED_COPY=true

if [ -f "$TARGET_MODEL" ]; then
    warn "目标模型已存在：$TARGET_MODEL"
    
    # 1. 比对文件大小
    SIZE_SRC=$(stat -c%s "$MODEL_FILE")
    SIZE_DST=$(stat -c%s "$TARGET_MODEL")
    
    if [ "$SIZE_SRC" != "$SIZE_DST" ]; then
        warn "文件大小不一致！源：$SIZE_SRC 目标：$SIZE_DST"
    else
        info "文件大小一致，开始校验MD5..."
        # 2. 大小一致，比对MD5
        MD5_SRC=$(get_md5 "$MODEL_FILE")
        MD5_DST=$(get_md5 "$TARGET_MODEL")
        
        if [ "$MD5_SRC" = "$MD5_DST" ]; then
            success "模型文件MD5一致，跳过拷贝！"
            NEED_COPY=false
        else
            warn "MD5不一致！源：$MD5_SRC 目标：$MD5_DST"
        fi
    fi

    # 如果需要拷贝，进入交互选择
    if [ "$NEED_COPY" = true ]; then
        echo ""
        warn "请选择操作："
        select opt in "覆盖现有文件" "重命名新文件(保留两者)" "取消拷贝"; do
            case $opt in
                "覆盖现有文件")
                    info "正在覆盖模型文件..."
                    cp -f "$MODEL_FILE" "$TARGET_MODEL"
                    success "模型已覆盖！"
                    break
                    ;;
                "重命名新文件(保留两者)")
                    NEW_NAME="${TARGET_MODEL%.bmodel}_$(date +%Y%m%d%H%M%S).bmodel"
                    info "新文件将保存为：$(basename $NEW_NAME)"
                    cp "$MODEL_FILE" "$NEW_NAME"
                    success "新模型已保存，原有文件保留！"
                    break
                    ;;
                "取消拷贝")
                    warn "取消模型拷贝，使用原有模型！"
                    break
                    ;;
                *) echo "无效选项，请重新选择！";;
            esac
        done
    fi
else
    # 目标不存在，直接拷贝
    info "目标模型不存在，开始拷贝..."
    cp "$MODEL_FILE" "$TARGET_MODEL"
    success "模型文件拷贝完成！"
fi

success "模型文件处理完成"

# ==================== 生成配置 ====================
info "[9/13] 生成 .env 配置文件..."
cat > $INSTALL_DIR/.env << EOF
# Star LLM Configuration
MODEL_PATH=models/$(basename $MODEL_FILE)
STARLLM_PORT=12658
EOF
success ".env 配置文件生成完成"

# 10. 解压源码
info "[10/13] 解压 star-llm 源码包..."
[ -f "$TAR_FILE" ] || error "源码包不存在：$TAR_FILE"
tar -xf $TAR_FILE -C $INSTALL_DIR/ > /dev/null 2>&1
success "源码包解压完成"

# 11. 部署服务
info "[11/13] 部署系统服务文件..."
[ -f $SERVICE_FILE ] || error "服务文件不存在：$SERVICE_FILE"
sudo cp -f $SERVICE_FILE /etc/systemd/system/star-llm.service
sudo chmod 644 /etc/systemd/system/star-llm.service
success "服务文件部署完成"

# 12. 刷新服务
info "[12/13] 刷新系统服务配置..."
sudo systemctl daemon-reload
success "服务配置刷新完成"

# 13. 开机自启+启动
info "[13/13] 设置开机自启并启动服务..."
sudo systemctl enable star-llm.service > /dev/null 2>&1
sudo systemctl restart star-llm.service
success "✅ Star-LLM 服务启动成功！"

# 14. 安装 dnsmasq 并配置 USB 网络
info "[14/14] 安装 dnsmasq 并配置 USB 虚拟网卡..."
sudo apt install -y dnsmasq > /dev/null 2>&1
sudo tee /etc/dnsmasq.d/usb > /dev/null << 'EOF'
# 只监听USB虚拟网卡
interface=usb0
# 不加载全局配置
no-resolv
no-hosts
# DHCP地址池（Windows自动获取的IP范围）
dhcp-range=192.168.188.100,192.168.188.199,255.255.255.0,24h
# 🔥 核心：不下发默认网关（关键！）
dhcp-option=3
# 🔥 核心：不下发DNS（关键！）
dhcp-option=6
# 关闭路由广播
no-negcache
EOF
sudo systemctl enable dnsmasq > /dev/null 2>&1
sudo systemctl restart dnsmasq
success "dnsmasq 安装配置完成"

# ==================== 完成 ====================
echo ""
info "================================================"
success "🎉 全部部署完成！服务已开机自启 + 运行中"
info "安装目录：$INSTALL_DIR"
info "服务端口：12658"
info "查看状态：sudo systemctl status star-llm.service"
info "实时日志：journalctl -u star-llm.service -f"
info "================================================"
