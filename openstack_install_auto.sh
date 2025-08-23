#!/bin/bash

# =================================================================================
# [최종] Kolla-Ansible 원클릭 설치 스크립트 (사용자 지정 NIC 버전)
# =================================================================================


#
# 중요: 이 스크립트를 실행하기 전에, 사용자는 반드시 아래 작업을 수동으로
#          완료해야 합니다.
#          1. Ubuntu Server 22.04 설치 및 SSH 설정
#          2. Netplan으로 2개의 네트워크 인터페이스(내부/외부) 고정 IP 설정
#          3. Cinder를 위한 LVM 볼륨 그룹(VG) 생성
#          4. globals.yml 파일이 스크립트와 같은 디렉토리에 위치
#
# 사용법: sudo ./openstack_install_auto.sh [내부 VIP] [외부망 시작IP] [외부망 끝IP] [내부NIC] [외부NIC]
# 예시:   sudo ./openstack_install_auto.sh 192.168.2.10 192.168.2.50 192.168.2.80 ens18 ens19
#
# =================================================================================



# --- 유틸리티 함수들 ---
show_usage() {
    echo "사용법: $0 [내부 VIP] [외부망 시작IP] [외부망 끝IP] [내부NIC] [외부NIC]"
    echo ""
    echo "매개변수:"
    echo "  내부 VIP      : Kolla 내부 VIP 주소 (예: 192.168.2.10)"
    echo "  외부망 시작IP  : 외부 네트워크 IP 풀 시작 (예: 192.168.2.50)"
    echo "  외부망 끝IP   : 외부 네트워크 IP 풀 끝 (예: 192.168.2.80)"
    echo "  내부NIC      : 내부 네트워크 인터페이스명 (예: ens18)"
    echo "  외부NIC      : 외부 네트워크 인터페이스명 (예: ens19)"
    echo ""
    echo "필수 파일:"
    echo "  globals.yml  : Kolla-Ansible 설정 파일 (스크립트와 같은 디렉토리)"
    echo ""
    echo "예시:"
    echo "  $0 192.168.2.10 192.168.2.50 192.168.2.80 ens18 ens19"
    echo ""
    echo "현재 시스템의 네트워크 인터페이스 목록:"
    echo "----------------------------------------"
    ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print "  " $2}' | grep -v lo
}


# =================================================================================
# [함수] 네트워크형식 검사 함수수
# =================================================================================

validate_ip() {
    local ip=$1
    local name=$2
    
    # IP 형식 검증
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "오류: $name '$ip'는 올바른 IP 형식이 아닙니다."
        return 1
    fi
    
    # 각 옥텟 범위 검증 (0-255)
    IFS='.' read -ra OCTETS <<< "$ip"
    for octet in "${OCTETS[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            echo "오류: $name '$ip'에 잘못된 옥텟 값($octet)이 있습니다. (0-255 범위)"
            return 1
        fi
    done
    
    # 특수 IP 주소 체크
    if [[ $ip == "0.0.0.0" || $ip == "255.255.255.255" ]]; then
        echo "오류: $name '$ip'는 사용할 수 없는 특수 IP 주소입니다."
        return 1
    fi
    
    return 0
}

# =================================================================================
# [함수] 인터페이스 존재 여부 확인 함수수
# =================================================================================

check_interface_exists() {
    local interface=$1
    local name=$2
    
    if [[ ! -d "/sys/class/net/$interface" ]]; then
        echo "오류: $name '$interface'가 존재하지 않습니다."
        echo "현재 사용 가능한 인터페이스:"
        ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print "  " $2}' | grep -v lo
        return 1
    fi
    
    return 0
}

# =================================================================================
# [함수] 인터페이스 상태 확인 함수수
# =================================================================================

check_interface_status() {
    local interface=$1
    local name=$2
    local require_ip=$3  # "yes" 또는 "no"
    
    # 인터페이스 상태 확인
    local state=$(cat "/sys/class/net/$interface/operstate" 2>/dev/null || echo "unknown")
    echo "   - $name '$interface' 상태: $state"
    
    # IP 주소 확인
    local ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
    
    if [[ "$require_ip" == "yes" ]]; then
        if [[ -z "$ip_addr" ]]; then
            echo "오류: $name '$interface'에 IP 주소가 할당되지 않았습니다."
            echo "내부 인터페이스는 반드시 IP 주소가 설정되어 있어야 합니다."
            return 1
        fi
        echo "   - $name IP 주소: $ip_addr"
    else
        if [[ -n "$ip_addr" ]]; then
            echo "경고: $name '$interface'에 IP 주소($ip_addr)가 할당되어 있습니다."
            echo "외부 인터페이스는 일반적으로 IP가 없어야 하지만, 설정에 따라 문제없을 수 있습니다."
        else
            echo "   - $name IP 주소: 없음 (정상)"
        fi
    fi
    
    return 0
}

