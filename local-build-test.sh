#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Script para executar MPTCP kernel build e testes localmente
# Baseado no entrypoint.sh do mptcp-upstream-virtme-docker
#
# ATENÇÃO: Este script compila e instala um kernel experimental!
# Use com cuidado e tenha backups/snapshots do sistema.

set -e

# Cores para output
COLOR_RED="\E[1;31m"
COLOR_GREEN="\E[1;32m"
COLOR_YELLOW="\E[1;33m"
COLOR_BLUE="\E[1;34m"
COLOR_RESET="\E[0m"

print_color() {
    echo -e "${*}${COLOR_RESET}"
}

print() {
    print_color "${COLOR_GREEN}${*}"
}

printinfo() {
    print_color "${COLOR_BLUE}${*}"
}

printerr() {
    print_color "${COLOR_RED}${*}" >&2
}

printwarn() {
    print_color "${COLOR_YELLOW}${*}"
}

# Configurações
KERNEL_SRC="${PWD}"
BUILD_DIR="${KERNEL_SRC}/.local-build"
SELFTESTS_DIR="tools/testing/selftests/net/mptcp"
BPFTESTS_DIR="tools/testing/selftests/bpf"
PACKETDRILL_DIR="/opt/packetdrill"

# Opções de compilação
USE_CLANG="${USE_CLANG:-0}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"
INSTALL_KERNEL="${INSTALL_KERNEL:-0}"

log_section_start() {
    print "=== $1 ==="
}

log_section_end() {
    print "=== Concluído ===\n"
}

