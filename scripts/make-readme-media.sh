#!/bin/bash
# 生成 README 用的截图和动图，放到 docs/images/。用 --demo 的假输入框当舞台，不读输入框、不请求模型。
# 录屏期间舞台会出现在主屏左上角（约 960×290），别把别的窗口拖到那里。需要终端有「屏幕录制」权限，以及 ffmpeg、ImageMagick。
#   ./scripts/make-readme-media.sh            全部重做
#   ./scripts/make-readme-media.sh hero zh    只录中文版主演示
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/dist/Gloss.app/Contents/MacOS/Gloss"
OUT_DIR="$PROJECT_DIR/docs/images"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gloss-media.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"
SCALE="$(python3 -c 'import AppKit; print(int(AppKit.NSScreen.screens()[0].backingScaleFactor()))')"

# 启动一个场景，等它在标准输出报出舞台位置；结果放进 STAGE_* 变量和 DEMO_PID。
start_scene() {
    local scene=$1 lang=$2 extra=${3:-aurora}
    : > "$WORK/stage.txt"
    "$APP" --demo "$scene" "$extra" --lang "$lang" > "$WORK/stage.txt" &
    DEMO_PID=$!
    until grep -q STAGE "$WORK/stage.txt"; do sleep 0.05; done
    read -r _ STAGE_X STAGE_Y STAGE_W STAGE_H STAGE_LOOP < <(grep STAGE "$WORK/stage.txt")
}

still() {
    local scene=$1 lang=$2
    start_scene "$scene" "$lang"
    sleep 2
    screencapture -x -R"$STAGE_X,$STAGE_Y,$STAGE_W,$STAGE_H" "$OUT_DIR/$scene-$lang.png"
    kill "$DEMO_PID"
    printf 'wrote %s\n' "docs/images/$scene-$lang.png"
}

# 录整个主屏，录两轮多一点，再按舞台每轮开头报的开机秒数切出完整的第二轮（第一轮开头可能还没开始录）。
hero() {
    local lang=$1
    start_scene hero "$lang"
    local seconds
    seconds="$(python3 -c "print($STAGE_LOOP * 2 + 1.5)")"
    ffmpeg -hide_banner -loglevel info -f avfoundation -capture_cursor 0 -framerate 30 -i "Capture screen 0" \
        -t "$seconds" -c:v libx264 -preset ultrafast -crf 12 -y "$WORK/raw.mov" 2> "$WORK/ffmpeg.log"
    kill "$DEMO_PID"
    # avfoundation 的时间戳是开机以来的秒数，和舞台报的 systemUptime 同一个时钟。
    local capture_start loop_start loop_end offset duration
    capture_start="$(grep -m1 -o 'start: [0-9.]*' "$WORK/ffmpeg.log" | cut -d' ' -f2)"
    loop_start="$(grep LOOP "$WORK/stage.txt" | sed -n 2p | cut -d' ' -f2)"
    loop_end="$(grep LOOP "$WORK/stage.txt" | sed -n 3p | cut -d' ' -f2)"
    offset="$(python3 -c "print($loop_start - $capture_start)")"
    duration="$(python3 -c "print($loop_end - $loop_start)")"
    local crop="crop=$((STAGE_W * SCALE)):$((STAGE_H * SCALE)):$((STAGE_X * SCALE)):$((STAGE_Y * SCALE))"
    ffmpeg -hide_banner -loglevel error -ss "$offset" -t "$duration" -i "$WORK/raw.mov" \
        -vf "$crop,scale=1440:-2:flags=lanczos,format=yuv420p" -c:v libx264 -crf 20 -movflags +faststart -an -y "$OUT_DIR/hero-$lang.mp4"
    # GIF：1280 宽（Retina 屏上看着不糊）、15 帧，先算调色板再抖动，体积和观感折中。
    ffmpeg -hide_banner -loglevel error -i "$OUT_DIR/hero-$lang.mp4" \
        -vf "fps=15,scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
        -loop 0 -y "$OUT_DIR/hero-$lang.gif"
    printf 'wrote %s (%s)\n' "docs/images/hero-$lang.gif" "$(du -h "$OUT_DIR/hero-$lang.gif" | cut -f1)"
}

# 四种配色的等待状态并排，下面写上名字：单独截浮窗（带透明边），再铺到同样的渐变底上。
palettes() {
    local lang=$1 font="Helvetica-Neue" names=(Aurora Ocean Sunset Mono)
    if [[ $lang == zh ]]; then
        font="/System/Library/Fonts/Hiragino Sans GB.ttc"
        names=(极光 冷蓝 日落 单色)
    fi
    local files=() index=0
    for palette in aurora ocean sunset mono; do
        "$APP" --demo waiting "$palette" > /dev/null &
        local pid=$!
        sleep 1.6
        local window
        window="$(python3 "$PROJECT_DIR/scripts/window-id.py" "$pid" 10 | head -1 | cut -d' ' -f1)"
        screencapture -x -o -l "$window" "$WORK/$palette.png"
        kill "$pid"
        magick "$WORK/$palette.png" -background none -gravity center -extent 240x180 \
            -font "$font" -pointsize 26 -fill '#5B6170' -annotate +0+70 "${names[$index]}" "$WORK/$palette-label.png"
        files+=("$WORK/$palette-label.png")
        index=$((index + 1))
    done
    magick "${files[@]}" +append "$WORK/strip.png"
    magick -size "$(magick identify -format '%[fx:w+120]x%[fx:h+40]' "$WORK/strip.png")" \
        gradient:'#E8EDF7'-'#F5EDF2' "$WORK/strip.png" -gravity center -composite "$OUT_DIR/palettes-$lang.png"
    printf 'wrote %s\n' "docs/images/palettes-$lang.png"
}

# 设置窗口：单独截窗口，带系统阴影。
settings() {
    local tab=$1 lang=$2
    "$APP" --demo settings "$tab" --lang "$lang" > /dev/null &
    local pid=$!
    sleep 2
    local window
    window="$(python3 "$PROJECT_DIR/scripts/window-id.py" "$pid" 300 | head -1 | cut -d' ' -f1)"
    screencapture -x -l "$window" "$OUT_DIR/settings-$tab-$lang.png"
    kill "$pid"
    printf 'wrote %s\n' "docs/images/settings-$tab-$lang.png"
}

# 欢迎引导：毛玻璃要连后面垫的渐变一起截，按场景报的位置截一块区域。
welcome() {
    local step=$1 lang=$2
    start_scene welcome "$lang" "$step"
    sleep 2
    screencapture -x -R"$STAGE_X,$STAGE_Y,$STAGE_W,$STAGE_H" "$OUT_DIR/welcome-$step-$lang.png"
    kill "$DEMO_PID"
    printf 'wrote %s\n' "docs/images/welcome-$step-$lang.png"
}

if [[ $# -gt 0 ]]; then
    "$@"
    exit
fi
for lang in zh en; do
    hero "$lang"
    still toolbar "$lang"
    still polish "$lang"
    palettes "$lang"
    settings 0 "$lang"
    welcome 0 "$lang"
    welcome 3 "$lang"
done