# --- 0. 입력값 확인 ---
if [ "$#" -ne 5 ]; then
    echo "오류: 잘못된 매개변수 개수입니다. (입력: $#개, 필요: 5개)"
    echo ""
    show_usage
    exit 1
fi

KOLLA_VIP=$1
EXT_NET_RANGE_START=$2
EXT_NET_RANGE_END=$3
INTERNAL_INTERFACE_NAME=$4
EXTERNAL_INTERFACE_NAME=$5
STACK_USER="stack"
STACK_HOME="/opt/$STACK_USER"

echo "=== 입력된 설정 정보 ==="
echo "내부 VIP: $KOLLA_VIP"
echo "외부망 IP 풀: $EXT_NET_RANGE_START ~ $EXT_NET_RANGE_END"
echo "내부 인터페이스: $INTERNAL_INTERFACE_NAME"
echo "외부 인터페이스: $EXTERNAL_INTERFACE_NAME"
echo ""

# 실행 중 오류가 발생하면 즉시 중단
set -e

# --- 1. 네트워크 인터페이스 검증 ---
echo "1. 네트워크 인터페이스를 검증합니다..."

# 인터페이스 존재 여부 확인
check_interface_exists "$INTERNAL_INTERFACE_NAME" "내부 인터페이스" || exit 1
check_interface_exists "$EXTERNAL_INTERFACE_NAME" "외부 인터페이스" || exit 1

# 동일한 인터페이스 사용 방지
if [[ "$INTERNAL_INTERFACE_NAME" == "$EXTERNAL_INTERFACE_NAME" ]]; then
    echo "오류: 내부와 외부 인터페이스가 동일합니다 ($INTERNAL_INTERFACE_NAME)."
    echo "서로 다른 인터페이스를 지정해야 합니다."
    exit 1
fi

# 인터페이스 상태 및 IP 확인
echo "   인터페이스 상태 확인 중..."
check_interface_status "$INTERNAL_INTERFACE_NAME" "내부 인터페이스" "yes" || exit 1
check_interface_status "$EXTERNAL_INTERFACE_NAME" "외부 인터페이스" "no"

echo "   - 네트워크 인터페이스 검증 완료"

# --- 2. IP 주소 검증 ---
echo "2. IP 주소 유효성을 검증합니다..."

# IP 형식 및 범위 검증
validate_ip "$KOLLA_VIP" "VIP 주소" || exit 1
validate_ip "$EXT_NET_RANGE_START" "외부망 시작 IP" || exit 1
validate_ip "$EXT_NET_RANGE_END" "외부망 끝 IP" || exit 1

# 외부망 IP 대역 검증
EXT_START_NET=$(echo "$EXT_NET_RANGE_START" | cut -d. -f1-3)
EXT_END_NET=$(echo "$EXT_NET_RANGE_END" | cut -d. -f1-3)

if [[ "$EXT_START_NET" != "$EXT_END_NET" ]]; then
    echo "오류: 외부망 시작 IP($EXT_NET_RANGE_START)와 끝 IP($EXT_NET_RANGE_END)가 동일한 서브넷에 속하지 않습니다."
    exit 1
fi

# IP 범위 검증
EXT_START_HOST=$(echo "$EXT_NET_RANGE_START" | cut -d. -f4)
EXT_END_HOST=$(echo "$EXT_NET_RANGE_END" | cut -d. -f4)

if (( EXT_START_HOST >= EXT_END_HOST )); then
    echo "오류: 외부망 시작 IP가 끝 IP보다 크거나 같습니다."
    exit 1
fi

# --- 3. VIP 서브넷 검증 ---
echo "3. VIP 서브넷을 검증합니다..."

