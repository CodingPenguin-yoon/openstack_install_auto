#!/bin/bash

# =================================================================================
# [최종] Kolla-Ansible 원클릭 설치 스크립트
# =================================================================================
#
# 중요: 이 스크립트를 실행하기 전에, 사용자는 반드시 아래 작업을 수동으로
#          완료해야 합니다.
#          1. Ubuntu Server 22.04 설치 및 SSH 설정
#          2. Netplan으로 2개의 네트워크 인터페이스(내부/외부) 고정 IP 설정
#          3. Cinder를 위한 LVM 볼륨 그룹(VG) 생성
#
# 사용법: sudo ./kolla_install.sh [내부 VIP 주소] [외부망 시작 IP] [외부망 끝 IP]
# 예시:   sudo ./kolla_install.sh 192.168.2.10 192.168.2.50 192.168.2.80
#
# =================================================================================


# =================================================================================
# 인자 확인 
# =================================================================================



# --- 0. 입력값 확인 ---
if [ "$#" -ne 3 ]; then
    echo "사용법: $0 [내부 VIP 주소] [외부망 시작 IP] [외부망 끝 IP]"
    echo "   예시: $0 192.168.2.10 192.168.2.50 192.168.2.80"
    exit 1
fi

KOLLA_VIP=$1
EXT_NET_RANGE_START=$2
EXT_NET_RANGE_END=$3
STACK_USER="stack"
STACK_HOME="/opt/$STACK_USER"



# 실행 중 오류가 발생하면 즉시 중단

set -e



# --- 1. 네트워크 인터페이스 및 VIP 검증 ---

echo "1. 네트워크 인터페이스 및 VIP 주소를 검증합니다..."

PHY_NICS=($(ls /sys/class/net | grep -E '^(eth|ens|enp|eno)'))

if [ "${#PHY_NICS[@]}" -lt 2 ]; then
    echo "오류: 최소 2개 이상의 물리적 네트워크 인터페이스가 필요합니다."
    exit 1
fi

INTERNAL_INTERFACE_NAME=$(ip route | grep default | awk '{print $5}')
if [ -z "$INTERNAL_INTERFACE_NAME" ]; then
    echo "오류: 기본 경로(default route)를 사용하는 네트워크 인터페이스를 찾을 수 없습니다."
    exit 1
fi

EXTERNAL_INTERFACE_NAME=""
for nic in "${PHY_NICS[@]}"; do
    if [ "$nic" != "$INTERNAL_INTERFACE_NAME" ]; then
        EXTERNAL_INTERFACE_NAME=$nic
        break
    fi
done

if [ -z "$EXTERNAL_INTERFACE_NAME" ]; then
    echo "오류: 내부용 인터페이스와 다른 외부용 물리적 인터페이스를 찾을 수 없습니다."
    exit 1
fi
echo "   - 인터페이스 검증 완료: Internal NIC='${INTERNAL_INTERFACE_NAME}', External NIC='${EXTERNAL_INTERFACE_NAME}'"

# --- VIP 및 외부망 IP 유효성 검증 ---
# 1. IP 형식 검사

for ip in "$KOLLA_VIP" "$EXT_NET_RANGE_START" "$EXT_NET_RANGE_END"; do
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "오류: 입력한 주소 '$ip'는 올바른 IP 형식이 아닙니다."
        exit 1
    fi
done

# 2. 외부망 IP 대역 서브넷 일치 검사 ( /24 기준 )

EXT_NET_START_SUBNET=$(echo $EXT_NET_RANGE_START | cut -d. -f1-3)
EXT_NET_END_SUBNET=$(echo $EXT_NET_RANGE_END | cut -d. -f1-3)

if [ "$EXT_NET_START_SUBNET" != "$EXT_NET_END_SUBNET" ]; then
    echo "오류: 외부망 시작 IP($EXT_NET_RANGE_START)와 끝 IP($EXT_NET_RANGE_END)가 동일한 서브넷에 속하지 않습니다. (C클래스 기준)"
    exit 1
fi

# 3. VIP 서브넷 일치 검사

