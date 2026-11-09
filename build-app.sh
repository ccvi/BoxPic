#!/usr/bin/env bash
#
# ============================================================
# BoxPic 打包脚本
#
# 产出 dist/BoxPic.app —— 可双击、可拖进 /Applications 的原生应用。
#
# 用法：
#   ./build-app.sh                发布构建（release，带图标，证书签名）
#   ./build-app.sh --debug        调试构建
#   ./build-app.sh --no-sign      跳过签名
#   ./build-app.sh --no-sandbox   让 swift build 跳过 SwiftPM 自带的沙箱
#   ./build-app.sh --install      构建完装到 /Applications
#   ./build-app.sh --bump         强制版本号 +1（即使源码没变）
#   ./build-app.sh --no-bump      保持版本号不变（指纹照常更新）
#   ./build-app.sh --clean        先清掉 .build 再构建
#
# 版本号：唯一来源是工程根目录的 VERSION 文件（一行，形如 1.0.0）。
#   源码指纹有变 → 补丁位 +1（1.0.0 → 1.0.1）；首次打包不递增。
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="release"
DO_SIGN=1
DO_INSTALL=0
FORCE_BUMP=0
SKIP_BUMP=0
DO_CLEAN=0
SWIFT_FLAGS=()

for argument in "$@"; do
    case "$argument" in
        --debug)      CONFIGURATION="debug" ;;
        --no-sign)    DO_SIGN=0 ;;
        --no-sandbox) SWIFT_FLAGS+=(--disable-sandbox) ;;
        --install)    DO_INSTALL=1 ;;
        --bump)       FORCE_BUMP=1 ;;
        --no-bump)    SKIP_BUMP=1 ;;
        --clean)      DO_CLEAN=1 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${argument}（用 --help 查看用法）" >&2
            exit 1
            ;;
    esac
done

APP_NAME="BoxPic"
DISPLAY_NAME="BoxPic"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# ------------------------------------------------------------
# 0. 版本号
# ------------------------------------------------------------

VERSION_FILE="$PROJECT_ROOT/VERSION"
FINGERPRINT_FILE="$PROJECT_ROOT/VERSION.fingerprint"

SOURCE_INPUTS=(Package.swift build-app.sh Sources Resources)

# 删目录。沙箱环境里裸 rm -rf 会把旧产物丢进废纸篓并重命名（BoxPic.app 13-20-25.app），
# 一路堆下去既占地又会让 LaunchServices 记一堆幽灵副本 —— 所以统一走 find -delete。
delete_tree() {
    [[ -e "$1" ]] || return 0
    find "$1" -depth -delete >/dev/null 2>&1 || rm -rf "$1"
}

read_version_file() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "错误：缺少 VERSION 文件（应包含一行形如 1.0.0 的版本号）" >&2
        exit 1
    fi
    local value
    value="$(tr -d '[:space:]' < "$VERSION_FILE")"
    if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：VERSION 内容不合法：「${value}」。要求形如 1.0.0（三段数字）。" >&2
        exit 1
    fi
    printf '%s' "$value"
}

bump_patch_version() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

build_number_of() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s' "$((major * 10000 + minor * 100 + patch))"
}

compute_source_fingerprint() {
    local records=()
    local path entry digest
    for path in ${SOURCE_INPUTS[@]+"${SOURCE_INPUTS[@]}"}; do
        [[ -e "$PROJECT_ROOT/$path" ]] || continue
        if [[ -d "$PROJECT_ROOT/$path" ]]; then
            while IFS= read -r -d '' entry; do
                digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
                records+=("${entry#$PROJECT_ROOT/}:$digest")
            done < <(find "$PROJECT_ROOT/$path" -type f ! -name '.DS_Store' -print0)
        else
            digest="$(shasum -a 256 "$PROJECT_ROOT/$path" | awk '{print $1}')"
            records+=("${path}:$digest")
        fi
    done
    printf '%s\0' ${records[@]+"${records[@]}"} \
        | LC_ALL=C sort -z \
        | shasum -a 256 | awk '{print $1}'
}

CURRENT_VERSION="$(read_version_file)"
CURRENT_FINGERPRINT="$(compute_source_fingerprint)"

STORED_FINGERPRINT=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
    STORED_FINGERPRINT="$(tr -d '[:space:]' < "$FINGERPRINT_FILE")"
fi

