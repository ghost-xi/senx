#!/bin/bash

red="\033[31m"
green="\033[32m"
yellow="\033[33m"
black="\033[0m"

# 检查root权限
[[ "$EUID" -ne '0' ]] && { echo -e "${red}错误：此脚本需要root权限运行！${black}"; exit 1; }

# 配置文件路径
base=/etc/port-forward
mkdir -p $base 2>/dev/null
conf=$base/ranges.conf
touch $conf

# 显示使用帮助
show_usage() {
    echo -e "${green}端口范围转发脚本${black}"
    echo "用法："
    echo "  $0 add <起始端口-结束端口> <目标IP> <目标端口>"
    echo "  $0 remove <起始端口-结束端口>"
    echo "  $0 list"
    echo "  $0 apply"
    echo "  $0 clear"
    echo ""
    echo "示例："
    echo "  $0 add 20000-40000 1.2.3.4 8080"
    echo "  $0 add 40001-60000 1.2.3.4 9090"
    echo ""
    echo "快速设置（你的需求）："
    echo "  $0 quick <目标IP> <端口1> <端口2>"
    echo "  示例: $0 quick 1.2.3.4 8080 9090"
}

# 检查并安装iptables
check_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo -e "${yellow}警告：iptables未安装，正在安装...${black}"
        if command -v yum &> /dev/null; then
            yum install -y iptables iptables-services
            systemctl enable iptables
            systemctl start iptables
        elif command -v apt &> /dev/null; then
            apt update
            apt install -y iptables iptables-persistent
        else
            echo -e "${red}无法自动安装iptables，请手动安装${black}"
            exit 1
        fi
    fi
    echo -e "${green}iptables检查完成${black}"
}

# 开启内核转发
enable_forward() {
    # 开启IP转发
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1
    
    # 开放FORWARD链
    iptables -P FORWARD ACCEPT
    
    echo -e "${green}IP转发已启用${black}"
}

# 获取本机IP
get_local_ip() {
    local localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.|^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-1]\.|^192\.168\.)' | head -n 1)
    if [ -z "$localIP" ]; then
        localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
    fi
    echo $localIP
}

# 添加端口范围转发规则
add_range() {
    local range=$1
    local target_ip=$2
    local target_port=$3
    
    # 验证参数
    if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
        echo -e "${red}错误：端口范围格式错误，应为 起始端口-结束端口${black}"
        return 1
    fi
    
    if [[ ! "$target_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${red}错误：目标IP格式错误${black}"
        return 1
    fi
    
    if [[ ! "$target_port" =~ ^[0-9]+$ ]]; then
        echo -e "${red}错误：目标端口必须是数字${black}"
        return 1
    fi
    
    # 保存到配置文件
    echo "$range>$target_ip:$target_port" >> $conf
    echo -e "${green}已添加转发规则: $range → $target_ip:$target_port${black}"
}

# 移除端口范围规则
remove_range() {
    local range=$1
    sed -i "/^$range>/d" $conf
    echo -e "${green}已移除端口范围: $range${black}"
}

# 列出所有规则
list_rules() {
    echo -e "${green}当前配置的转发规则：${black}"
    echo "================================"
    if [ -s $conf ]; then
        cat $conf | while read line; do
            if [[ "$line" =~ ^([0-9]+-[0-9]+)>([0-9.]+):([0-9]+)$ ]]; then
                echo "  $line"
            fi
        done
    else
        echo "  （无规则）"
    fi
    echo "================================"
}

# 应用所有规则到iptables
apply_rules() {
    local localIP=$(get_local_ip)
    
    # 清理现有的NAT规则
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    
    echo -e "${yellow}正在应用规则...${black}"
    
    # 读取配置文件并应用规则
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+)-([0-9]+)>([0-9.]+):([0-9]+)$ ]]; then
            local start_port=${BASH_REMATCH[1]}
            local end_port=${BASH_REMATCH[2]}
            local target_ip=${BASH_REMATCH[3]}
            local target_port=${BASH_REMATCH[4]}
            
            # 添加PREROUTING规则（DNAT）
            iptables -t nat -A PREROUTING -p tcp --dport ${start_port}:${end_port} \
                -j DNAT --to-destination ${target_ip}:${target_port}
            iptables -t nat -A PREROUTING -p udp --dport ${start_port}:${end_port} \
                -j DNAT --to-destination ${target_ip}:${target_port}
            
            # 添加POSTROUTING规则（SNAT）
            iptables -t nat -A POSTROUTING -p tcp -d ${target_ip} --dport ${target_port} \
                -j SNAT --to-source ${localIP}
            iptables -t nat -A POSTROUTING -p udp -d ${target_ip} --dport ${target_port} \
                -j SNAT --to-source ${localIP}
            
            echo -e "  已应用: ${start_port}-${end_port} → ${target_ip}:${target_port}"
        fi
    done < $conf
    
    echo -e "${green}所有规则已应用完成！${black}"
    
    # 保存iptables规则
    if command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
}

