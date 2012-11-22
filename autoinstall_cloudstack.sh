#!/bin/sh

SSH_PUBLIC_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDPI5qwXRPKmgUGK9hTnIjFVQ06lO52Jabe+4YiCqZCvHYgJFKdgyUTDgiWqXq5lMcfmOLdmxmS98HDX99tX+FWH/5RJZp5y5AuWg7zOksIEf0IwEKVg4rFCKuji2jbspq3I4nrV6EPWL3+33MQlgU0iXlut8zrfYubE+i2tqqKWp+ugQmZ3QbWi1EIB51F56WyIJegI7jkDyfWRkukXS8OqGKfCWqjFP/kkvtF03zeY1G6INe51E5X6ADmjEJ5DrXvTXIN2A97rA5BkcErJyxyXDATdPtho4VCTvVNAUN+qmyk78BhDawAID7WHUQgzqBfgQILErq2XvlHllwBIPhD penguin@ThinkPadX220'

function add_ssh_public_key() {
    cd
    mkdir -p .ssh
    chmod 700 .ssh
    echo "$SSH_PUBLIC_KEY" >> .ssh/authorized_keys
    chmod 600 .ssh/authorized_keys
}

function get_network_info() {
    echo '* for cloud agent'
    read -p ' hostname: ' HOSTNAME
    read -p ' ip address: ' IPADDR
    read -p ' netmask: ' NETMASK
    read -p ' gateway: ' GATEWAY
    read -p ' dns1: ' DNS1
    read -p ' dns2: ' DNS2
}

function get_nfs_info() {
    echo '* for nfs server'
    read -p ' NFS Server IP: ' NFS_SERVER_IP
    read -p ' Primary mount point (ex:/export/primary): ' NFS_SERVER_PRIMARY
    read -p ' Secondary mount point (ex:/export/secondary): ' NFS_SERVER_SECONDARY
}

function get_nfs_network() {
    echo '* for iptables'
    read -p ' network accept from (ex:192.168.1.0/24): ' NETWORK
}

function install_common() {
    yum update -y
    sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
    setenforce permissive
    echo "[cloudstack]
name=cloudstack
baseurl=http://cloudstack.apt-get.eu/rhel/4.0/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/CloudStack.repo
    sed -i -e "s/localhost/$HOSTNAME localhost/" /etc/hosts
    yum install ntp wget -y
    service ntpd start
    chkconfig ntpd on
    wget http://download.cloud.com.s3.amazonaws.com/tools/vhd-util
    mkdir -p /usr/lib64/cloud/common/scripts/vm/hypervisor/xenserver
    mv vhd-util /usr/lib64/cloud/common/scripts/vm/hypervisor/xenserver
}

function install_management() {
    yum install cloud-client mysql-server expect -y

    head -7 /etc/my.cnf > /tmp/before
    tail -n +7 /etc/my.cnf > /tmp/after
    cat /tmp/before > /etc/my.cnf
    echo "innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=350
log-bin=mysql-bin
binlog-format = 'ROW'" >> /etc/my.cnf
    cat /tmp/after >> /etc/my.cnf
    rm -rf /tmp/before /tmp/after

    service mysqld start
    chkconfig mysqld on

    expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none): \"
send \"\n\"
expect \"Change the root password?\"
send \"Y\n\"
expect \"New password: \"
send \"password\n\"
expect \"Re-enter new password: \"
send \"password\n\"
expect \"Remove anonymous users?\"
send \"Y\n\"
expect \"Disallow root login remotely?\"
send \"Y\n\"
expect \"Remove test database and access to it?\"
send \"Y\n\"
expect \"Reload privilege tables now?\"
send \"Y\n\"
interact
"
    cloud-setup-databases cloud:password@localhost --deploy-as=root:password
    cloud-setup-management
    chkconfig cloud-management on
}

