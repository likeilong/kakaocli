#!/usr/bin/env bash
# install.sh — 빌드 → **안정적 코드서명** → ~/.local/bin 설치.
#
# 왜 서명이 필수인가 (2026-07 실제 사고):
#   Swift 기본 빌드는 ad-hoc(linker-signed) 바이너리를 만든다. macOS TCC는 ad-hoc 바이너리를
#   **cdhash(내용 해시)로 식별**하므로, 재빌드할 때마다 "완전히 다른 프로그램"이 된다.
#   → 이전에 부여한 권한(전체 디스크 접근 / "다른 앱의 데이터에 접근")이 무효화되고,
#     다음 실행에서 권한 프롬프트가 뜬다. 아무도 수락하지 않으면 프로세스가 블록되거나
#     카톡 DB를 못 읽어 **조용히 "메시지 0건"** 을 반환한다.
#   실제로 2026-07-10 재빌드 직후부터 6일간 PerfectDesk 카톡 수집이 에러 한 줄 없이 멈췄고,
#   사람이 사무실에서 프롬프트를 수락하고서야 재개됐다.
#   → 안정적 자체서명 인증서로 서명하면 **코드 신원이 유지**되어 권한이 재빌드에도 살아남는다.
#
# 사전 준비(최초 1회): 키체인 접근 > 인증서 지원 > 인증서 생성
#   이름=kakaocli-signing / 신원 유형=자체 서명 루트 / 인증서 유형=코드 서명
#
# 사용:  bash install.sh            (기본 identity: kakaocli-signing)
#        KAKAOCLI_SIGN_IDENTITY=... bash install.sh
set -euo pipefail

IDENTITY="${KAKAOCLI_SIGN_IDENTITY:-kakaocli-signing}"
DEST="${KAKAOCLI_DEST:-$HOME/.local/bin/kakaocli}"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sqlcipher 는 Package.swift 가 pkgConfig 로 찾는다. pkg-config 바이너리가 없어도 SwiftPM 이
# .pc 를 직접 읽지만, **경로를 알려줘야** 한다. 영맥처럼 pkg-config 미설치 환경에서는
# 이게 없으면 "library 'sqlcipher' not found" 로 링크가 깨진다(2026-10-31 실측).
for d in /opt/homebrew/opt/sqlcipher/lib/pkgconfig /usr/local/opt/sqlcipher/lib/pkgconfig; do
  [ -f "$d/sqlcipher.pc" ] && export PKG_CONFIG_PATH="$d:${PKG_CONFIG_PATH:-}" && break
done

echo "[1/3] 빌드 (swift build -c release)"
swift build -c release
BIN=".build/release/kakaocli"
[ -x "$BIN" ] || { echo "✗ 빌드 산출물 없음: $BIN"; exit 1; }

echo "[2/3] 코드서명 — identity: $IDENTITY"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$BIN"
  codesign -dv "$BIN" 2>&1 | grep -E "Signature|Authority" | sed 's/^/    /' || true
  echo "    ✓ 안정 서명 완료 — 재빌드해도 권한 유지됨"
else
  echo "    ⚠️  '$IDENTITY' 인증서를 찾을 수 없습니다 → ad-hoc 서명으로 설치됩니다."
  echo "       재빌드마다 TCC 권한이 깨져 카톡 수집이 '조용히' 멈출 수 있습니다."
  echo "       키체인 접근 > 인증서 지원 > 인증서 생성:"
  echo "         이름=$IDENTITY / 신원 유형=자체 서명 루트 / 인증서 유형=코드 서명"
fi

echo "[3/3] 설치 → $DEST"
mkdir -p "$(dirname "$DEST")"
install -m 0755 "$BIN" "$DEST"
echo "    버전: $("$DEST" --version 2>/dev/null || echo '?')"

cat <<'EOF'

※ 서명 신원이 처음 바뀐 직후 첫 실행에는 macOS 권한 프롬프트가 한 번 뜹니다 — 수락하세요.
   (전체 디스크 접근 / "다른 앱의 데이터에 접근") 같은 인증서로 재빌드하는 한 다시 묻지 않습니다.
EOF
