red="\033[31m"
black="\033[0m"

base=/etc/dnat
mkdir $base 2>/dev/null
conf=$base/conf
touch $conf

# 检查iptables是否可用
if ! command -v iptables &> /dev/null; then
    echo -e "${red}警告：iptables未安装${black}"
    echo "脚本将尝试安装iptables，请确保有足够的权限"
    echo "按任意键继续，或按Ctrl+C退出..."
    read -n 1 -s
fi

setupService(){
    cat > /usr/local/bin/dnat.sh <<"AAAA"
#! /bin/bash
[[ "$EUID" -ne '0' ]] && echo "Error:This script must be run as root!" && exit 1;

base=/etc/dnat
mkdir $base 2>/dev/null
conf=$base/conf
firstAfterBoot=1
lastConfig="/iptables_nat.sh"
lastConfigTmp="/iptables_nat.sh_tmp"

####
echo "正在安装依赖...."

# 检查并安装iptables
echo "检查iptables..."
if ! command -v iptables &> /dev/null; then
    echo "iptables未安装，正在安装..."
    if command -v yum &> /dev/null; then
        yum install -y iptables iptables-services &> /dev/null
        systemctl enable iptables &> /dev/null
        systemctl start iptables &> /dev/null
    elif command -v apt &> /dev/null; then
        apt update &> /dev/null
        apt install -y iptables &> /dev/null
    elif command -v pacman &> /dev/null; then
        pacman -S --noconfirm iptables &> /dev/null
    else
        echo "无法确定包管理器，请手动安装iptables"
        exit 1
    fi
    echo "iptables安装完成"
else
    echo "iptables已安装"
fi

# 安装DNS工具
yum install -y bind-utils &> /dev/null
apt install -y dnsutils &> /dev/null
echo "Completed：依赖安装完毕"
echo ""
####

turnOnNat(){
    # 开启端口转发
    echo "1. 端口转发开启  【成功】"
    sed -n '/^net.ipv4.ip_forward=1/'p /etc/sysctl.conf | grep -q "net.ipv4.ip_forward=1"
    if [ $? -ne 0 ]; then
        echo -e "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
    fi

    #开放FORWARD链
    echo "2. 开放iptbales中的FORWARD链  【成功】"
    arr1=(`iptables -L FORWARD -n  --line-number |grep "REJECT"|grep "0.0.0.0/0"|sort -r|awk '{print $1,$2,$5}'|tr " " ":"|tr "\n" " "`)
    for cell in ${arr1[@]}
    do
        arr2=(`echo $cell|tr ":" " "`)
        index=${arr2[0]}
        echo 删除禁止FOWARD的规则$index
        iptables -D FORWARD $index
    done
    iptables --policy FORWARD ACCEPT
}
turnOnNat

testVars(){
    local localport=$1
    local remotehost=$2
    local remoteport=$3
    # 判断端口是否为数字或端口段
    local valid=
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ]||{
       echo  -e "${red}端口请输入数字或端口段（如40000:60000）！！${black}";
       return 1;
    }
    
    # 检查端口段匹配：如果本地是端口段，远程可以是单端口或端口段
    local local_is_range=$(echo "$localport" | grep -c ":")
    local remote_is_range=$(echo "$remoteport" | grep -c ":")
    
    # 如果本地不是端口段，远程也不能是端口段
    if [ $local_is_range -eq 0 ] && [ $remote_is_range -eq 1 ]; then
        echo -e "${red}本地单端口不能映射到远程端口段！${black}";
        return 1;
    fi
}