function initialize_storage() {
    service rpcbind start
    chkconfig rpcbind on
    service nfs start
    chkconfig nfs on
    mkdir -p /mnt/primary
    mkdir -p /mnt/secondary
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_PRIMARY} /mnt/primary
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_SECONDARY} /mnt/secondary
    rm -rf /mnt/primary/*
    rm -rf /mnt/secondary/*
    /usr/lib64/cloud/common/scripts/storage/secondary/cloud-install-sys-tmplt -m /mnt/secondary -u http://download.cloud.com/templates/acton/acton-systemvm-02062012.qcow2.bz2 -h kvm -F
    umount /mnt/primary
    umount /mnt/secondary
    rmdir /mnt/primary
    rmdir /mnt/secondary
}
   
function install_agent() {
    yum install cloud-agent bridge-utils -y
    echo 'listen_tls = 0
listen_tcp = 1
tcp_port = "16509"
auth_tcp = "none"
mdns_adv = 0' >> /etc/libvirt/libvirtd.conf
    sed -i -e 's/#LIBVIRTD_ARGS="--listen"/LIBVIRTD_ARGS="--listen"/g' /etc/sysconfig/libvirtd
    service libvirtd restart

    HWADDR=`grep HWADDR /etc/sysconfig/network-scripts/ifcfg-eth0 | awk -F '"' '{print $2}'`

    echo "DEVICE=eth0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
BRIDGE=cloudbr0" > /etc/sysconfig/network-scripts/ifcfg-eth0
    echo "DEVICE=cloudbr0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
TYPE=Bridge" > /etc/sysconfig/network-scripts/ifcfg-cloudbr0
}

function install_nfs() {
    yum install nfs-utils -y
    service nfs start
    chkconfig nfs on

    mkdir -p /export/primary
    mkdir -p /export/secondary
    echo '/export	*(rw,async,no_root_squash)' > /etc/exports
    exportfs -a

    echo "LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020" >> /etc/sysconfig/nfs

    INPUT_SECTION_LINE=`cat -n /etc/sysconfig/iptables | egrep -- '-A INPUT' | head -1 | awk '{print $1}'`

    head -`expr $INPUT_SECTION_LINE - 1` /etc/sysconfig/iptables > /tmp/before
    tail -$INPUT_SECTION_LINE /etc/sysconfig/iptables > /tmp/after
    cat /tmp/before > /etc/sysconfig/iptables
    echo "-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 111   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 111   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 2049  -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 32803 -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 32769 -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 892   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 892   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 875   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 875   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p tcp --dport 662   -j ACCEPT
-A INPUT -s $NETWORK -m state --state NEW -p udp --dport 662   -j ACCEPT" >> /etc/sysconfig/iptables
    cat /tmp/after >> /etc/sysconfig/iptables
    rm -rf /tmp/before /tmp/after

    service iptables restart
    service iptables save

}

if [ $# -eq 0 ]
then
    OPT_ERROR=1
fi

while getopts "acnmhr" flag; do
    case $flag in
	\?) OPT_ERROR=1; break;;
	h) OPT_ERROR=1; break;;
	a) opt_agent=true;;
	c) opt_common=true;;
	n) opt_nfs=true;;
	m) opt_management=true;;
	r) opt_reboot=true;;
    esac
done

shift $(( $OPTIND - 1 ))

if [ $OPT_ERROR ]
then
    echo >&2 "usage: $0 [-cnamhr]
  -c : install common packages
  -n : install nfs server
  -a : install cloud agent
  -m : install management server
  -h : show this help
  -r : reboot after installation"
    exit 1
fi

if [ "$opt_agent" = "true" ]
then
    get_network_info
fi
if [ "$opt_nfs" = "true" ]
then
    get_nfs_network
fi
if [ "$opt_management" = "true" ]
then
    get_nfs_info
fi


if [ "$opt_common" = "true" ]
then
    add_ssh_public_key
    install_common
fi
if [ "$opt_agent" = "true" ]
then
    install_agent
fi
if [ "$opt_nfs" = "true" ]
then
    install_nfs
fi
if [ "$opt_management" = "true" ]
then
    install_management
    initialize_storage
fi
if [ "$opt_reboot" = "true" ]
then
    reboot
fi

