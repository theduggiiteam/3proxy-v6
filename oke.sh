#!/bin/bash

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
FIRST_PORT=11000
LAST_PORT=11500
IP6_PREFIX="2a0b:f304:040c"
IFACE="ens3"
PROXY_VERSION="0.9.4"

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    yum -y install gcc net-tools bsdtar zip make wget >/dev/null
    mkdir -p /3proxy && cd /3proxy
    wget -q -O 3proxy.tar.gz "https://github.com/3proxy/3proxy/archive/refs/tags/${PROXY_VERSION}.tar.gz"
    tar -xzf 3proxy.tar.gz
    cd 3proxy-${PROXY_VERSION}
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat,cfd}
    mv bin/3proxy /usr/local/etc/3proxy/bin/
    wget -qO /usr/lib/systemd/system/3proxy.service https://raw.githubusercontent.com/xlandgroup/ipv4-ipv6-proxy/master/scripts/3proxy.service-Centos8
    systemctl daemon-reexec
    systemctl daemon-reload
    echo "* hard nofile 999999" >> /etc/security/limits.conf
    echo "* soft nofile 999999" >> /etc/security/limits.conf
    cat >> /etc/sysctl.conf <<EOF
net.ipv6.conf.${IFACE}.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind = 1
EOF
    sysctl -p
    systemctl stop firewalld
    systemctl disable firewalld
}

gen_data() {
    IP4=$(curl -4 -s icanhazip.com)
    for port in $(seq $FIRST_PORT $LAST_PORT); do
        user=$(random)
        pass=$(random)
        ip6=$(gen64 $IP6_PREFIX)
        echo "$user/$pass/$IP4/$port/$ip6"
    done
}

gen_3proxy_cfg() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
flush
auth strong
users $(awk -F "/" '{printf "%s:CL:%s ", $1, $2}' ${WORKDATA})
$(awk -F "/" '{printf "auth strong\nallow %s\nproxy -6 -n -a -p%s -i%s -e%s\nflush\n", $1, $4, $3, $5}' ${WORKDATA})
EOF
}

gen_boot_scripts() {
    awk -F "/" '{print "ifconfig '"$IFACE"' inet6 add " $5 "/64"}' ${WORKDATA} > ${WORKDIR}/boot_ifconfig.sh
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -j ACCEPT"}' ${WORKDATA} > ${WORKDIR}/boot_iptables.sh
    chmod +x ${WORKDIR}/boot_*.sh
}

setup_rc_local() {
    cat >>/etc/rc.local <<EOF
#!/bin/bash
systemctl start NetworkManager.service
ifup ${IFACE}
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/cfd/3proxy.cfg &
EOF
    chmod +x /etc/rc.local
    bash /etc/rc.local
}

gen_proxy_file() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2}' ${WORKDATA} > ${WORKDIR}/proxy.txt
}

mkdir -p $WORKDIR && cd $WORKDIR
install_3proxy
gen_data > $WORKDATA
gen_3proxy_cfg > /usr/local/etc/3proxy/cfd/3proxy.cfg
gen_boot_scripts
setup_rc_local
gen_proxy_file