dnat(){
     [ "$#" = "3" ]&&{
        local localport=$1
        local remote=$2
        local remoteport=$3

        # 检查是否为端口段映射到单端口的情况
        local local_is_range=$(echo "$localport" | grep -c ":")
        local remote_is_range=$(echo "$remoteport" | grep -c ":")
        
        if [ $local_is_range -eq 1 ] && [ $remote_is_range -eq 0 ]; then
            # 端口段映射到单端口：需要逐个端口创建规则
            local start_port=$(echo "$localport" | cut -d: -f1)
            local end_port=$(echo "$localport" | cut -d: -f2)
            
            for ((port=$start_port; port<=$end_port; port++)); do
                cat >> $lastConfigTmp <<EOF
iptables -t nat -A PREROUTING -p tcp --dport $port -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A PREROUTING -p udp --dport $port -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $localIP
iptables -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $localIP
EOF
            done
        else
            # 其他情况：单端口到单端口，或端口段到端口段
            cat >> $lastConfigTmp <<EOF
iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $localIP
iptables -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $localIP
EOF
        fi
    }
}

dnatIfNeed(){
  [ "$#" = "3" ]&&{
    local needNat=0
    # 如果已经是ip
    if [ "$(echo  $2 |grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ];then
        local remote=$2
    else
        local remote=$(host -t a  $2|grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}"|head -1)
    fi

    if [ "$remote" = "" ];then
            echo Warn:解析失败
          return 1;
     fi
  }||{
      echo "Error: host命令缺失或传递的参数数量有误"
      return 1;
  }
    echo $remote >$base/${1}IP
    dnat $1 $remote $3
}

echo "3. 开始监听域名解析变化"
echo ""
while true ;
do
## 获取本机地址
localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
if [ "${localIP}" = "" ]; then
        localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1|head -n 1 )
fi
echo  "本机网卡IP [$localIP]"
cat > $lastConfigTmp <<EOF
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING
EOF
arr1=(`cat $conf`)
for cell in ${arr1[@]}
do
    # 先用>分割出左右两部分
    localpart=$(echo $cell | cut -d'>' -f1)
    remotepart=$(echo $cell | cut -d'>' -f2)
    
    # 分割远程部分：域名/IP 和 端口
    remotehost=$(echo $remotepart | rev | cut -d':' -f2- | rev)
    remoteport=$(echo $remotepart | rev | cut -d':' -f1 | rev)
    
    # 检查是否有效
    if [ "$localpart" != "" -a "$remotehost" != "" -a "$remoteport" != "" ]; then
        # 验证格式
        if testVars "$localpart" "$remotehost" "$remoteport"; then
            echo "转发规则： $localpart => $remotehost:$remoteport"
            dnatIfNeed "$localpart" "$remotehost" "$remoteport"
        fi
    fi
done

lastConfigTmpStr=`cat $lastConfigTmp`
lastConfigStr=`cat $lastConfig`
if [ "$firstAfterBoot" = "1" -o "$lastConfigTmpStr" != "$lastConfigStr" ];then
    echo '更新iptables规则[DOING]'
    source $lastConfigTmp
    cat $lastConfigTmp > $lastConfig
    echo '更新iptables规则[DONE]，新规则如下：'
    echo "###########################################################"
    iptables -L PREROUTING -n -t nat --line-number
    iptables -L POSTROUTING -n -t nat --line-number
    echo "###########################################################"
else
 echo "iptables规则未变更"
fi

firstAfterBoot=0
echo '' > $lastConfigTmp
sleep 60
echo ''
echo ''
echo ''
done    
AAAA

cat > /lib/systemd/system/dnat.service <<\EOF
[Unit]
Description=动态设置iptables转发规则
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/root/
EnvironmentFile=
ExecStart=/bin/bash /usr/local/bin/dnat.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dnat > /dev/null 2>&1
service dnat stop > /dev/null 2>&1
service dnat start > /dev/null 2>&1
}

## 检查iptables是否可用
if ! command -v iptables &> /dev/null; then
    echo -e "${red}错误：iptables未安装或不在PATH中${black}"
    echo "请先运行脚本安装依赖，或者手动安装iptables"
    exit 1
fi

## 获取本机地址
localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
if [ "${localIP}" = "" ]; then
        localIP=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1|head -n 1 )