if [[ "$FORCE_BUMP" == "1" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="--bump 强制递增"
elif [[ ! -f "$FINGERPRINT_FILE" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="首次打包，沿用 VERSION 里的初版号"
elif [[ "$SKIP_BUMP" == "1" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="--no-bump 保持版本号"
elif [[ "$CURRENT_FINGERPRINT" != "$STORED_FINGERPRINT" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="源码有改动"
else
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="源码未变，沿用当前版本"
fi
APP_BUILD_NUMBER="$(build_number_of "$APP_VERSION")"

echo "${DISPLAY_NAME} 打包（${APP_NAME}）"
echo "────────────────────────────────────────────────────"
echo "  版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）· ${VERSION_REASON}"
echo "  构建配置：${CONFIGURATION}"
echo "  输出位置：${APP_DIR}"
echo ""

# ------------------------------------------------------------
# 1. 编译主程序
# ------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
    echo "▶ 清理 .build…"
    delete_tree "$PROJECT_ROOT/.build"
fi

echo "▶ 编译主程序（${CONFIGURATION}）…"
swift build -c "$CONFIGURATION" --product "$APP_NAME" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：没有找到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi
echo "  ✓ 可执行文件：${BIN_PATH}"

# ------------------------------------------------------------
# 2. 自检
#
# 🔴 铁律：自检**只能**跑 .build 下的裸产物，绝不 exec .app 内的二进制
#    （macOS 26 上那样做会让 bundle 的 LaunchServices 登记永久失效）。
# ------------------------------------------------------------
echo "▶ 核心自检…"
if "$BIN_PATH" --selftest > /tmp/boxpic-selftest.log 2>&1; then
    grep -E '^✓' /tmp/boxpic-selftest.log | sed 's/^/  /' || true
else
    echo "  ✗ 自检未通过，停止打包。完整输出：/tmp/boxpic-selftest.log" >&2
    tail -20 /tmp/boxpic-selftest.log | sed 's/^/    /' >&2
    exit 1
fi

# ------------------------------------------------------------
# 4. 图标
# ------------------------------------------------------------
echo "▶ 生成图标…"
ICON_TMP="$(mktemp -d)"
ICONSET_DIR="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
ICON_OK=1
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"; name="${spec##* }"
    sips -s format png -z "$size" "$size" "$PROJECT_ROOT/Resources/icon-master.png" \
        --out "$ICONSET_DIR/${name}.png" > /dev/null 2>&1 || ICON_OK=0
done
if [[ "$ICON_OK" == "1" ]] && iconutil -c icns "$ICONSET_DIR" -o "$ICON_TMP/AppIcon.icns" 2>/dev/null; then
    ICON_READY=1
else
    ICON_READY=0
fi

# ------------------------------------------------------------
# 5. 组装 bundle
# ------------------------------------------------------------
echo "▶ 组装应用包…"
delete_tree "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
printf 'APPL????' > "$CONTENTS/PkgInfo"

render_plist() {
    sed -e "s/__BOXPIC_VERSION__/$APP_VERSION/g" \
        -e "s/__BOXPIC_BUILD__/$APP_BUILD_NUMBER/g" "$1" > "$2"
}
render_plist "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

if grep -q '__BOXPIC_' "$CONTENTS/Info.plist"; then
    echo "错误：Info.plist 里仍有未替换的占位符，版本注入不完整。" >&2
    exit 1
fi
plutil -lint "$CONTENTS/Info.plist" > /dev/null
echo "  ✓ Info.plist（版本 ${APP_VERSION} · 构建 ${APP_BUILD_NUMBER}）"

if [[ "$ICON_READY" == "1" ]]; then
    cp "$ICON_TMP/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "  ✓ AppIcon.icns"
else
    echo "  ⚠ 图标生成失败，使用系统默认图标（不影响功能）"
fi
rm -rf "$ICON_TMP"

# 许可证（内置 libwebp 必须随包携带）
if [[ -f "$PROJECT_ROOT/Sources/CLibWebP/COPYING" ]]; then
    cp "$PROJECT_ROOT/Sources/CLibWebP/COPYING" "$RESOURCES_DIR/libwebp-COPYING.txt"
fi

xattr -cr "$APP_DIR" 2>/dev/null || true

SIGNING_IDENTITY_NAME="FastFind Local Signing"

detect_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "$SIGNING_IDENTITY_NAME" | head -1 | awk '{print $2}'
}

SIGNING_IDENTITY=""
if [[ "$DO_SIGN" == "1" ]]; then
    SIGNING_IDENTITY="$(detect_signing_identity || true)"
fi

# ------------------------------------------------------------
# 5.5 内置 cjxl（JPEG XL 编码器）
#
# macOS 的 ImageIO 只能解 JXL、不能写，输出必须靠 cjxl（brew install jpeg-xl）。
# 为了让别人拿到 dmg 就能直接出 JXL，把 cjxl 和它的非系统依赖一起塞进包里，
# 并把加载路径改写成 @executable_path / @loader_path —— 装完不再依赖 Homebrew。
# ------------------------------------------------------------
echo "▶ 内置 cjxl（JPEG XL 编码器）…"

FRAMEWORKS_DIR="$CONTENTS/Frameworks"

JXL_SRC=""
if command -v cjxl > /dev/null 2>&1; then
    JXL_SRC="$(command -v cjxl)"
else
    for cand in /opt/homebrew/bin/cjxl /usr/local/bin/cjxl /opt/local/bin/cjxl; do
        if [[ -x "$cand" ]]; then JXL_SRC="$cand"; break; fi
    done
fi

rpaths_of() {
    otool -l "$1" 2>/dev/null | awk '/cmd LC_RPATH/ { getline; getline; print $2 }'
}

# @rpath/xxx 顺着 LC_RPATH 解析成真实文件；系统库一律不跟
resolve_dep() {
    local owner="$1" dep="$2" base cand rp
    case "$dep" in
        @rpath/*)
            base="${dep#@rpath/}"
            while IFS= read -r rp; do
                [[ -z "$rp" ]] && continue
                rp="${rp//@loader_path/$(dirname "$owner")}"
                rp="${rp//@executable_path/$(dirname "$owner")}"
                cand="$rp/$base"
                if [[ -f "$cand" ]]; then printf '%s\n' "$cand"; return 0; fi
            done < <(rpaths_of "$owner")
            ;;
        /*)
            if [[ -f "$dep" ]]; then printf '%s\n' "$dep"; return 0; fi
            ;;
    esac
    return 1
}

JXL_FILES=()
JXL_SEEN=" "

# 递归收集非系统依赖（按 basename 去重；macOS 自带 bash 3.2 没有关联数组）
collect_jxl_deps() {
    local f="$1" dep real key
    key="$(basename "$f")"
    case "$JXL_SEEN" in *" ${key} "*) return 0 ;; esac
    case "$f" in
        /usr/lib/*|/System/*) return 0 ;;
    esac
    JXL_SEEN="${JXL_SEEN}${key} "
    JXL_FILES+=("$f")
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
        esac
        if real="$(resolve_dep "$f" "$dep")"; then
            collect_jxl_deps "$real"
        fi
    done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

if [[ -z "$JXL_SRC" ]]; then
    echo "  ⚠ 没找到 cjxl，本次不内置（JXL 输出会退回系统 PATH，缺就提示用户安装）"
    echo "    装一下再打包：brew install jpeg-xl"
else
    collect_jxl_deps "$JXL_SRC"
    mkdir -p "$FRAMEWORKS_DIR"
    cp "$JXL_SRC" "$MACOS_DIR/cjxl"
    chmod +x "$MACOS_DIR/cjxl"

    for f in "${JXL_FILES[@]}"; do
        [[ "$f" == "$JXL_SRC" ]] && continue
        cp "$f" "$FRAMEWORKS_DIR/$(basename "$f")"
        chmod u+w "$FRAMEWORKS_DIR/$(basename "$f")"
    done

    # cjxl：依赖改成 @executable_path/../Frameworks/xxx
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        base="$(basename "$dep")"
        if [[ -f "$FRAMEWORKS_DIR/$base" ]]; then
            install_name_tool -change "$dep" "@executable_path/../Frameworks/$base" \
                "$MACOS_DIR/cjxl" 2>/dev/null || true
        fi
    done < <(otool -L "$MACOS_DIR/cjxl" 2>/dev/null | tail -n +2 | awk '{print $1}')

    # 各 dylib：id 改成 @rpath/xxx，互相之间用 @loader_path/xxx
    for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue
        base="$(basename "$dylib")"
        install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            depbase="$(basename "$dep")"
            [[ "$depbase" == "$base" ]] && continue
            if [[ -f "$FRAMEWORKS_DIR/$depbase" ]]; then
                install_name_tool -change "$dep" "@loader_path/$depbase" "$dylib" 2>/dev/null || true
            fi
        done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done

    # 包内不许再指向 Homebrew：残留的 LC_RPATH 直接删掉
    for macho in "$MACOS_DIR/cjxl" "$FRAMEWORKS_DIR"/*.dylib; do
        [[ -f "$macho" ]] || continue
        while IFS= read -r rp; do
            [[ -z "$rp" ]] && continue
            case "$rp" in
                /opt/homebrew*|/usr/local*|@loader_path/../../../*)
                    install_name_tool -delete_rpath "$rp" "$macho" 2>/dev/null || true
                    ;;
            esac
        done < <(rpaths_of "$macho")
    done

    # 许可证随包携带（libjxl 及依赖都是 BSD / Apache / MIT）
    JXL_LICENSE=""
    for cand in /opt/homebrew/opt/jpeg-xl/LICENSE /usr/local/opt/jpeg-xl/LICENSE; do
        if [[ -f "$cand" ]]; then JXL_LICENSE="$cand"; break; fi
    done
    {
        echo "BoxPic 内置的 JPEG XL 编码器来自 libjxl (https://github.com/libjxl/libjxl)"
        echo "及其依赖，均为 BSD / Apache-2.0 / MIT 许可，可自由分发。"
        echo ""
        echo "随包文件："
        printf '  %s\n' "$(basename "$JXL_SRC")" "${JXL_FILES[@]##*/}"
    } > "$RESOURCES_DIR/jpeg-xl-NOTICE.txt"
    if [[ -n "$JXL_LICENSE" ]]; then
        cp "$JXL_LICENSE" "$RESOURCES_DIR/jpeg-xl-LICENSE.txt"
    fi

    echo "  ✓ cjxl + ${#JXL_FILES[@]} 个依赖（$(du -sh "$FRAMEWORKS_DIR" | awk '{print $1}')）"

    # 🔴 改过加载命令的 arm64 二进制必须先重签，否则一执行就被系统杀掉（Killed: 9）
    NESTED_SIGN="${SIGNING_IDENTITY:--}"
    for nested in "$FRAMEWORKS_DIR"/*.dylib "$MACOS_DIR/cjxl"; do
        [[ -f "$nested" ]] || continue
        codesign --force --sign "$NESTED_SIGN" --timestamp=none "$nested" > /dev/null 2>&1 || true
    done

    # 立刻验一次：只留系统路径也能跑，说明真的自包含了
    if env -i PATH=/usr/bin:/bin "$MACOS_DIR/cjxl" --version > /dev/null 2>&1; then
        echo "  ✓ 自包含验证通过（脱离 Homebrew 也能执行）"
    else
        echo "  ⚠ 内置的 cjxl 跑不起来，检查 dylib 路径改写" >&2
    fi
fi

xattr -cr "$APP_DIR" 2>/dev/null || true

# ------------------------------------------------------------
# 6. 签名
#
# 🔴 铁律：优先用固定的本机自签名身份，找不到才退回 ad-hoc。
#    系统记 TCC 授权时存的是**指定要求**：ad-hoc 只能钉 cdhash，重编一次就失效。
# ------------------------------------------------------------
if [[ "$DO_SIGN" == "1" ]]; then
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        echo "▶ 代码签名（${SIGNING_IDENTITY_NAME}）…"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || true
    else
        echo "▶ 代码签名（ad-hoc）…"
        echo "  ⚠ 没找到「${SIGNING_IDENTITY_NAME}」身份，本次退回临时签名。"
        echo "    临时签名会让扩展注册 / 授权在每次更新后失效；"
        echo "    跑一次 Tools/setup-signing-identity.sh 即可建立固定身份（不需要 sudo）。"
        codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || true
    fi
    if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
        echo "  ✓ 签名校验通过"
    else
        echo "  ⚠ 签名校验未通过（改用 --no-sign 可跳过这一步）" >&2
    fi

    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "$DESIGNATED_REQUIREMENT" ]]; then
        echo "  · 指定要求：${DESIGNATED_REQUIREMENT}"
        case "$DESIGNATED_REQUIREMENT" in
            cdhash*)
                echo "    ⚠ 这是临时签名的形态（钉死二进制哈希），更新一次就要重授一次。" >&2
                ;;
        esac
    fi
else
    echo "▶ 已跳过签名（--no-sign）"
fi

# ------------------------------------------------------------
# 7. 版本号落盘（放最后：中途失败不该吃掉一个版本号）
# ------------------------------------------------------------
printf '%s\n' "$APP_VERSION" > "$VERSION_FILE"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

README_FILE="$PROJECT_ROOT/README.md"
if [[ -f "$README_FILE" ]]; then
    python3 - "$README_FILE" "$APP_VERSION" <<'PYEOF'
import re, sys
path, version = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
pattern = r"(当前版本：\*\*)[0-9]+\.[0-9]+\.[0-9]+(\*\*)"
new = re.sub(pattern, r"\g<1>" + version + r"\g<2>", text, count=1)
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print(f"  ✓ README「当前版本」已同步为 {version}")
elif re.search("当前版本：\\*\\*" + re.escape(version) + "\\*\\*", text):
    print(f"  ✓ README「当前版本」已是 {version}，不用改")
PYEOF
fi

# ------------------------------------------------------------
# 7.5 制作 dmg 安装包
#
# 🔴 顺序：先签好 app，再打 dmg。反过来的话要么挂载进去重签（cdhash 一变授权就废），
#    要么 dmg 里躺着一个没签的 app。
# 里面只放两样东西：app + 指向 /Applications 的软链接（拖进去就装好，mac 用户的肌肉记忆）。
# ------------------------------------------------------------
DMG_PATH="$DIST_DIR/${APP_NAME}-${APP_VERSION}.dmg"
DMG_STAGE="$DIST_DIR/.dmg-stage"
DIST_CDHASH="${DIST_CDHASH:-$(codesign -dvvv "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')}"
delete_tree "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_DIR" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

echo ""
echo "▶ 制作 dmg…"
rm -f "$DMG_PATH"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO -quiet "$DMG_PATH" >/dev/null
delete_tree "$DMG_STAGE"

# 挂起来核对一遍：dmg 里那份必须和 dist 里验证过的是同一个签名，
# 否则「安装包里的东西」和「我验过的东西」就不是一份了
DMG_MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>/dev/null \
    | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "${DMG_MOUNT}" ]]; then
    echo "  ✗ dmg 挂载失败：${DMG_PATH}" >&2
    exit 1
fi
DMG_CDHASH="$(codesign -dvvv "$DMG_MOUNT/$APP_NAME.app" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
hdiutil detach -quiet "$DMG_MOUNT" >/dev/null 2>&1 || true
if [[ -z "$DMG_CDHASH" || "$DMG_CDHASH" != "$DIST_CDHASH" ]]; then
    echo "  ✗ dmg 内的 app 与 dist 不一致（dmg=${DMG_CDHASH:-?} / dist=${DIST_CDHASH:-?}）" >&2
    exit 1
fi
echo "  ✓ dmg：${DMG_PATH}（$(du -h "$DMG_PATH" | awk '{print $1}')，内嵌 cdhash ${DMG_CDHASH}）"

# ------------------------------------------------------------
# 8. 完成
# ------------------------------------------------------------
echo ""
echo "────────────────────────────────────────────────────"
echo "打包完成：${APP_DIR}"
echo "版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）"
echo ""
du -sh "$APP_DIR" | sed 's/^/  体积 /'

if [[ "$DO_INSTALL" == "1" ]]; then
    echo ""
    echo "▶ 安装到 /Applications…"
    INSTALLED_APP="/Applications/$APP_NAME.app"
    DIST_CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    delete_tree "$INSTALLED_APP"

    # 🔴 ditto 复制，复制后绝不重新签名 —— 重签会把证书覆盖成临时签名，
    #    cdhash 一变，TCC 授权当场作废（「装完看着正常，功能全不触发」就是这么来的）。
    ditto "$APP_DIR" "$INSTALLED_APP"
    xattr -cr "$INSTALLED_APP" 2>/dev/null || true

    if ! codesign --verify --deep --strict "$INSTALLED_APP" 2>/dev/null; then
        echo "  ✗ 安装副本签名校验失败：${INSTALLED_APP}" >&2
        exit 1
    fi

    INSTALLED_CDHASH="$(codesign -dvvv "$INSTALLED_APP" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    if [[ -z "$DIST_CDHASH" || "$DIST_CDHASH" != "$INSTALLED_CDHASH" ]]; then
        echo "  ✗ cdhash 不一致：dist=${DIST_CDHASH:-?} / 安装=${INSTALLED_CDHASH:-?}" >&2
        echo "    说明安装过程改动了签名封存，此前的授权会失效。" >&2
        exit 1
    fi
    echo "  ✓ 已安装：${INSTALLED_APP}（cdhash ${INSTALLED_CDHASH}）"

    # 刷新服务菜单缓存，右键里的「在 BoxPic 中打开」立刻可用
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
fi

cat <<'TIPS'

首次使用
────────────────────────────────────────────────────
1) 启动
     双击 dist/BoxPic.app。拖图片进窗口，或在「文件 → 添加图片」选。
     从别人机器拷来的副本第一次打开请右键 → 打开。

2) 右键菜单
     图片上右键 → 菜单底部「在 BoxPic 中打开」（NSServices，装完即用，不需要授权）。
     若没出现：把应用启动一次（首次启动才会注册服务），或执行
     /System/Library/CoreServices/pbs -update 刷新缓存。

3) 自检 / 诊断
     ⚠️ 不要直接执行 .app 里的二进制（Contents/MacOS/BoxPic）！
     用 .build 下的裸产物：
        .build/release/BoxPic --selftest
TIPS
