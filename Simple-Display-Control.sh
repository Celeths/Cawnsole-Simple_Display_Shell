#!/bin/bash

if ! command -v dialog &> /dev/null; then
    echo "Missing prerequisite 'dialog'." >&2
    exit 1
fi

MENU_OUT=$(mktemp)
trap 'rm -f "$MENU_OUT"' EXIT

# Snort the raw output and mathematically strip the ANSI color codes
KSCREEN_RAW=$(kscreen-doctor -o)
KSCREEN_DATA=$(echo "$KSCREEN_RAW" | sed -r 's/\x1B\[[0-9;]*[mK]//g')

mapfile -t menu_options < <(echo "$KSCREEN_DATA" | awk '/^Output:/ {
    id=$2
    $1=$2=""
    sub(/^[ \t]+/, "")
    print id
    print $0
}')

if [ ${#menu_options[@]} -eq 0 ]; then
    dialog --title "Error" --msgbox "No active video outputs detected." 6 50
    exit 1
fi

# Global associative matrices for state tracking
declare -A seen_fps
declare -A fps_map
declare -A fps_label_map
declare -A res_map
declare -A scale_map

# The semantic finite state machine
STATE="SELECT_OUTPUT"

while true; do
    case "$STATE" in
        "SELECT_OUTPUT")
            dialog --clear --title "Detected Active Outputs" --timeout 60 \
                --menu "Select the desired output to modify:" 15 70 5 \
                "${menu_options[@]}" 2> "$MENU_OUT"

            RET=$?
            if [ $RET -eq 255 ]; then
                clear
                echo "EXITED: Idle timeout. Session terminated."
                exit 0
            elif [ $RET -ne 0 ]; then
                clear
                echo "EXITED: Menu closed."
                exit 0
            fi

            SELECTED_OUTPUT=$(cat "$MENU_OUT")

            OUTPUT_BLOCK=$(echo "$KSCREEN_DATA" | awk -v id="$SELECTED_OUTPUT" '
                $1 == "Output:" && $2 == id {p=1; print; next}
                $1 == "Output:" && $2 != id {p=0}
                p
            ')
            
            DISPLAY_NAME=$(echo "$OUTPUT_BLOCK" | awk '/^Output:/ {print $3; exit}')
            
            CURRENT_SCALE=$(echo "$OUTPUT_BLOCK" | grep -ioP 'Scale:\s*\K[0-9.]+')
            CURRENT_HDR=$(echo "$OUTPUT_BLOCK" | grep -ioP 'HDR:\s*\K[a-zA-Z]+')
            CURRENT_VRR=$(echo "$OUTPUT_BLOCK" | grep -ioP 'Vrr:\s*\K[a-zA-Z]+')

            CURRENT_SCALE=${CURRENT_SCALE:-1.0}
            CURRENT_HDR=${CURRENT_HDR:-disabled}
            CURRENT_VRR=${CURRENT_VRR:-incapable}

            STATE="SELECT_PARAMETER"
            ;;

        "SELECT_PARAMETER")
            # Dynamically construct the parameter menu to prune dead-ends
            param_options=("1" "Resolution & Refresh-Rate" "2" "Display Scaling")
            
            if [[ "${CURRENT_HDR,,}" != *"incapable"* && "${CURRENT_HDR,,}" != *"unsupported"* ]]; then
                param_options+=("3" "High Dynamic Range (HDR)")
            fi
            
            if [[ "${CURRENT_VRR,,}" != *"incapable"* && "${CURRENT_VRR,,}" != *"unsupported"* ]]; then
                param_options+=("4" "Variable Refresh Rate (VRR)")
            fi

            MENU_ITEMS=$((${#param_options[@]} / 2))

            dialog --clear --title "Interface $DISPLAY_NAME: Identified Parameters" \
                --menu "Select a parameter to modify:" 15 65 $MENU_ITEMS \
                "${param_options[@]}" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="SELECT_OUTPUT"
                continue
            fi

            PARAM_CHOICE=$(cat "$MENU_OUT")
            case "$PARAM_CHOICE" in
                "1") STATE="RES_GEOMETRY" ;;
                "2") STATE="SCALE_SELECT" ;;
                "3") STATE="HDR_SELECT"   ;;
                "4") STATE="VRR_SELECT"   ;;
            esac
            ;;

        "RES_GEOMETRY")
            MODES_LINE=$(echo "$OUTPUT_BLOCK" | grep "Modes:")
            mapfile -t mode_items < <(echo "$MODES_LINE" | grep -oP '\d+:\d+x\d+@[0-9.]+[!*]*')

            ORIGINAL_MODE_ID=""
            ORIGINAL_READABLE="Unknown"
            ACTIVE_RES=""
            
            for item in "${mode_items[@]}"; do
                if [[ "$item" == *"*"* ]]; then
                    ORIGINAL_MODE_ID=$(echo "$item" | cut -d: -f1)
                    raw_orig=$(echo "$item" | cut -d: -f2 | tr -d '*!')
                    orig_res=$(echo "$raw_orig" | cut -d@ -f1)
                    orig_fps=$(echo "$raw_orig" | awk -F'@' '{printf "%.0f", $2}')
                    ORIGINAL_READABLE="${orig_res} @ ${orig_fps}Hz"
                    ACTIVE_RES="$orig_res"
                    break
                fi
            done

            res_list=()
            for item in "${mode_items[@]}"; do
                res=$(echo "$item" | grep -oP '\d+x\d+')
                res_list+=("$res")
            done

            mapfile -t unique_res < <(printf "%s\n" "${res_list[@]}" | sort -u -t 'x' -k1,1nr -k2,2nr)

            res_dialog_options=()
            res_map=()
            alphabet=({a..z})
            seq_idx=0
            
            for r in "${unique_res[@]}"; do
                tag="${alphabet[$seq_idx]}"
                res_map["$tag"]="$r"
                if [[ "$r" == "$ACTIVE_RES" ]]; then
                    res_dialog_options+=("$tag" "${r}px (Active)")
                else
                    res_dialog_options+=("$tag" "${r}px")
                fi
                ((seq_idx++))
            done

            dialog --clear --title "Interface $DISPLAY_NAME - Identified Resolutions" \
                --menu "Select a resolution:" 18 65 8 \
                "${res_dialog_options[@]}" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="SELECT_PARAMETER"
                continue
            fi

            USER_CHOICE=$(cat "$MENU_OUT")
            SELECTED_RES="${res_map[$USER_CHOICE]}"
            STATE="RES_REFRESH"
            ;;

        "RES_REFRESH")
            seen_fps=()
            fps_map=()
            fps_label_map=()
            fps_options=()
            seq_idx=1

            for item in "${mode_items[@]}"; do
                if [[ "$item" == *"$SELECTED_RES"* ]]; then
                    clean_id=$(echo "$item" | cut -d: -f1)
                    raw_mode=$(echo "$item" | cut -d: -f2 | tr -d '*!')
                    fps_part=$(echo "$raw_mode" | awk -F'@' '{printf "%.0f", $2}')
                    
                    status=""
                    [[ "$item" == *"*"* ]] && status=" (Active)"
                    [[ "$item" == *"!"* ]] && status=" (Optimal)"
                    
                    if [[ -z "${seen_fps[$fps_part]}" ]]; then
                        seen_fps[$fps_part]=1
                        fps_options+=("$seq_idx" "${fps_part}Hz$status")
                        fps_map[$seq_idx]=$clean_id
                        fps_label_map[$seq_idx]="${fps_part}Hz"
                        ((seq_idx++))
                    fi
                fi
            done

            dialog --clear --title "Interface $DISPLAY_NAME - Identified Refresh Rates" \
                --menu "Select the desired refresh rate for $SELECTED_RES:" 18 65 8 \
                "${fps_options[@]}" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="RES_GEOMETRY"
                continue
            fi

            USER_CHOICE=$(cat "$MENU_OUT")
            SELECTED_MODE_ID=${fps_map[$USER_CHOICE]}
            SELECTED_FPS_LABEL=${fps_label_map[$USER_CHOICE]}

            if [[ -z "$ORIGINAL_MODE_ID" ]]; then
                ORIGINAL_MODE_ID=$SELECTED_MODE_ID
                ORIGINAL_READABLE="$SELECTED_RES @ $SELECTED_FPS_LABEL"
            fi

            PAYLOAD_CMD="mode.$SELECTED_MODE_ID"
            ROLLBACK_CMD="mode.$ORIGINAL_MODE_ID"
            HUMAN_MSG="Resolution & Refresh-Rate: $SELECTED_RES @ $SELECTED_FPS_LABEL"
            ROLLBACK_MSG="Resolution & Refresh-Rate: $ORIGINAL_READABLE"
            
            STATE="EXECUTE"
            ;;

        "SCALE_SELECT")
            scale_options=()
            scale_map=()
            idx=1
            for s in 0.50 0.75 1.00 1.25 1.50 2.00 2.50 3.00; do
                scale_options+=("$idx" "${s}x Multiplier")
                scale_map[$idx]="$s"
                ((idx++))
            done
            
            # Inject the arbitrary parameter option
            CUSTOM_IDX=$idx
            scale_options+=("$CUSTOM_IDX" "Custom Display Scale")

            dialog --clear --title "Interface $DISPLAY_NAME - Display Scaling (Currently: $CURRENT_SCALE)" \
                --menu "Select a display scale:" 20 65 13 \
                "${scale_options[@]}" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="SELECT_PARAMETER"
                continue
            fi

            SCALE_CHOICE=$(cat "$MENU_OUT")

            if [ "$SCALE_CHOICE" -eq "$CUSTOM_IDX" ]; then
                dialog --clear --title "Custom Display Scale Input" \
                    --inputbox "Change the current value to any new value between 0.5 and 3:" 8 60 "$CURRENT_SCALE" 2> "$MENU_OUT"
                
                if [ $? -ne 0 ]; then
                    STATE="SCALE_SELECT"
                    continue
                fi
                
                SELECTED_SCALE=$(cat "$MENU_OUT")

                # Sanitize the organic input with regex before mathematically assessing it
                if [[ ! "$SELECTED_SCALE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    dialog --title "Error" --msgbox "Invalid input. Not a number." 6 60
                    STATE="SCALE_SELECT"
                    continue
                fi

                VALID=$(awk -v v="$SELECTED_SCALE" 'BEGIN { if(v >= 0.5 && v <= 3.0) print 1; else print 0 }')
                if [ "$VALID" -ne 1 ]; then
                    dialog --title "Error" --msgbox "Numeber is not between 0.5 and 3 (0.5<[New Value]<3)." 6 60
                    STATE="SCALE_SELECT"
                    continue
                fi
            else
                SELECTED_SCALE="${scale_map[$SCALE_CHOICE]}"
            fi

            PAYLOAD_CMD="scale.$SELECTED_SCALE"
            ROLLBACK_CMD="scale.$CURRENT_SCALE"
            HUMAN_MSG="Display Scale: $SELECTED_SCALE"
            ROLLBACK_MSG="Display Scale: $CURRENT_SCALE"
            
            STATE="EXECUTE"
            ;;

        "HDR_SELECT")
            T_ON=""; T_OFF=""
            case "${CURRENT_HDR,,}" in
                *enable*) T_ON=" (Active)" ;;
                *) T_OFF=" (Active)" ;;
            esac

            if [[ "${CURRENT_HDR,,}" == *"enable"* ]]; then
                ORIG_HDR_CMD="enable"
            else
                ORIG_HDR_CMD="disable"
            fi

            dialog --clear --title "Interface $DISPLAY_NAME - High Dynamic Range (HDR)" \
                --menu "Select an HDR state:" 15 65 2 \
                "1" "Enabled$T_ON" \
                "2" "Disabled$T_OFF" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="SELECT_PARAMETER"
                continue
            fi

            MENU_CHOICE=$(cat "$MENU_OUT")
            if [ "$MENU_CHOICE" == "1" ]; then
                SELECTED_HDR="enable"
            else
                SELECTED_HDR="disable"
            fi

            PAYLOAD_CMD="hdr.$SELECTED_HDR"
            ROLLBACK_CMD="hdr.$ORIG_HDR_CMD"
            HUMAN_MSG="High Dynamic Range (HDR): $SELECTED_HDR"
            ROLLBACK_MSG="High Dynamic Range (HDR): $ORIG_HDR_CMD"
            
            STATE="EXECUTE"
            ;;

        "VRR_SELECT")
            T_AUTO=""; T_ON=""; T_OFF=""
            case "${CURRENT_VRR,,}" in
                *automatic*) T_AUTO=" (Active)" ;;
                *always*) T_ON=" (Active)" ;;
                *) T_OFF=" (Active)" ;;
            esac

            if [[ "${CURRENT_VRR,,}" == *"automatic"* ]]; then
                ORIG_VRR_CMD="automatic"
            elif [[ "${CURRENT_VRR,,}" == *"always"* ]]; then
                ORIG_VRR_CMD="always"
            else
                ORIG_VRR_CMD="never"
            fi

            dialog --clear --title "Interface $DISPLAY_NAME - Variable Refresh-Rate (VRR)" \
                --menu "Select a Variable Refresh-Rate option:" 15 65 3 \
                "1" "VRR Automatic Sync$T_AUTO" \
                "2" "VRR On$T_ON" \
                "3" "VRR Off$T_OFF" 2> "$MENU_OUT"

            if [ $? -ne 0 ]; then
                STATE="SELECT_PARAMETER"
                continue
            fi

            MENU_CHOICE=$(cat "$MENU_OUT")
            case "$MENU_CHOICE" in
                "1") SELECTED_VRR="automatic" ;;
                "2") SELECTED_VRR="always" ;;
                "3") SELECTED_VRR="never" ;;
            esac

            PAYLOAD_CMD="vrrpolicy.$SELECTED_VRR"
            ROLLBACK_CMD="vrrpolicy.$ORIG_VRR_CMD"
            HUMAN_MSG="Variable Refresh Rate (VRR): $SELECTED_VRR"
            ROLLBACK_MSG="Variable Refresh Rate (VRR): $ORIG_VRR_CMD"

            STATE="EXECUTE"
            ;;

        "EXECUTE")
            if [[ "$PAYLOAD_CMD" == "$ROLLBACK_CMD" ]]; then
                clear
                echo "NO CHANGES MADE: confuration matches the current active state ($HUMAN_MSG)."
                exit 0
            fi

            clear
            echo "Preparing to modify display parameters."
            
            kscreen-doctor output."$SELECTED_OUTPUT"."$PAYLOAD_CMD"

            dialog --clear --title "Waiting To Confirm Changes" --timeout 10 --defaultno \
                --yesno "Changes Applied:\nInterface: $DISPLAY_NAME\n$HUMAN_MSG\n\nConfirm changes?\nReverting changes in 10 seconds for failsafe." 10 60

            CONFIRM_STATUS=$?

            clear
            if [ $CONFIRM_STATUS -eq 0 ]; then
                echo "CHANGES: $HUMAN_MSG successfully integrated."
            elif [ $CONFIRM_STATUS -eq 1 ]; then
                echo "CHANGES CANCELLED (User Revert): Rolling back to $ROLLBACK_MSG."
                kscreen-doctor output."$SELECTED_OUTPUT"."$ROLLBACK_CMD" >/dev/null 2>&1
            else
                echo "CHANGES CANCELLED (Timeout/ Failsafe): Rolling back to $ROLLBACK_MSG."
                kscreen-doctor output."$SELECTED_OUTPUT"."$ROLLBACK_CMD" >/dev/null 2>&1
            fi
            exit 0
            ;;
    esac
done