fi

addDnat(){
    local localport=
    local remoteport=
    local remotehost=
    local valid=
    echo -n "本地端口号（支持端口段如40000:60000）:" ;read localport
    echo -n "远程端口号（单端口或端口段）:" ;read remoteport
    
    # 判断端口是否为数字或端口段
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ]||{
        echo  -e "${red}端口请输入数字或端口段（如40000:60000）！！${black}"
        return 1;
    }
    
    # 检查端口段匹配
    local local_is_range=$(echo "$localport" | grep -c ":")
    local remote_is_range=$(echo "$remoteport" | grep -c ":")
    
    if [ $local_is_range -eq 0 ] && [ $remote_is_range -eq 1 ]; then
        echo -e "${red}本地单端口不能映射到远程端口段！${black}"
        return 1;
    fi

    echo -n "目标域名/IP:" ;read remotehost

    # 构造配置行，将冒号替换为特殊分隔符以便存储
    local configline="${localport}>${remotehost}:${remoteport}"
    
    sed -i "/^${localport//:/\\:}>.*\$/d" $conf
    cat >> $conf <<LINE
$configline
LINE
    
    echo "成功添加转发规则 $configline"
    setupService
}

rmDnat(){
    local localport=
    echo -n "本地端口号（支持端口段如40000:60000）:" ;read localport
    sed -i "/^${localport//:/\\:}>.*\$/d" $conf
    echo "done!"
}

testVars(){
    local localport=$1
    local remotehost=$2
    local remoteport=$3
    # 判断端口是否为数字或端口段
    local valid=
    echo "$localport"|[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ] && echo $remoteport |[ -n "`sed -n '/^[0-9][0-9]*\(:[0-9][0-9]*\)\?$/p'`" ]||{
       return 1;
    }
    
    # 检查端口段匹配
    local local_is_range=$(echo "$localport" | grep -c ":")
    local remote_is_range=$(echo "$remoteport" | grep -c ":")
    
    if [ $local_is_range -eq 0 ] && [ $remote_is_range -eq 1 ]; then
        return 1;
    fi
}

lsDnat(){
    if [ ! -f "$conf" ] || [ ! -s "$conf" ]; then
        echo "暂无转发规则"
        return
    fi
    
    while IFS= read -r cell; do
        # 跳过空行
        [ -z "$cell" ] && continue
        
        # 先用>分割出左右两部分
        localpart=$(echo $cell | cut -d'>' -f1)
        remotepart=$(echo $cell | cut -d'>' -f2)
        
        # 分割远程部分：域名/IP 和 端口
        remotehost=$(echo $remotepart | rev | cut -d':' -f2- | rev)
        remoteport=$(echo $remotepart | rev | cut -d':' -f1 | rev)
        
        # 检查是否有效
        if [ "$localpart" != "" -a "$remotehost" != "" -a "$remoteport" != "" ]; then
            echo "转发规则： $localpart => $remotehost:$remoteport"
        fi
    done < "$conf"
}

echo  -e "${red}你要做什么呢（请输入数字）？Ctrl+C 退出本脚本${black}"
select todo in 增加转发规则 删除转发规则 列出所有转发规则 查看当前iptables配置
do
    case $todo in
    增加转发规则)
        addDnat
        ;;
    删除转发规则)
        rmDnat
        ;;
    列出所有转发规则)
        lsDnat
        ;;
    查看当前iptables配置)
        if ! command -v iptables &> /dev/null; then
            echo -e "${red}错误：iptables未安装或不在PATH中${black}"
            echo "请先安装iptables"
        else
            echo "###########################################################"
            iptables -L PREROUTING -n -t nat --line-number
            iptables -L POSTROUTING -n -t nat --line-number
            echo "###########################################################"
        fi
        ;;
    *)
        echo "如果要退出，请按Ctrl+C"
        ;;
    esac
done
