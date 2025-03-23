#!/bin/sh
random() {
	tr </dev/urandom -dc A-Za-z0-9 | head -c5
	echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
main_interface=$(ip route get 8.8.8.8 | awk -- '{printf $5}')

gen64() {
	ip64() {
		echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
	}
	echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "Installing 3proxy..."
    mkdir -p /3proxy
    cd /3proxy || exit
    URL="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.5.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-0.9.5 || exit
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    mv /3proxy/3proxy-0.9.5/bin/3proxy /usr/local/etc/3proxy/bin/
    
    wget https://raw.githubusercontent.com/theduggiiteam/3proxy-v6/refs/heads/main/3proxy.service-Centos9 -O /3proxy/3proxy-0.9.5/scripts/3proxy.service
    cp /3proxy/3proxy-0.9.5/scripts/3proxy.service /usr/lib/systemd/system/3proxy.service
    systemctl daemon-reload
    systemctl enable 3proxy
    systemctl restart 3proxy
    
    echo "* hard nofile 999999" >> /etc/security/limits.conf
    echo "* soft nofile 999999" >> /etc/security/limits.conf

    cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.$main_interface.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind=1
EOF
    sysctl -p

    systemctl stop firewalld
    systemctl disable firewalld
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 5000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 8.8.4.4
nserver 9.9.9.9
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth none
allow *

$(awk -F "/" '{print "auth none\n" \
"allow *\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read -r port; do
        echo "$(random)/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    echo "Resetting firewall rules..."
    iptables -F
    iptables -X
    cat <<EOF
$(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 " -j ACCEPT"}' ${WORKDATA})
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig '$main_interface' inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

upload_proxy() {
    cd $WORKDIR || exit
    zip -q proxy.zip proxy.txt
    URL=$(curl --upload-file ./proxy.zip https://transfer.sh/proxy.zip)
    echo "Download your proxy list from: ${URL}"
}

echo "Installing necessary packages..."
yum -y install gcc net-tools bsdtar zip make curl >/dev/null

install_3proxy

WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd "$WORKDIR" || exit

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')

echo "Internal IP: ${IP4}, External IPv6 subnet: ${IP6}"

FIRST_PORT=40000
LAST_PORT=42000

gen_data > $WORKDATA
gen_iptables > $WORKDIR/boot_iptables.sh
gen_ifconfig > $WORKDIR/boot_ifconfig.sh
echo NM_CONTROLLED="no" >> /etc/sysconfig/network-scripts/ifcfg-${main_interface}

chmod +x $WORKDIR/boot_*.sh /etc/rc.local

gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

cat >> /etc/rc.local <<EOF
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF

bash /etc/rc.local

echo "Generating proxy list..."
awk -F "/" '{print $3 ":" $4 }' ${WORKDATA} > $WORKDIR/proxy.txt

upload_proxy

echo "Setup completed successfully!"