# 내부 IP 정보 추출
INTERNAL_IP_CIDR=$(ip -4 addr show "$INTERNAL_INTERFACE_NAME" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
INTERNAL_IP=$(echo "$INTERNAL_IP_CIDR" | cut -d'/' -f1)
PREFIX=$(echo "$INTERNAL_IP_CIDR" | cut -d'/' -f2)

echo "   - 내부 네트워크: $INTERNAL_IP_CIDR"

# 간단한 서브넷 검증 (C클래스 기준)
if (( PREFIX >= 24 )); then
    INTERNAL_NET=$(echo "$INTERNAL_IP" | cut -d. -f1-3)
    VIP_NET=$(echo "$KOLLA_VIP" | cut -d. -f1-3)
    
    if [[ "$INTERNAL_NET" != "$VIP_NET" ]]; then
        echo "오류: VIP 주소($KOLLA_VIP)가 내부 네트워크($INTERNAL_IP_CIDR)와 다른 서브넷에 있습니다."
        echo "VIP는 내부 네트워크와 같은 서브넷에 있어야 합니다."
        exit 1
    fi
elif (( PREFIX >= 16 )); then
    INTERNAL_NET=$(echo "$INTERNAL_IP" | cut -d. -f1-2)
    VIP_NET=$(echo "$KOLLA_VIP" | cut -d. -f1-2)
    
    if [[ "$INTERNAL_NET" != "$VIP_NET" ]]; then
        echo "오류: VIP 주소가 내부 네트워크와 다른 서브넷에 있습니다."
        exit 1
    fi
else
    echo "경고: 비정상적인 서브넷 마스크(/$PREFIX)입니다. VIP 설정을 수동으로 확인하세요."
fi

# VIP 중복 확인
if [[ "$KOLLA_VIP" == "$INTERNAL_IP" ]]; then
    echo "경고: VIP 주소($KOLLA_VIP)가 서버의 실제 IP 주소와 동일합니다."
    echo "단일 노드 테스트 환경에서만 권장됩니다."
fi

# IP 풀 크기 확인
POOL_SIZE=$(( EXT_END_HOST - EXT_START_HOST + 1 ))
if (( POOL_SIZE < 10 )); then
    echo "경고: 외부망 IP 풀이 작습니다(${POOL_SIZE}개). 최소 10개 이상 권장됩니다."
fi

echo "   - 모든 검증 완료"
echo "     VIP: $KOLLA_VIP (내부 네트워크: $INTERNAL_IP_CIDR)"
echo "     외부 IP 풀: $EXT_NET_RANGE_START ~ $EXT_NET_RANGE_END (총 ${POOL_SIZE}개)"
echo "     내부 NIC: $INTERNAL_INTERFACE_NAME"
echo "     외부 NIC: $EXTERNAL_INTERFACE_NAME"

# =================================================================================
# 최종 확인 및 설치 시작 여부 결정
# =================================================================================

echo ""
echo "=========================================="
echo "OpenStack 설치 준비 완료!"
echo "=========================================="
echo ""
echo "설정 요약:"
echo "  • VIP 주소: $KOLLA_VIP"
echo "  • 내부 인터페이스: $INTERNAL_INTERFACE_NAME"
echo "  • 외부 인터페이스: $EXTERNAL_INTERFACE_NAME"
echo "  • 외부 IP 풀: $EXT_NET_RANGE_START ~ $EXT_NET_RANGE_END"
echo ""
echo "주의: OpenStack 설치가 시작됩니다."
echo "   설치 과정은 20-30분 정도 소요되며, 중간에 중단하면 시스템이 불안정해질 수 있습니다."
echo ""
echo "5초 후 자동으로 설치가 시작됩니다."
echo "   설치를 중단하려면 아무 키나 누르세요..."

# 5초 대기하면서 키 입력 감지
if timeout 5 bash -c 'read -n 1 -s'; then
    echo ""
    echo ""
    echo "사용자에 의해 설치가 중단되었습니다."
    echo "   설치를 원하면 스크립트를 다시 실행하세요."
    exit 0
fi

echo ""
echo "설치를 시작합니다..."
echo ""

# 외부망 네트워크 정보 자동 생성
EXT_NET_RANGE="start=${EXT_NET_RANGE_START},end=${EXT_NET_RANGE_END}"
EXT_NET_SUBNET="$EXT_START_NET"
EXT_NET_CIDR="${EXT_NET_SUBNET}.0/24"
EXT_NET_GATEWAY="${EXT_NET_SUBNET}.1"

# =================================================================================
# 시스템 설치 준비
# =================================================================================





# --- 2. 시스템 사전 준비 자동화 ---

echo "4. 시스템 사전 준비를 시작합니다 (Swap, 방화벽 등)..."

sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo systemctl stop ufw apparmor || true
sudo systemctl disable ufw apparmor || true

# --- 3. 'stack' 사용자 생성 및 권한 설정 ---

echo "3. '$STACK_USER' 사용자를 생성하고 sudo 권한을 부여합니다..."

if ! id -u $STACK_USER > /dev/null 2>&1; then
    sudo useradd -s /bin/bash -d $STACK_HOME -m $STACK_USER
    sudo chmod 755 $STACK_HOME
    echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$STACK_USER
    sleep 2  # 사용자 생성 후 대기
fi

# --- 4. 필수 패키지 설치 ---

echo "4. 시스템을 업데이트하고 필수 패키지를 설치합니다..."

sudo apt-get update
sudo apt-get install -y git python3-dev libffi-dev python3-venv gcc libssl-dev python3-pip python3-full pkg-config libdbus-1-dev cmake libglib2.0-dev curl
sleep 2  # 패키지 설치 후 대기

# --- 여기부터 stack 사용자로 명령어 블록 실행 ---






# [수정] sudo 블록에 들어가기 전, 현재 스크립트의 디렉토리에서 globals.yml의 절대 경로를 미리 확인합니다.

echo "globals.yml 파일의 절대 경로를 확인합니다..."
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GLOBALS_FILE_PATH="$SCRIPT_DIR/globals.yml"

if [ ! -f "$GLOBALS_FILE_PATH" ]; then
    echo "오류: globals.yml 파일을 찾을 수 없습니다!"
    echo "스크립트와 동일한 디렉토리($SCRIPT_DIR)에 globals.yml 파일이 있어야 합니다."
    exit 1
fi
echo "   - globals.yml 파일 발견: $GLOBALS_FILE_PATH"
echo ""
sleep 2  # sudo 전환 전 대기

# 확실한 사용자 전환 확인
echo "stack 사용자로 전환을 시도합니다..."
sleep 1
id stack || { echo "오류: stack 사용자가 없습니다!"; exit 1; }
sleep 1
sudo su - stack <<EOF
set -e
sleep 2

cd $STACK_HOME
sleep 2

echo "5. Kolla-Ansible과 관련 라이브러리를 설치합니다..."

python3 -m venv $HOME/kolla-openstack
sleep 1  # 가상환경 생성 후 대기
source $HOME/kolla-openstack/bin/activate
pip install -U pip 'ansible>=8,<9' docker pkgconfig dbus-python
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2024.1
sleep 1  # kolla-ansible 설치 후 대기
deactivate

echo "6. Ansible 및 Kolla 설정을 준비합니다..."

cat > \$HOME/ansible.cfg <<EOC
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOC

sudo mkdir -p /etc/kolla
sudo chown stack:stack /etc/kolla
sleep 1  # 권한 설정 후 대기

echo "7. 로컬 globals.yml 설정을 적용합니다..."




# [수정] 외부에서 미리 확인해 둔 절대 경로 변수($GLOBALS_FILE_PATH)를 사용해 파일을 복사합니다.
echo "   - 원본 파일 위치: $GLOBALS_FILE_PATH"
sudo cp "$GLOBALS_FILE_PATH" /etc/kolla/globals.yml
sleep 1  # 파일 복사 후 대기





# 동적 설정 변경
sudo sed -i "s/^kolla_internal_vip_address:.*/kolla_internal_vip_address: \"$KOLLA_VIP\"/" /etc/kolla/globals.yml
sudo sed -i "s/^network_interface:.*/network_interface: \"$INTERNAL_INTERFACE_NAME\"/" /etc/kolla/globals.yml
sudo sed -i "s/^neutron_external_interface:.*/neutron_external_interface: \"$EXTERNAL_INTERFACE_NAME\"/" /etc/kolla/globals.yml
echo "   - 최종 설정 완료: VIP=$KOLLA_VIP, Internal NIC=$INTERNAL_INTERFACE_NAME, External NIC=$EXTERNAL_INTERFACE_NAME"

echo "8. OpenStack 배포를 시작합니다..."


INVENTORY_PATH="$HOME/kolla-openstack/share/kolla-ansible/ansible/inventory/all-in-one"

source $HOME/kolla-openstack/bin/activate
sleep 1  # 가상환경 활성화 후 대기

kolla-ansible install-deps
sleep 2  # install-deps 후 대기
kolla-genpwd
sleep 1  # genpwd 후 대기
kolla-ansible -i \$INVENTORY_PATH bootstrap-servers
sleep 3  # bootstrap-servers 후 대기
kolla-ansible -i \$INVENTORY_PATH prechecks
sleep 2  # prechecks 후 대기
kolla-ansible -i \$INVENTORY_PATH deploy
sleep 3  # deploy 후 대기

echo "9. 배포 후 마무리 작업을 진행합니다..."

sudo usermod -aG docker stack
sleep 1  # docker 그룹 추가 후 대기
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/2024.1
sleep 1  # openstackclient 설치 후 대기
kolla-ansible -i \$INVENTORY_PATH post-deploy
sleep 2  # post-deploy 후 대기
source /etc/kolla/admin-openrc.sh
sleep 1  # admin-openrc 로드 후 대기

echo "10. 'init-runonce' 스크립트를 실행하여 초기 환경을 설정합니다..."

INIT_RUNONCE_PATH="$HOME/kolla-openstack/share/kolla-ansible/init-runonce"
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