INTERNAL_IP_CIDR=$(ip -4 addr show $INTERNAL_INTERFACE_NAME | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
INTERNAL_IP=$(echo $INTERNAL_IP_CIDR | cut -d'/' -f1)
PREFIX=$(echo $INTERNAL_IP_CIDR | cut -d'/' -f2)

# VIP와 서버 IP가 같아도 되도록 허용합니다.
if [ "$KOLLA_VIP" == "$INTERNAL_IP" ]; then
    echo "경고: VIP 주소($KOLLA_VIP)가 서버의 실제 IP 주소와 동일합니다. 단일 노드 테스트 환경에서만 사용하세요."
fi



# 서브넷 비교 로직

SERVER_NET_PART=""
VIP_NET_PART=""
if (( PREFIX >= 24 )); then
    SERVER_NET_PART=$(echo $INTERNAL_IP | cut -d. -f1-3)
    VIP_NET_PART=$(echo $KOLLA_VIP | cut -d. -f1-3)
elif (( PREFIX >= 16 )); then
    SERVER_NET_PART=$(echo $INTERNAL_IP | cut -d. -f1-2)
    VIP_NET_PART=$(echo $KOLLA_VIP | cut -d. -f1-2)
elif (( PREFIX >= 8 )); then
    SERVER_NET_PART=$(echo $INTERNAL_IP | cut -d. -f1)
    VIP_NET_PART=$(echo $KOLLA_VIP | cut -d. -f1)
fi



if [ -n "$SERVER_NET_PART" ] && [ "$SERVER_NET_PART" != "$VIP_NET_PART" ]; then
    echo "오류: VIP 주소($KOLLA_VIP)가 서버의 내부 IP 서브넷($INTERNAL_IP_CIDR)과 일치하지 않습니다."
    exit 1
fi
echo "   - VIP 및 외부망 IP 주소 검증 완료."





# 외부망 네트워크 정보 자동 생성
EXT_NET_RANGE="start=${EXT_NET_RANGE_START},end=${EXT_NET_RANGE_END}"
EXT_NET_SUBNET=$(echo $EXT_NET_RANGE_START | cut -d. -f1-3)
EXT_NET_CIDR="${EXT_NET_SUBNET}.0/24"
EXT_NET_GATEWAY="${EXT_NET_SUBNET}.1"




# =================================================================================
# 시스템 설치 준비
# =================================================================================





# --- 2. 시스템 사전 준비 자동화 ---

echo "2. 시스템 사전 준비를 시작합니다 (Swap, 방화벽 등)..."

sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo systemctl stop ufw apparmor
sudo systemctl disable ufw apparmor

# --- 3. 'stack' 사용자 생성 및 권한 설정 ---

echo "3. '$STACK_USER' 사용자를 생성하고 sudo 권한을 부여합니다..."

if ! id -u $STACK_USER > /dev/null 2>&1; then
    sudo useradd -s /bin/bash -d $STACK_HOME -m $STACK_USER
    sudo chmod 755 $STACK_HOME
    echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$STACK_USER
fi

# --- 4. 필수 패키지 설치 ---

echo "4. 시스템을 업데이트하고 필수 패키지를 설치합니다..."

sudo apt-get update
sudo apt-get install -y git python3-dev libffi-dev python3-venv gcc libssl-dev python3-pip python3-full pkg-config libdbus-1-dev cmake libglib2.0-dev curl

# --- 여기부터 stack 사용자로 명령어 블록 실행 ---

sudo -u $STACK_USER -i <<EOF
set -e

echo "5. Kolla-Ansible과 관련 라이브러리를 설치합니다..."

python3 -m venv \$HOME/kolla-openstack
source \$HOME/kolla-openstack/bin/activate
pip install -U pip 'ansible>=8,<9' docker pkgconfig dbus-python
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2024.1
deactivate

echo "6. Ansible 및 Kolla 설정을 준비합니다..."

cat > \$HOME/ansible.cfg <<EOC
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOC

sudo mkdir -p /etc/kolla
sudo chown \$USER:\$USER /etc/kolla

# --- 7. 로컬 globals.yml 파일 복사 및 설정 적용 ---
echo "7. 로컬 globals.yml 파일을 복사하고 최종 설정을 적용합니다..."
# 스크립트와 같은 경로에 있는 globals.yml 파일을 사용합니다.
if [ ! -f "globals.yml" ]; then
    echo "오류: 스크립트와 동일한 위치에 globals.yml 파일이 없습니다."
    exit 1
fi
sudo cp ./globals.yml /etc/kolla/globals.yml

sudo sed -i "s/^kolla_internal_vip_address:.*/kolla_internal_vip_address: \"$KOLLA_VIP\"/" /etc/kolla/globals.yml
sudo sed -i "s/^network_interface:.*/network_interface: \"$INTERNAL_INTERFACE_NAME\"/" /etc/kolla/globals.yml
sudo sed -i "s/^neutron_external_interface:.*/neutron_external_interface: \"$EXTERNAL_INTERFACE_NAME\"/" /etc/kolla/globals.yml
echo "   - 최종 설정 완료: VIP=$KOLLA_VIP, Internal NIC=$INTERNAL_INTERFACE_NAME, External NIC=$EXTERNAL_INTERFACE_NAME"

echo "8. OpenStack 배포를 시작합니다..."

source \$HOME/kolla-openstack/bin/activate
INVENTORY_PATH="\$HOME/kolla-openstack/share/kolla-ansible/ansible/inventory/all-in-one"
kolla-ansible -i \$INVENTORY_PATH bootstrap-servers
kolla-genpwd
kolla-ansible -i \$INVENTORY_PATH prechecks
kolla-ansible -i \$INVENTORY_PATH deploy

echo "9. 배포 후 마무리 작업을 진행합니다..."

sudo usermod -aG docker \$USER
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/2024.1
kolla-ansible -i \$INVENTORY_PATH post-deploy
source /etc/kolla/admin-openrc.sh

echo "10. 'init-runonce' 스크립트를 실행하여 초기 환경을 설정합니다..."

INIT_RUNONCE_PATH="\$HOME/kolla-openstack/share/kolla-ansible/init-runonce"
if [ -f "\$INIT_RUNONCE_PATH" ]; then
    # sed를 이용해 init-runonce 파일의 네트워크 변수들을 동적으로 변경
    sudo sed -i "s|^EXT_NET_CIDR=.*|EXT_NET_CIDR='${EXT_NET_CIDR}'|" "\$INIT_RUNONCE_PATH"
    sudo sed -i "s|^EXT_NET_GATEWAY=.*|EXT_NET_GATEWAY='${EXT_NET_GATEWAY}'|" "\$INIT_RUNONCE_PATH"
    sudo sed -i "s|^EXT_NET_RANGE=.*|EXT_NET_RANGE='${EXT_NET_RANGE}'|" "\$INIT_RUNONCE_PATH"
    echo "   - 외부 네트워크 설정을 동적으로 변경했습니다 (CIDR: ${EXT_NET_CIDR}, Gateway: ${EXT_NET_GATEWAY}, Pool: ${EXT_NET_RANGE})."
    bash "\$INIT_RUNONCE_PATH"
fi

echo "최종 OpenStack 서비스 목록을 확인합니다:"

openstack service list
deactivate

EOF
# --- stack 사용자 명령어 블록 끝 ---

echo ""

echo "모든 설치 과정이 성공적으로 완료되었습니다!"

