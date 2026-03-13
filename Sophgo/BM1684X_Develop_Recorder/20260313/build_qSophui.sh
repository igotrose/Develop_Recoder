#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# Basic configuration
########################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
BUILD_DIR="${ROOT_DIR}/build"
INSTALL_DIR="${ROOT_DIR}/install"

# Support two possible .pro file locations
PRO_FILE_1="${ROOT_DIR}/SophUI.pro"
PRO_FILE_2="${ROOT_DIR}/SophUI/SophUI.pro"

PKG_ROOT="${ROOT_DIR}/SophUI"
PKG_DEB_DIR="${PKG_ROOT}/deb"
PKG_OUTPUT="${PKG_ROOT}/sophgo-hdmi_1.6.8_arm64.deb"
PKG_BIN_DST="${PKG_DEB_DIR}/bm_services/SophonHDMI/SophUI"

DFSS_FLAG="sophgo-bsp-qt5-toolchain"

QMAKE_BIN="${INSTALL_DIR}/bin/qmake"
MAKE_JOBS="$(nproc)"

########################################
# Logging helpers
########################################
log() {
    echo -e "\033[1;32m[INFO]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

err() {
    echo -e "\033[1;31m[ERR ]\033[0m $*" >&2
}

########################################
# Help
########################################
usage() {
    cat <<EOF
Usage:
  $0 [build|clean|rebuild|package|all]

Commands:
  build    Check tools and build the project
  clean    Remove the build directory
  rebuild  Clean and then build
  package  Package only (requires a successful build first)
  all      Build and package

Default:
  If no argument is provided, "all" will be used.
EOF
}

########################################
# Check whether sudo is available
########################################
SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        warn "Current user is not root and sudo is not available. Dependency installation may fail."
    fi
fi

########################################
# Detect project file
########################################
detect_pro_file() {
    if [[ -f "${PRO_FILE_1}" ]]; then
        echo "${PRO_FILE_1}"
        return 0
    fi
    if [[ -f "${PRO_FILE_2}" ]]; then
        echo "${PRO_FILE_2}"
        return 0
    fi

    err "No .pro file found:"
    err "  - ${PRO_FILE_1}"
    err "  - ${PRO_FILE_2}"
    exit 1
}

########################################
# Check and install dfss
########################################
ensure_dfss() {
    log "Checking dfss ..."
    if ! python3 -m pip show dfss >/dev/null 2>&1; then
        log "dfss not found, installing/upgrading ..."
        python3 -m pip install --upgrade dfss
    else
        log "dfss is already installed, upgrading ..."
        python3 -m pip install --upgrade dfss
    fi
}

########################################
# Check and download qmake toolchain
########################################
ensure_qmake() {
    if [[ ! -x "${QMAKE_BIN}" ]]; then
        log "qmake not found at ${QMAKE_BIN}, downloading toolchain via dfss ..."
        mkdir -p "${INSTALL_DIR}"
        (
            cd "${ROOT_DIR}"
            python3 -m dfss --dflag="${DFSS_FLAG}"
        )
    fi

    if [[ ! -x "${QMAKE_BIN}" ]]; then
        err "qmake still not found: ${QMAKE_BIN}"
        err "Please check the dfss download result or the install directory structure."
        exit 1
    fi

    log "qmake path: ${QMAKE_BIN}"
    "${QMAKE_BIN}" -query || {
        err "Failed to execute qmake"
        exit 1
    }
}

########################################
# Check and install aarch64 cross toolchain
########################################
ensure_cross_tools() {
    local missing=0

    if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        warn "Missing aarch64-linux-gnu-gcc"
        missing=1
    fi
    if ! command -v aarch64-linux-gnu-g++ >/dev/null 2>&1; then
        warn "Missing aarch64-linux-gnu-g++"
        missing=1
    fi
    if ! command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        warn "Missing aarch64-linux-gnu-strip"
        missing=1
    fi

    if [[ "${missing}" -eq 1 ]]; then
        log "Installing aarch64 cross-compilation toolchain ..."
        ${SUDO} apt update
        ${SUDO} apt install -y \
            gcc-aarch64-linux-gnu \
            g++-aarch64-linux-gnu \
            binutils-aarch64-linux-gnu \
            make
    fi

    log "Cross toolchain detection result:"
    echo "gcc   : $(command -v aarch64-linux-gnu-gcc || true)"
    echo "g++   : $(command -v aarch64-linux-gnu-g++ || true)"
    echo "strip : $(command -v aarch64-linux-gnu-strip || true)"

    command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || { err "aarch64-linux-gnu-gcc not found"; exit 1; }
    command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 || { err "aarch64-linux-gnu-g++ not found"; exit 1; }
    command -v aarch64-linux-gnu-strip >/dev/null 2>&1 || { err "aarch64-linux-gnu-strip not found"; exit 1; }
}

########################################
# Clean
########################################
clean_build() {
    log "Removing build directory: ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
    log "Clean completed"
}

########################################
# Build
########################################
build_project() {
    local PRO_FILE
    PRO_FILE="$(detect_pro_file)"

    log "Using .pro file: ${PRO_FILE}"
    mkdir -p "${BUILD_DIR}"

    pushd "${BUILD_DIR}" >/dev/null

    log "Running qmake ..."
    "${QMAKE_BIN}" "${PRO_FILE}" "CONFIG+=release" "CONFIG-=debug"

    log "Running make -j${MAKE_JOBS} ..."
    make -j"${MAKE_JOBS}"

    popd >/dev/null

    if [[ ! -f "${BUILD_DIR}/SophUI" ]]; then
        err "Build finished, but output file was not found: ${BUILD_DIR}/SophUI"
        exit 1
    fi

    chmod 755 "${BUILD_DIR}/SophUI"
    log "Build succeeded: ${BUILD_DIR}/SophUI"
}

########################################
# Package
########################################
package_project() {
    if [[ ! -f "${BUILD_DIR}/SophUI" ]]; then
        err "Built SophUI binary not found: ${BUILD_DIR}/SophUI"
        err "Please run build or all first"
        exit 1
    fi

    if [[ ! -d "${PKG_DEB_DIR}" ]]; then
        err "Package directory not found: ${PKG_DEB_DIR}"
        exit 1
    fi

    mkdir -p "$(dirname "${PKG_BIN_DST}")"

    log "Copying SophUI into package directory ..."
    cp "${BUILD_DIR}/SophUI" "${PKG_BIN_DST}"
    chmod 755 "${PKG_BIN_DST}"

    if compgen -G "${PKG_DEB_DIR}/DEBIAN/p*" >/dev/null; then
        chmod 755 "${PKG_DEB_DIR}/DEBIAN"/p*
    else
        warn "No files matched ${PKG_DEB_DIR}/DEBIAN/p*, skipping chmod"
    fi

    log "Building deb package ..."
    pushd "${PKG_ROOT}" >/dev/null
    dpkg-deb -b deb "$(basename "${PKG_OUTPUT}")"
    popd >/dev/null

    if [[ ! -f "${PKG_OUTPUT}" ]]; then
        err "Deb package creation failed, output not found: ${PKG_OUTPUT}"
        exit 1
    fi

    log "Package succeeded: ${PKG_OUTPUT}"
}

########################################
# Main flow
########################################
main() {
    local action="${1:-all}"

    case "${action}" in
        build)
            ensure_dfss
            ensure_qmake
            ensure_cross_tools
            build_project
            ;;
        clean)
            clean_build
            ;;
        rebuild)
            clean_build
            ensure_dfss
            ensure_qmake
            ensure_cross_tools
            build_project
            ;;
        package)
            package_project
            ;;
        all)
            ensure_dfss
            ensure_qmake
            ensure_cross_tools
            build_project
            package_project
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            err "Unknown argument: ${action}"
            usage
            exit 1
            ;;
    esac
}

main "$@"