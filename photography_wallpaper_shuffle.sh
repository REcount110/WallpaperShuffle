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
# Local count file
COUNT_FILE="$HOME/myShell/.wallpaper_shuffle_count.txt"

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

cleanup_and_exit() {
    [ -f "$COUNT_FILE.tmp" ] && rm -f "$COUNT_FILE.tmp"
    echo "Wallpaper shuffle script exited."
    exit 0
}
trap cleanup_and_exit EXIT TERM

ERRORCOUNT=0

is_screen_locked() {
    # check GNOME status of lock
    loginctl show-session $(loginctl | awk '/tty/ {print $1; exit}') -p Locked | grep -q 'yes'
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
        # Check lock status, skip change and count if locked
        if is_screen_locked; then
            echo "[info] $(date '+%F %T') - Screen is locked, skipping wallpaper change."
            sleep 10
            continue
        fi
        photo=$(readlink -f "$photo")  
        count=$(awk -v f="$photo" '$1==f{print $2}' "$COUNT_FILE")
        [ -z "$count" ] && count=0

        # Try to set wallpaper. Always set picture-uri; picture-uri-dark is optional.
        if gsettings set org.gnome.desktop.background picture-uri "file://$photo"; then
            ERRORCOUNT=0
            # Optional: set dark variant if supported (ignore errors)
            if gsettings writable org.gnome.desktop.background picture-uri-dark >/dev/null 2>&1; then
                gsettings set org.gnome.desktop.background picture-uri-dark "file://$photo" || true
            fi
            # Ensure GNOME scales the wallpaper (ignore errors if unsupported)
            gsettings set org.gnome.desktop.background picture-options "scaled" >/dev/null 2>&1 || true
            echo "[info] $(date '+%F %T') - set wallpaper: $photo (mode=$([ "$ALLOW_DELETE" = true ] && echo primary || echo fallback))"
            # Increment display count
            newcount=$((count+1))
            grep -vF "$photo" "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
            echo "$photo $newcount" >> "$COUNT_FILE"
            # Delete image and count after 5 displays (only for primary folder)
            if [ "$newcount" -ge 5 ] && [ "$ALLOW_DELETE" = true ]; then
                rm -f "$photo"
                grep -vF "$photo" "$COUNT_FILE" > "$COUNT_FILE.tmp" && mv "$COUNT_FILE.tmp" "$COUNT_FILE"
                # Delete empty folders only under the primary(myWallPaper) folder
                if [[ "$photo" == "$FOLDER"* ]]; then
                    find "$FOLDER" -type d -empty -delete
                fi
                continue
            fi
        else
            ((ERRORCOUNT++))
            echo "Failed to set wallpaper: $photo" >> "$COUNT_FILE"
            echo "[warn] gsettings failed to set picture-uri for: $photo" >&2
            if [ $((ERRORCOUNT * INTERVAL)) -gt 20 ]; then
                cleanup_and_exit
            fi
        fi

        # Wait for the specified number of minutes before switching to the next image
        sleep "${INTERVAL}m"
    done
done