check_dependencies() {
    log_section_start "Verificando dependências"
    
    local missing=()
    
    # Dependências básicas para compilação de kernel
    for dep in make gcc flex bison libssl-dev libelf-dev bc; do
        if ! dpkg -s "$dep" &>/dev/null && ! rpm -q "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Se usar clang
    if [ "$USE_CLANG" = "1" ]; then
        for dep in clang llvm; do
            if ! command -v "$dep" &>/dev/null; then
                missing+=("$dep")
            fi
        done
    fi
    
    # Dependências para testes
    # for dep in iperf3 netcat-openbsd tcpdump; do
    #     if ! command -v "$dep" &>/dev/null; then
    #         missing+=("$dep")
    #     fi
    # done
    
    if [ ${#missing[@]} -gt 0 ]; then
        printerr "Dependências em falta: ${missing[*]}"
        printinfo "Ubuntu/Debian: sudo apt install ${missing[*]}"
        printinfo "CentOS/RHEL: sudo yum install ${missing[*]}"
        exit 1
    fi
    
    print "Todas as dependências estão disponíveis"
    log_section_end
}

setup_build_env() {
    log_section_start "Configurando ambiente de compilação"
    
    mkdir -p "${BUILD_DIR}"
    
    # Argumentos do make
    MAKE_ARGS=()
    if [ "$USE_CLANG" = "1" ]; then
        MAKE_ARGS+=(LLVM=1 LLVM_IAS=1 CC=clang ARCH="$(uname -m)")
        print "Usando Clang como compilador"
    else
        print "Usando GCC como compilador"
    fi
    
    MAKE_ARGS+=(O="${BUILD_DIR}" -j"${MAKE_JOBS}")
    
    export KBUILD_OUTPUT="${BUILD_DIR}"
    
    log_section_end
}

gen_kconfig() {
    log_section_start "Gerando configuração do kernel (BTF + Debug)"
    
    # Configuração base
    make "${MAKE_ARGS[@]}" defconfig
    
    # Configurações específicas para MPTCP (baseadas em tools/testing/selftests/net/mptcp/config)
    if [ -f "${SELFTESTS_DIR}/config" ]; then
        print "Aplicando configurações do ${SELFTESTS_DIR}/config"
        
        # Ler e aplicar configurações do arquivo config
        while IFS= read -r line; do
            if [[ "$line" =~ ^CONFIG_.*=.* ]]; then
                config_name="${line%%=*}"
                config_value="${line#*=}"
                ./scripts/config --file "${BUILD_DIR}/.config" --set-str "${config_name#CONFIG_}" "${config_value}"
            elif [[ "$line" =~ ^CONFIG_.*$ ]]; then
                config_name="${line#CONFIG_}"
                ./scripts/config --file "${BUILD_DIR}/.config" --enable "${config_name}"
            fi
        done < "${SELFTESTS_DIR}/config"
    fi
    
    # Configurações BTF (necessárias para BPF)
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable DEBUG_INFO \
        --enable DEBUG_INFO_BTF \
        --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
        --enable BPF \
        --enable BPF_SYSCALL \
        --enable BPF_JIT
    
    # Configurações de debug
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable DEBUG_KERNEL \
        --enable DEBUG_INFO \
        --enable GDB_SCRIPTS \
        --enable KFENCE \
        --enable DEBUG_NET \
        --enable NET_NS_REFCNT_TRACKER
    
    # Configurações extras para MPTCP
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable MPTCP \
        --enable MPTCP_IPV6 \
        --enable INET_MPTCP_DIAG \
        --enable TUN \
        --enable CRYPTO_USER_API_HASH \
        --enable CRYPTO_SHA1
    
    # KUnit para testes
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --module KUNIT \
        --enable KUNIT_DEBUGFS \
        --module MPTCP_KUNIT_TEST
    
    # Finalizar configuração
    make "${MAKE_ARGS[@]}" olddefconfig
    
    print "Configuração do kernel gerada em ${BUILD_DIR}/.config"
    log_section_end
}

build_kernel() {
    log_section_start "Compilando kernel"
    
    make "${MAKE_ARGS[@]}"
    
    print "Kernel compilado com sucesso"
    log_section_end
}

install_kernel_headers() {
    log_section_start "Instalando headers do kernel"
    
    local headers_dir="${BUILD_DIR}/headers"
    make "${MAKE_ARGS[@]}" headers_install INSTALL_HDR_PATH="${headers_dir}"
    
    print "Headers instalados em ${headers_dir}"
    log_section_end
}

build_selftests() {
    log_section_start "Compilando selftests MPTCP"
    
    if [ ! -d "${SELFTESTS_DIR}" ]; then
        printerr "Diretório ${SELFTESTS_DIR} não encontrado"
        return 1
    fi
    
    make "${MAKE_ARGS[@]}" -C "${SELFTESTS_DIR}"
    
    print "Selftests MPTCP compilados"
    log_section_end
}

build_bpftests() {
    log_section_start "Compilando BPF tests"
    
    if [ ! -d "${BPFTESTS_DIR}" ]; then
        printwarn "Diretório ${BPFTESTS_DIR} não encontrado, pulando BPF tests"
        return 0
    fi
    
    local headers_dir="${BUILD_DIR}/headers"
    make "${MAKE_ARGS[@]}" KHDR_INCLUDES="-I${headers_dir}/include" -C "${BPFTESTS_DIR}"
    
    print "BPF tests compilados"
    log_section_end
}

install_kernel_prompt() {
    if [ "$INSTALL_KERNEL" != "1" ]; then
        printwarn "ATENÇÃO: Para executar os testes, você precisa instalar o kernel compilado."
        printwarn "Isso irá modificar o seu sistema e requer reinicialização."
        echo
        read -p "Deseja instalar o kernel agora? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            printinfo "Kernel não instalado. Para instalar manualmente:"
            printinfo "  sudo make -C ${BUILD_DIR} modules_install"
            printinfo "  sudo make -C ${BUILD_DIR} install"
            printinfo "  sudo update-grub  # ou equivalente para seu sistema"
            printinfo "  sudo reboot"
            return 1
        fi
    fi
    return 0
}

install_kernel() {
    log_section_start "Instalando kernel"
    
    if ! install_kernel_prompt; then
        return 1
    fi
    
    printwarn "Instalando kernel - isso requer privilégios de root"
    
    # Instalar módulos
    sudo make -C "${BUILD_DIR}" modules_install
    
    # Instalar kernel
    sudo make -C "${BUILD_DIR}" install
    
    # Atualizar bootloader
    if command -v update-grub &>/dev/null; then
        sudo update-grub
    elif command -v grub2-mkconfig &>/dev/null; then
        sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        printwarn "Não foi possível atualizar o bootloader automaticamente"
        printwarn "Você pode precisar atualizar manualmente"
    fi
    
    print "Kernel instalado. Reinicie o sistema para usar o novo kernel."
    log_section_end
}

run_selftests() {
    log_section_start "Executando selftests MPTCP"
    
    cd "${SELFTESTS_DIR}"
    
    printinfo "Executando testes MPTCP..."
    
    # Lista de testes principais
    local tests=(
        "./mptcp_connect.sh"
        "./mptcp_join.sh"
        "./mptcp_sockopt.sh"
        "./diag.sh"
    )
    
    for test in "${tests[@]}"; do
        if [ -x "$test" ]; then
            print "Executando $(basename "$test")..."
            if "$test"; then
                print "✓ $(basename "$test") passou"
            else
                printerr "✗ $(basename "$test") falhou"
            fi
        else
            printwarn "Teste $test não encontrado ou não executável"
        fi
    done
    
    cd "${KERNEL_SRC}"
    log_section_end
}

run_kunit_tests() {
    log_section_start "Executando KUnit tests MPTCP"
    
    local kunit_modules="${BUILD_DIR}/net/mptcp/*_test.ko"
    
    for module in $kunit_modules; do
        if [ -f "$module" ]; then
            print "Carregando módulo KUnit: $(basename "$module")"
            sudo insmod "$module" || true
        fi
    done
    
    # Verificar resultados em /sys/kernel/debug/kunit/
    if [ -d "/sys/kernel/debug/kunit" ]; then
        print "Resultados KUnit disponíveis em /sys/kernel/debug/kunit/"
    fi
    
    log_section_end
}

show_summary() {
    log_section_start "Resumo"
    
    print "Build completo!"
    printinfo "Kernel compilado em: ${BUILD_DIR}"
    printinfo "Selftests disponíveis em: ${SELFTESTS_DIR}"
    
    if [ "$INSTALL_KERNEL" = "1" ]; then
        printinfo "Kernel instalado - reinicie para usar"
    else
        printinfo "Para instalar o kernel: INSTALL_KERNEL=1 $0"
    fi
    
    printinfo "Para executar apenas os testes: $0 test"
    
    log_section_end
}

case "${1:-build}" in
    "build")
        check_dependencies
        setup_build_env
        gen_kconfig
        build_kernel
        install_kernel_headers
        build_selftests
        build_bpftests
        install_kernel
        show_summary
        ;;
    "test")
        run_selftests
        run_kunit_tests
        ;;
    "install")
        INSTALL_KERNEL=1
        install_kernel
        ;;
    "config")
        setup_build_env
        gen_kconfig
        print "Configuração gerada em ${BUILD_DIR}/.config"
        ;;
    *)
        echo "Uso: $0 [build|test|install|config]"
        echo "  build  - Compila kernel e testes (padrão)"
        echo "  test   - Executa apenas os testes"
        echo "  install- Instala o kernel compilado"
        echo "  config - Gera apenas a configuração"
        echo
        echo "Variáveis de ambiente:"
        echo "  USE_CLANG=1     - Usar Clang em vez de GCC"
        echo "  MAKE_JOBS=N     - Número de jobs paralelos"
        echo "  INSTALL_KERNEL=1- Instalar kernel automaticamente"
        exit 1
        ;;
esac
