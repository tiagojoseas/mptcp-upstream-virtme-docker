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
BTF_MODE="${BTF_MODE:-1}"  # Habilitar BTF por padrão para BPF tests

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
    
    # Dependências específicas para BPF schedulers MPTCP
    for dep in pahole dwarves; do
        if ! command -v pahole &>/dev/null && ! dpkg -s "$dep" &>/dev/null && ! rpm -q "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    # Dependências para testes (opcionais)
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
    
    # Verificar se bpftool está disponível ou será compilado
    if ! command -v bpftool &>/dev/null; then
        printinfo "bpftool não encontrado, será compilado junto com o kernel"
    else
        print "bpftool encontrado: $(which bpftool)"
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
    
    # Configurações BTF (necessárias para BPF) - sempre habilitar se BTF_MODE=1
    if [ "$BTF_MODE" = "1" ]; then
        print "Habilitando BTF para suporte BPF completo (schedulers MPTCP)"
        ./scripts/config --file "${BUILD_DIR}/.config" \
            --enable DEBUG_INFO \
            --enable DEBUG_INFO_BTF \
            --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
            --enable BPF \
            --enable BPF_SYSCALL \
            --enable BPF_JIT \
            --enable BPF_LSM \
            --enable BPF_PRELOAD
    fi
    
    # Configurações específicas para MPTCP BPF schedulers
    ./scripts/config --file "${BUILD_DIR}/.config" \
        --enable MPTCP \
        --enable MPTCP_IPV6 \
        --enable INET_MPTCP_DIAG \
        --enable BPF_STRUCT_OPS \
        --enable BPF_KPROBE_OVERRIDE
    
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
    if [ "$BTF_MODE" = "1" ]; then
        print "BTF habilitado para testes BPF completos"
    fi
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
    log_section_start "Compilando BPF tests e schedulers MPTCP"
    
    if [ ! -d "${BPFTESTS_DIR}" ]; then
        printwarn "Diretório ${BPFTESTS_DIR} não encontrado, pulando BPF tests"
        return 0
    fi
    
    local headers_dir="${BUILD_DIR}/headers"
    
    # Compilar BPF selftests incluindo schedulers MPTCP
    make "${MAKE_ARGS[@]}" KHDR_INCLUDES="-I${headers_dir}/include" -C "${BPFTESTS_DIR}"
    
    # Copiar test_progs para o BUILD_DIR para facilitar localização
    if [ -f "${BPFTESTS_DIR}/test_progs" ]; then
        cp "${BPFTESTS_DIR}/test_progs"* "${BUILD_DIR}/" 2>/dev/null || true
        print "test_progs copiados para ${BUILD_DIR}"
    fi
    
    # Verificar se os schedulers MPTCP foram compilados
    local mptcp_schedulers=(
        "mptcp_bpf_first.bpf.o"
        "mptcp_bpf_rr.bpf.o" 
        "mptcp_bpf_burst.bpf.o"
        "mptcp_bpf_red.bpf.o"
        "mptcp_bpf_bkup.bpf.o"
    )
    
    local schedulers_found=0
    for scheduler in "${mptcp_schedulers[@]}"; do
        if [ -f "${BPFTESTS_DIR}/${scheduler}" ]; then
            schedulers_found=1
            cp "${BPFTESTS_DIR}/${scheduler}" "${BUILD_DIR}/" 2>/dev/null || true
            print "Scheduler MPTCP compilado: ${scheduler}"
        fi
    done
    
    if [ "$schedulers_found" = "1" ]; then
        print "Schedulers MPTCP BPF disponíveis em ${BUILD_DIR}/"
        printinfo "Use 'bpftool struct_ops load <scheduler>.bpf.o' para carregar"
    else
        printwarn "Nenhum scheduler MPTCP BPF encontrado"
    fi
    
    print "BPF tests compilados"
    log_section_end
}

