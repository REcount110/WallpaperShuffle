#!/bin/bash

#*********************************************************************************************************
# Photography wallpaper random switch script, a tool for photography enthusiasts to study excellent works.
# This script randomly selects an image from the specified folder as the desktop wallpaper,
# waits for a specified number of minutes after each switch,
# and deletes each image after it has been displayed 5 times.
# Recursively searches subfolders for images.
# Supported image formats: jpg, jpeg, png, gif, tga (case-insensitive).
# Requires: gsettings, find, shuf, awk, grep, readlink.
# Designed for GNOME desktop environment.
# Author: Rackell
# Date: 2024-06-27
#********************************************************************************************************


# Default interval time (minutes)
INTERVAL=1
# Primary image folder
FOLDER="/home/rackell/myWallPaper/"

# Fallback system folders (first one with images will be used)
FALLBACK_DIRS=(/usr/share/backgrounds /usr/share/pixmaps)
# Local count file (stores: "<full path> <count>"; path may contain spaces; count is last field)
COUNT_FILE="$HOME/myShell/.wallpaper_shuffle_count.txt"
LOCK_FILE="${COUNT_FILE}.lock"

# Exponential backoff settings for locked screen (in seconds)
LOCK_SLEEP_INITIAL=10      # initial wait
LOCK_SLEEP_MAX=600         # maximum wait (10 minutes)
LOCK_SLEEP_CURRENT=$LOCK_SLEEP_INITIAL

# Sanity checks
if ! command -v gsettings >/dev/null 2>&1; then
    echo "gsettings not found. This script requires GNOME settings (org.gnome.desktop.background)." >&2
    exit 1
fi

has_images() {
    local d="$1"
    [ -d "$d" ] || return 1
    find "$d" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) -print -quit | grep -q .
}

pick_fallback_dir() {
    local d
    for d in "${FALLBACK_DIRS[@]}"; do
        if has_images "$d"; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# Wait 4 seconds before starting to ensure the desktop environment is loaded
sleep 4
# Decide initial working directory and deletion policy
ALLOW_DELETE=true
if cd "$FOLDER" 2>/dev/null; then
    if ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            echo "No images in $FOLDER, falling back to system: $fb (no deletion)"
            cd "$fb" || { echo "Cannot enter $fb"; exit 1; }
            ALLOW_DELETE=false
        else
            echo "No photo files found in $FOLDER and no system backgrounds available."
            exit 0
        fi
    fi
else
    fb="$(pick_fallback_dir || true)"
    if [ -n "$fb" ]; then
        echo "Cannot enter $FOLDER, using system: $fb (no deletion)"
        cd "$fb" || { echo "Cannot enter $fb"; exit 1; }
        ALLOW_DELETE=false
    else
        echo "Cannot enter $FOLDER and no system backgrounds available."
        exit 1
    fi
fi

if [[ $@ == *wait* ]]; then  
    sleep "${INTERVAL}m"
fi


mkdir -p "$(dirname "$COUNT_FILE")"
touch "$COUNT_FILE"
# Acquire exclusive lock for the whole runtime to avoid concurrent corruption
exec 200>"$LOCK_FILE" || { echo "Cannot open lock file $LOCK_FILE" >&2; exit 1; }
if ! flock -n 200; then
    echo "Another instance is running (lock: $LOCK_FILE). Exiting." >&2
    exit 0
fi

cleanup_and_exit() {
    [ -f "$COUNT_FILE.tmp" ] && rm -f "$COUNT_FILE.tmp"
    # Release lock (fd 200 will close on exit). Optionally remove lock file.
    # rm -f "$LOCK_FILE"  # uncomment if you prefer deleting the lock file each run
    echo "Wallpaper shuffle script exited."
    exit 0
}
trap cleanup_and_exit EXIT TERM

ERRORCOUNT=0

is_screen_locked() {
    # check GNOME status of lock
    loginctl show-session $(loginctl | awk '/tty/ {print $1; exit}') -p Locked | grep -q 'yes'
}

# --- Count helper functions supporting paths with spaces ---
get_photo_count() {
    local photo="$1"
    awk -v f="$photo" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p==f){print c; exit}
        }
    ' "$COUNT_FILE"
}

update_photo_count() {
    local photo="$1" newcount="$2"
    awk -v f="$photo" -v nc="$newcount" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p!=f) print p" "c;
        }
        END { print f" "nc }
    ' "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
}

