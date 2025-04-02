#!/usr/bin/env bash
export LLVM_NAME="Kaleidoscope"
export STABLE_TAG="main"
export HOME_DIR="$(pwd)"
export INSTALL="${HOME_DIR}/install"
export CHAT_ID="$TELEGRAM_CHAT"
export BUILD_DATE="$(date "+%Y%m%d")"
export BUILD_DAY="$(date "+%d %B %Y, %H:%M %Z")"
export BUILD_TAG="$(date "+%Y%m%d-%H%M-%Z")"
export NPROC="$(nproc --all)"
export CUSTOM_FLAGS="
  LLVM_PARALLEL_TABLEGEN_JOBS=${NPROC}
  LLVM_PARALLEL_COMPILE_JOBS=${NPROC}
  LLVM_PARALLEL_LINK_JOBS=${NPROC}
  LLVM_OPTIMIZED_TABLEGEN=ON
  CMAKE_C_FLAGS='-O3 -pipe -ffunction-sections -fdata-sections -fno-plt -fmerge-all-constants -fomit-frame-pointer -funroll-loops -falign-functions=64 -march=haswell -mtune=diamondrapids -mllvm -polly -mllvm -polly-position=early -mllvm -polly-vectorizer=stripmine -mllvm -polly-run-dce'
  CMAKE_CXX_FLAGS='-O3 -pipe -ffunction-sections -fdata-sections -fno-plt -fmerge-all-constants -fomit-frame-pointer -funroll-loops -falign-functions=64 -march=haswell -mtune=diamondrapids -mllvm -polly -mllvm -polly-position=early -mllvm -polly-vectorizer=stripmine -mllvm -polly-run-dce'
  CMAKE_EXE_LINKER_FLAGS='-Wl,-O3,--lto-O3,--lto-CGO3,--gc-sections,--strip-debug'
  CMAKE_MODULE_LINKER_FLAGS='-Wl,-O3,--lto-O3,--lto-CGO3,--gc-sections,--strip-debug'
  CMAKE_SHARED_LINKER_FLAGS='-Wl,-O3,--lto-O3,--lto-CGO3,--gc-sections,--strip-debug'
  CMAKE_STATIC_LINKER_FLAGS='-Wl,-O3,--lto-O3,--lto-CGO3,--gc-sections,--strip-debug'
  "

FINAL=false
RELEASE=false
for ARGS in $@; do
  case $ARGS in
  final)
    FINAL=true
    ;;
  release)
    RELEASE=true
    ;;
  esac
done
export FINAL RELEASE

send_info() {
  curl -s -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage \
    -d chat_id="${CHAT_ID}" \
    -d "parse_mode=html" \
    -d text="<b>${1}</b><code>${2}</code>" >/dev/null 2>&1
}

send_file() {
  curl -s -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument \
    -F document=@"${2}" \
    -F chat_id="${CHAT_ID}" \
    -F "parse_mode=html" \
    -F caption="${1}" >/dev/null 2>&1
}

build_llvm() {
  if ${FINAL}; then
    ADD="${ADD} --final"
  fi

  if ${RELEASE}; then
    ADD="${ADD} --ref ${STABLE_TAG}"
  fi

  ./build-llvm.py ${ADD} \
    --build-type "Release" \
    --build-stage1-only \
    --defines "${CUSTOM_FLAGS}" \
    --install-folder "${INSTALL}" \
    --lto thin \
    --pgo llvm \
    --projects clang lld polly \
    --shallow-clone \
    --targets AArch64 ARM X86 \
    --no-update \
    --vendor-string "${LLVM_NAME}" |& tee -a build.log

  # Check LLVM files
  if [ -f ${INSTALL}/bin/clang ]; then
    send_info "Action : " "LLVM compilation finished ! ! !"
  elif [ -f ${HOME_DIR}/build/llvm/instrumented/profdata.prof ]; then
    send_info "Action : " "Instrumented LLVM compilation finished ! ! !"
  else
    send_info "Action : " "LLVM compilation failed ! ! !"
    send_file "LLVM build.log" ./build.log
    exit 1
  fi
}

build_zstd() {
  git clone https://github.com/facebook/zstd -b v1.5.7 --depth=1
  cd zstd
  cmake build/cmake -DCMAKE_INSTALL_PREFIX="${INSTALL}/.zstd" |& tee -a build.log
  make -j${NPROC} |& tee -a build.log
  make install -j${NPROC} |& tee -a build.log
  cd -
}

strip_binaries() {
  find ${INSTALL} -type f -exec file {} \; >.file-idx
  cp ${INSTALL}/bin/llvm-objcopy ./strip
  grep "not strip" .file-idx |
    tr ':' ' ' | awk '{print $1}' |
    while read -r file; do ./strip --strip-all-gnu "${file}"; done

  # clean unused files
  rm -rf strip .file-idx
}

git_release() {
  CLANG_VERSION="$(${INSTALL}/bin/clang --version | head -n1 | cut -d ' ' -f4)"
  MESSAGE="Clang: ${CLANG_VERSION}-${BUILD_DATE}"
  cd ${INSTALL}
  # tar -I"${INSTALL}/.zstd/bin/zstd --ultra -22 -T0" -cf clang.tar.zst *
  tar -I "zstd --ultra -22 -T0" -cf clang.tar.zst *
  cd ..
  git config --global user.name github-actions[bot]
  git config --global user.email github-actions[bot]@users.noreply.github.com
  git clone https://sandatjepil:${GITHUB_TOKEN}@github.com/PurrrsLitterbox/clang-releases.git clang -b main
  cd clang
  cat README | sed s/LLVM_VERSION/${CLANG_VERSION}/g | sed s/SIZE/$(du -m ${INSTALL}/clang.tar.zst | cut -f1)/g > README.md
  echo "https://github.com/PurrrsLitterbox/clang-releases/releases/download/${BUILD_TAG}/clang.tar.zst" > latestlink.txt
  send_info "Date : " "${BUILD_DAY}"
  send_info "Action : " "Release into GitHub . . ."
  send_info "Clang Version : " "${CLANG_VERSION}"
  git add . && git commit --allow-empty -sm "${MESSAGE}"
  git push origin main
  cp ${INSTALL}/clang.tar.zst .
  hub release create -a clang.tar.zst -m "${MESSAGE}

$(cat README.md)" "${BUILD_TAG}"
  send_info "Action : " "Toolchain released ! ! !"
  cd ..
}

build_llvm
if ${FINAL}; then
  # build_zstd
  strip_binaries
  git_release
fi
