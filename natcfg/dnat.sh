#!/bin/bash

red="\033[31m"
green="\033[32m"
yellow="\033[33m"
black="\033[0m"

# 检查root权限
[[ "$EUID" -ne '0' ]] && { echo -e "${red}错误：此脚本需要root权限运行！${black}"; exit 1; }

# 配置文件路径 - 使用统一的路径
base=/etc/dnat
mkdir -p $base 2>/dev/null
conf=$base/port-ranges.conf
touch $conf

# 显示使用帮助
show_usage() {
    echo -e "${green}DNAT端口范围转发脚本${black}"
    echo "用法："
    echo "  $0 quick <目标IP> <端口1> <端口2>  - 快速设置20000-40000和40001-60000"
    echo "  $0 add <起始端口-结束端口> <目标IP> <目标端口>"
    echo "  $0 list  - 列出所有规则"
    echo "  $0 apply - 应用规则到iptables"
    echo "  $0 show  - 显示当前iptables规则"
    echo "  $0 clear - 清除所有规则"
    echo ""
    echo "示例："
    echo "  $0 quick 1.2.3.4 8080 9090"
}

# 检查并安装iptables
check_iptables() {
    if ! command -v iptables &> /dev/null; then
        echo -e "${yellow}警告：iptables未安装，正在安装...${black}"
        if command -v yum &> /dev/null; then
            yum install -y iptables iptables-services
        elif command -v apt &> /dev/null; then
            apt update
            apt install -y iptables iptables-persistent
        else
            echo -e "${red}无法自动安装iptables，请手动安装${black}"
            exit 1
        fi
    fi
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
    
    # 保存到配置文件
    echo "$range>$target_ip:$target_port" >> $conf
    echo -e "${green}已添加转发规则: $range → $target_ip:$target_port${black}"
}

# 列出所有规则
list_rules() {
    echo -e "${green}配置文件位置: $conf${black}"
    echo -e "${green}当前配置的转发规则：${black}"
    echo "================================"
    if [ -s $conf ]; then
        cat $conf
    else
        echo "  （无规则）"
    fi
    echo "================================"
}

# 应用所有规则到iptables
apply_rules() {
    local localIP=$(get_local_ip)
    
    echo -e "${yellow}本机IP: $localIP${black}"
    echo -e "${yellow}正在应用规则到iptables...${black}"
    
    # 清理现有的NAT规则
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    
    # 检查配置文件
    if [ ! -s $conf ]; then
        echo -e "${red}配置文件为空或不存在: $conf${black}"
        return 1
    fi
    
    # 读取配置文件并应用规则
    while IFS= read -r line; do
        # 跳过空行和注释
        [ -z "$line" ] && continue
        [[ "$line" =~ ^#.*$ ]] && continue
        
        echo "处理规则: $line"
        
        # 解析规则格式: 起始端口-结束端口>目标IP:目标端口
        if [[ "$line" =~ ^([0-9]+)-([0-9]+)\>([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
            local start_port="${BASH_REMATCH[1]}"
            local end_port="${BASH_REMATCH[2]}"
            local target_ip="${BASH_REMATCH[3]}"
            local target_port="${BASH_REMATCH[4]}"
            
            echo "  解析: 端口 ${start_port}-${end_port} → ${target_ip}:${target_port}"
            
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
            
            echo -e "  ${green}✓ 已应用: ${start_port}-${end_port} → ${target_ip}:${target_port}${black}"
        else
            echo -e "  ${red}✗ 格式错误，跳过: $line${black}"
            echo -e "  ${yellow}正确格式应为: 起始端口-结束端口>目标IP:目标端口${black}"
        fi
    done < "$conf"
    
    echo -e "${green}所有规则已应用完成！${black}"
    
    # 保存iptables规则
    if command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables 2>/dev/null
        if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
            echo "规则已保存到 /etc/iptables/rules.v4"
        elif iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
            echo "规则已保存到 /etc/sysconfig/iptables"
        fi
    fi
}

# 清除所有规则
clear_rules() {
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    > $conf
    echo -e "${green}已清除所有转发规则${black}"
}

# 快速设置
quick_setup() {
    local target_ip=$1
    local port1=$2
    local port2=$3
    
    if [ -z "$target_ip" ] || [ -z "$port1" ] || [ -z "$port2" ]; then
        echo -e "${red}错误：参数不完整${black}"
        echo "用法: $0 quick <目标IP> <端口1> <端口2>"
        return 1
    fi
    
    echo -e "${yellow}开始快速设置...${black}"
    
    # 清除旧规则和配置
    > $conf
    
    # 添加两个范围到配置文件
    echo "20000-40000>$target_ip:$port1" >> $conf
    echo "40001-60000>$target_ip:$port2" >> $conf
    
    echo -e "${green}配置已写入 $conf:${black}"
    cat $conf
    
    # 应用规则
    apply_rules
    
    # 设置开机启动
    setup_service
    
    # 启动服务
    systemctl start dnat.service 2>/dev/null
    
    echo ""
    echo -e "${green}==================== 设置完成 ====================${black}"
    echo -e "${green}转发规则:${black}"
    echo "  20000-40000 → ${target_ip}:${port1}"
    echo "  40001-60000 → ${target_ip}:${port2}"
    echo -e "${green}服务状态:${black}"
    systemctl is-enabled dnat.service 2>/dev/null | grep -q enabled && echo "  开机自启: 已启用" || echo "  开机自启: 未启用"
    systemctl is-active dnat.service 2>/dev/null | grep -q active && echo "  当前状态: 运行中" || echo "  当前状态: 未运行"
    echo -e "${green}==================================================${black}"
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
    echo -e "${green}=== 当前 iptables NAT 规则 ===${black}"
    echo ""
    echo -e "${yellow}PREROUTING 链:${black}"
    iptables -t nat -L PREROUTING -n --line-number
    echo ""
    echo -e "${yellow}POSTROUTING 链:${black}"
    iptables -t nat -L POSTROUTING -n --line-number
}

# 主程序
main() {
    case "$1" in
        quick)
            if [ $# -ne 4 ]; then
                show_usage
                exit 1
            fi
            check_iptables
            enable_forward
            quick_setup "$2" "$3" "$4"
            ;;
        add)
            if [ $# -ne 4 ]; then
                show_usage
                exit 1
            fi
            add_range "$2" "$3" "$4"
            apply_rules
            ;;
        list)
            list_rules
            ;;
        apply)
            check_iptables
            enable_forward
            apply_rules
            ;;
        clear)
            clear_rules
            ;;
        show)
            show_iptables
            ;;
        service)
            setup_service
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

# 运行主程序
main "$@"