remove_photo_entry() {
    local photo="$1"
    awk -v f="$photo" '
        {
            c=$NF; $NF=""; sub(/[ \t]+$/,"",$0); p=$0;
            if(p!=f) print p" "c;
        }
    ' "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
}

while true; do
    # If we are using fallback but primary now has images, switch back (and allow deletion)
    if [ "$ALLOW_DELETE" = false ] && has_images "$FOLDER"; then
        echo "Primary folder now has images, switching back to $FOLDER"
        cd "$FOLDER" || true
        ALLOW_DELETE=true
    fi

    # If we are on primary and it became empty, switch to fallback (no deletion)
    if [ "$ALLOW_DELETE" = true ] && ! has_images "$FOLDER"; then
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            echo "Primary folder empty, switching to system: $fb (no deletion)"
            cd "$fb" || true
            ALLOW_DELETE=false
        fi
    fi

    # Recursively find all image files and shuffle the order (case-insensitive)
    mapfile -t FILES < <(find . -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.tga' \) | shuf)
    
    if [ "${#FILES[@]}" -eq 0 ]; then
        echo "No photo files found in current directory $(pwd)"
        # If nothing here, try switching to any available fallback or exit
        fb="$(pick_fallback_dir || true)"
        if [ -n "$fb" ]; then
            echo "Trying fallback: $fb (no deletion)"
            cd "$fb" || true
            ALLOW_DELETE=false
            continue
        fi
        exit 0
    fi

    for photo in "${FILES[@]}"; do  
        # Exponential backoff while locked: skip change & counting
        if is_screen_locked; then
            echo "[info] $(date '+%F %T') - Screen locked, waiting ${LOCK_SLEEP_CURRENT}s (exp backoff)."
            sleep "$LOCK_SLEEP_CURRENT"
            # Increase wait time up to max
            if [ "$LOCK_SLEEP_CURRENT" -lt "$LOCK_SLEEP_MAX" ]; then
                LOCK_SLEEP_CURRENT=$(( LOCK_SLEEP_CURRENT * 2 ))
                [ "$LOCK_SLEEP_CURRENT" -gt "$LOCK_SLEEP_MAX" ] && LOCK_SLEEP_CURRENT=$LOCK_SLEEP_MAX
            fi
            continue
        else
            # Reset backoff after unlock
            [ "$LOCK_SLEEP_CURRENT" -ne "$LOCK_SLEEP_INITIAL" ] && LOCK_SLEEP_CURRENT=$LOCK_SLEEP_INITIAL
        fi
    photo=$(readlink -f "$photo")  
    count=$(get_photo_count "$photo")
    [ -z "$count" ] && count=0

        # Try to set wallpaper. Only on SUCCESS do we increment display count.
        if gsettings set org.gnome.desktop.background picture-uri "file://$photo"; then
            ERRORCOUNT=0
            # Optional: set dark variant if supported (ignore errors)
            if gsettings writable org.gnome.desktop.background picture-uri-dark >/dev/null 2>&1; then
                gsettings set org.gnome.desktop.background picture-uri-dark "file://$photo" || true
            fi
            # Ensure GNOME scales the wallpaper (ignore errors if unsupported)
            gsettings set org.gnome.desktop.background picture-options "scaled" >/dev/null 2>&1 || true
            newcount=$((count+1))
            update_photo_count "$photo" "$newcount"
            echo "[info] $(date '+%F %T') - set wallpaper: $photo (count=$newcount mode=$([ "$ALLOW_DELETE" = true ] && echo primary || echo fallback))"
            # Delete image and count after 3 successful displays (only for primary folder)
            if [ "$newcount" -ge 3 ] && [ "$ALLOW_DELETE" = true ]; then
                rm -f "$photo"
                remove_photo_entry "$photo"
                if [[ "$photo" == "$FOLDER"* ]]; then
                    find "$FOLDER" -type d -empty -delete
                fi
                continue
            fi
        else
            ((ERRORCOUNT++))
            echo "[warn] gsettings failed to set picture-uri for: $photo (no count increment)" >&2
            if [ $((ERRORCOUNT * INTERVAL)) -gt 20 ]; then
                cleanup_and_exit
            fi
        fi

        # Wait for the specified number of minutes before switching to the next image
        sleep "${INTERVAL}m"
    done
done