build_bpftool() {
    log_section_start "Compilando bpftool"
    
    # bpftool é essencial para carregar schedulers MPTCP BPF
    if command -v bpftool &>/dev/null; then
        print "bpftool já disponível: $(which bpftool)"
        log_section_end
        return 0
    fi
    
    local bpftool_dir="tools/bpf/bpftool"
    local headers_dir="${BUILD_DIR}/headers"
    
    if [ ! -d "$bpftool_dir" ]; then
        printwarn "Diretório $bpftool_dir não encontrado"
        log_section_end
        return 1
    fi
    
    cd "$bpftool_dir"
    
    # Compilar bpftool
    make "${MAKE_ARGS[@]}" EXTRA_CFLAGS="-I${headers_dir}/include"
    
    # Copiar para BUILD_DIR para fácil acesso
    cp bpftool "${BUILD_DIR}/"
    
    # Adicionar ao PATH temporariamente
    export PATH="${BUILD_DIR}:${PATH}"
    
    cd "${KERNEL_SRC}"
    
    print "bpftool compilado e disponível em ${BUILD_DIR}/bpftool"
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
        
        # Mostrar resultados se disponíveis
        for result_file in /sys/kernel/debug/kunit/*/results; do
            if [ -r "$result_file" ]; then
                local test_name=$(basename "$(dirname "$result_file")")
                print "Resultados do KUnit test: $test_name"
                cat "$result_file" || true
            fi
        done
    fi
    
    log_section_end
}

run_bpf_test_progs() {
    log_section_start "Executando BPF test_progs"
    
    # Verificar se estamos no modo BTF (necessário para BPF)
    if [ ! -f "${BUILD_DIR}/.config" ] || ! grep -q "CONFIG_DEBUG_INFO_BTF=y" "${BUILD_DIR}/.config"; then
        printwarn "BTF não habilitado, pulando BPF test_progs"
        printwarn "Para executar BPF tests, use: BTF_MODE=1 $0"
        log_section_end
        return 0
    fi
    
    # Procurar por executáveis test_progs compilados
    local test_progs_found=0
    for test_prog in "${BUILD_DIR}/test_progs"*; do
        if [ -x "$test_prog" ]; then
            test_progs_found=1
            local prog_name=$(basename "$test_prog")
            print "Executando BPF test: $prog_name"
            
            # Executar test_progs com filtro para testes MPTCP se disponível
            if "$test_prog" --help 2>&1 | grep -q "\-t.*test.*filter"; then
                "$test_prog" -t mptcp || true
            else
                "$test_prog" || true
            fi
        fi
    done
    
    if [ "$test_progs_found" = "0" ]; then
        printwarn "Nenhum test_progs encontrado em ${BUILD_DIR}"
        printwarn "Certifique-se de que os BPF tests foram compilados"
    fi
    
    log_section_end
}

test_mptcp_schedulers() {
    log_section_start "Testando carregamento de schedulers MPTCP BPF"
    
    # Verificar se bpftool está disponível
    if ! command -v bpftool &>/dev/null && ! [ -x "${BUILD_DIR}/bpftool" ]; then
        printwarn "bpftool não disponível, pulando teste de schedulers"
        log_section_end
        return 0
    fi
    
    local bpftool_cmd="bpftool"
    if [ -x "${BUILD_DIR}/bpftool" ]; then
        bpftool_cmd="${BUILD_DIR}/bpftool"
    fi
    
    # Verificar schedulers disponíveis
    print "Schedulers MPTCP disponíveis:"
    ls -la "${BUILD_DIR}"/mptcp_bpf_*.o 2>/dev/null || {
        printwarn "Nenhum scheduler MPTCP encontrado em ${BUILD_DIR}"
        log_section_end
        return 0
    }
    
    # Testar carregamento de um scheduler (exemplo: first)
    local test_scheduler="${BUILD_DIR}/mptcp_bpf_first.bpf.o"
    if [ -f "$test_scheduler" ]; then
        print "Testando carregamento do scheduler 'first'..."
        
        # Tentar carregar o scheduler
        if sudo "$bpftool_cmd" struct_ops load "$test_scheduler"; then
            print "✓ Scheduler 'first' carregado com sucesso!"
            
            # Mostrar struct_ops carregados
            print "Struct_ops BPF carregados:"
            sudo "$bpftool_cmd" struct_ops show || true
            
            # Mostrar schedulers MPTCP disponíveis no sistema
            print "Schedulers MPTCP disponíveis no sistema:"
            cat /proc/sys/net/mptcp/scheduler 2>/dev/null || true
            
        else
            printwarn "Falha ao carregar scheduler 'first'"
        fi
    else
        printwarn "Scheduler de teste não encontrado: $test_scheduler"
    fi
    
    log_section_end
}

show_summary() {
    log_section_start "Resumo"
    
    print "Build completo!"
    printinfo "Kernel compilado em: ${BUILD_DIR}"
    printinfo "Selftests disponíveis em: ${SELFTESTS_DIR}"
    printinfo "Schedulers MPTCP BPF em: ${BUILD_DIR}/mptcp_bpf_*.bpf.o"
    
    if [ -x "${BUILD_DIR}/bpftool" ]; then
        printinfo "bpftool disponível em: ${BUILD_DIR}/bpftool"
    fi
    
    if [ "$INSTALL_KERNEL" = "1" ]; then
        printinfo "Kernel instalado - reinicie para usar"
    else
        printinfo "Para instalar o kernel: INSTALL_KERNEL=1 $0"
    fi
    
    printinfo "Para executar testes: $0 test"
    printinfo "Para testar schedulers: $0 schedulers"
    
    print ""
    print "Como usar schedulers MPTCP BPF:"
    print "1. sudo ${BUILD_DIR}/bpftool struct_ops load ${BUILD_DIR}/mptcp_bpf_first.bpf.o"
    print "2. echo 'bpf_first' | sudo tee /proc/sys/net/mptcp/scheduler"
    
    log_section_end
}

case "${1:-build}" in
    "build")
        check_dependencies
        setup_build_env
        gen_kconfig
        build_kernel
        install_kernel_headers
        build_bpftool
        build_selftests
        build_bpftests
        install_kernel
        show_summary
        ;;
    "test")
        run_selftests
        run_kunit_tests
        run_bpf_test_progs
        test_mptcp_schedulers
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
    "schedulers")
        test_mptcp_schedulers
        ;;
    *)
        echo "Uso: $0 [build|test|install|config|schedulers]"
        echo "  build      - Compila kernel e testes (padrão)"
        echo "  test       - Executa todos os testes"
        echo "  install    - Instala o kernel compilado"
        echo "  config     - Gera apenas a configuração"
        echo "  schedulers - Testa carregamento de schedulers MPTCP BPF"
        echo
        echo "Variáveis de ambiente:"
        echo "  USE_CLANG=1     - Usar Clang em vez de GCC"
        echo "  MAKE_JOBS=N     - Número de jobs paralelos"
        echo "  INSTALL_KERNEL=1- Instalar kernel automaticamente"
        echo "  BTF_MODE=1      - Habilitar BTF para BPF tests (padrão)"
        exit 1
        ;;
esac