# 清除所有规则
clear_rules() {
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    > $conf
    echo -e "${green}已清除所有转发规则${black}"
}

# 快速设置（你的特定需求）
quick_setup() {
    local target_ip=$1
    local port1=$2
    local port2=$3
    
    if [ -z "$target_ip" ] || [ -z "$port1" ] || [ -z "$port2" ]; then
        echo -e "${red}错误：参数不完整${black}"
        echo "用法: $0 quick <目标IP> <端口1> <端口2>"
        return 1
    fi
    
    # 清除旧规则
    clear_rules
    
    # 添加两个范围
    add_range "20000-40000" "$target_ip" "$port1"
    add_range "40001-60000" "$target_ip" "$port2"
    
    # 应用规则
    apply_rules
    
    # 自动设置开机启动
    setup_service
    systemctl start dnat.service
    
    echo -e "${green}快速设置完成！${black}"
    echo "  20000-40000 → ${target_ip}:${port1}"
    echo "  40001-60000 → ${target_ip}:${port2}"
    echo -e "${green}已设置开机自动启动（服务名：dnat）${black}"
}

# 创建systemd服务
setup_service() {
    # 获取脚本的绝对路径
    SCRIPT_PATH=$(realpath "$0")
    
    cat > /etc/systemd/system/dnat.service <<EOF
[Unit]
Description=DNAT端口转发服务
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_PATH} apply
RemainAfterExit=yes
ExecReload=/bin/bash ${SCRIPT_PATH} apply
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dnat.service
    echo -e "${green}已创建dnat开机自启服务${black}"
}

# 显示当前iptables规则
show_iptables() {
    echo -e "${green}当前iptables NAT规则：${black}"
    echo "=== PREROUTING ==="
    iptables -t nat -L PREROUTING -n --line-number
    echo ""
    echo "=== POSTROUTING ==="
    iptables -t nat -L POSTROUTING -n --line-number
}

# 主程序
main() {
    # 检查iptables
    check_iptables
    
    # 开启转发
    enable_forward
    
    case "$1" in
        add)
            if [ $# -ne 4 ]; then
                echo -e "${red}错误：参数不正确${black}"
                show_usage
                exit 1
            fi
            add_range "$2" "$3" "$4"
            apply_rules
            ;;
        remove)
            if [ $# -ne 2 ]; then
                echo -e "${red}错误：参数不正确${black}"
                show_usage
                exit 1
            fi
            remove_range "$2"
            apply_rules
            ;;
        list)
            list_rules
            ;;
        apply)
            apply_rules
            ;;
        clear)
            clear_rules
            ;;
        quick)
            if [ $# -ne 4 ]; then
                echo -e "${red}错误：参数不正确${black}"
                show_usage
                exit 1
            fi
            quick_setup "$2" "$3" "$4"
            ;;
        service)
            setup_service
            ;;
        show)
            show_iptables
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

# 运行主程序
main "$@"
