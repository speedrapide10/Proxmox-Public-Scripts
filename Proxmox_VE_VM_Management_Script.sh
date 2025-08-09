#!/bin/bash
# =============================================================================
# Proxmox VE VM Management Script
#
# Author: speedrapide10
# Version: 16.7 Adjusted for bulk confirmation & improved progress bar fix
# Tested on: Proxmox VE 9.0.3
#
# Modifications:
# - Added one global per-operation confirmation (skip per-VM confirmation)
# - Fixed progress bar display to improve readability and prevent visual issues
# =============================================================================

set -o pipefail
# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Banner ---
echo -e "${GREEN}"
cat << "EOF"
╔════════════════════════════════════════════╗
║                                            ║
║      Proxmox VE VM Management Script       ║
║            by speedrapide10                ║
║                                            ║
╚════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# --- Logging and Output ---
log_message() {
    local type="$1" message="$2" color="$3"
    local plain_message="[$type] $message"
    local colored_message="${color}$plain_message${NC}"
    echo -e "$colored_message"
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $plain_message" >> "$LOG_FILE_PATH"
    fi
    if [[ "$type" == "ERROR" || "$type" == "ERROR_DETAIL" || "$type" == "FAILURE" ]]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $plain_message" >> "$ERROR_LOG_PATH"
    fi
}
print_warning() { log_message "WARNING" "$1" "$YELLOW"; }
print_error() { log_message "ERROR" "$1" "$RED"; }
print_error_detail() { log_message "ERROR_DETAIL" "  - $1" "$RED"; }
print_info() { log_message "INFO" "$1" "$GREEN"; }

# --- Fixed Progress Bar with improved spacing ---
print_overall_progress() {
    local current="$1" total="$2"
    local bar_width=50
    local percentage=0
    if (( total > 0 )); then
        percentage=$((current * 100 / total))
    fi
    local filled_length=$((bar_width * percentage / 100))
    local empty_length=$((bar_width - filled_length))
    local bar=""
    if (( filled_length > 0 )); then
        bar=$(printf "%0.s#" $(seq 1 $filled_length))
    fi
    if (( empty_length > 0 )); then
        bar+=$(printf "%0.s-" $(seq 1 $empty_length))
    fi

    if [[ "$current" -eq "$total" ]]; then
        # Print newline on completion for clean output
        printf "\rOverall Progress: [${GREEN}%s${NC}] %3d%% (%d/%d)\n" "$bar" "$percentage" "$current" "$total"
    else
        # Overwrite line while processing with added trailing spaces to avoid leftover chars
        printf "\rOverall Progress: [${GREEN}%s${NC}] %3d%% (%d/%d)    " "$bar" "$percentage" "$current" "$total"
    fi
}

# --- Shutdown VM ---
shutdown_vm() {
    local vmid="$1" vm_name="$2" SHUTDOWN_TIMEOUT=120
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would attempt to gracefully shut down VM $vmid ($vm_name)."
        return 0
    fi
    print_info "Attempting to gracefully shut down VM $vmid ($vm_name)..."
    if ! error_output=$(qm shutdown "$vmid" 2>&1); then
        print_warning "Graceful shutdown command for VM $vmid ($vm_name) returned a non-zero status."
        print_warning "  - Detail: $error_output"
    fi
    print_info "Waiting for VM $vmid ($vm_name) to stop (timeout: ${SHUTDOWN_TIMEOUT}s)..."
    local count=0
    while [[ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" && "$count" -lt "$SHUTDOWN_TIMEOUT" ]]; do
        sleep 1
        ((count++))
    done
    if [[ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
        print_warning "VM $vmid ($vm_name) did not shut down gracefully. Forcing stop."
        if ! error_output=$(qm stop "$vmid" 2>&1); then
            local err_msg="Failed to force stop VM $vmid ($vm_name)."
            print_error "$err_msg"; print_error_detail "QM Error: $error_output"
            failures+=("$err_msg"$'\n'"  Error: $error_output")
            return 1
        fi
    fi
    print_info "VM $vmid ($vm_name) has been shut down successfully."
    return 0
}

# --- Select VMs from list ---
select_vms_text() {
    clear >&2
    print_info "Available VMs on this host:" >&2
    echo "------------------------------------------------------------------" >&2
    local i=1
    VMS_INDEXED=()
    local sorted_vmids
    IFS=$'\n' sorted_vmids=($(echo "${!VM_NAMES[@]}" | tr ' ' '\n' | sort -n))
    unset IFS
    for vmid in "${sorted_vmids[@]}"; do
        VMS_INDEXED+=("$vmid")
        local vm_name=${VM_NAMES[$vmid]}
        local conf_file="/etc/pve/qemu-server/${vmid}.conf"
        if [ -f "$conf_file" ]; then
            local active_config
            active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
            local machine cpu vga
            machine=$(echo "$active_config" | grep '^machine:' | tail -n 1 | awk '{print $2}')
            [[ -z "$machine" ]] && machine="i440fx (default)"
            cpu=$(echo "$active_config" | grep '^cpu:' | tail -n 1 | awk '{print $2}')
            [[ -z "$cpu" ]] && cpu="x86-64-v2-AES (default)"
            vga=$(echo "$active_config" | grep '^vga:' | tail -n 1 | awk '{$1=""; print $0}' | xargs)
            [[ -z "$vga" ]] && vga="default"
            echo -e "  [${YELLOW}$i${NC}] - VM ${YELLOW}$vmid ($vm_name)${NC} | Machine: ${GREEN}$machine${NC}, CPU: ${GREEN}$cpu${NC}, VGA: ${GREEN}$vga${NC}" >&2
        else
            echo -e "  [${YELLOW}$i${NC}] - VM ${YELLOW}$vmid ($vm_name)${NC} | ${RED}Config file not found${NC}" >&2
        fi
        ((i++))
    done
    echo "------------------------------------------------------------------" >&2; echo >&2
    print_info "Enter the numbers of the VMs you want to process, separated by spaces." >&2
    read -p "Or press [Enter] to process all VMs: " selected_numbers_str < /dev/tty
    if [[ -z "$selected_numbers_str" ]]; then
        echo "all"
    else
        local selected_vmids=""
        for num in $selected_numbers_str; do
            if [[ "$num" =~ ^[0-9]+$ && "$num" -gt 0 && "$num" -le "${#VMS_INDEXED[@]}" ]]; then
                local index=$((num - 1))
                selected_vmids+="${VMS_INDEXED[$index]} "
            else
                print_warning "Invalid number '$num' will be ignored." >&2
            fi
        done
        echo "$selected_vmids"
    fi
}

# --- Check if action needed ---
is_action_needed() {
    local vmid="$1"
    local conf_file="/etc/pve/qemu-server/${vmid}.conf"
    if [[ ! -f "$conf_file" ]]; then
        echo "false"
        return
    fi
    local active_config
    active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
    case "$OPERATION_MODE" in
        snapshot-only|set-spice-mem|revert-spice-mem) echo "true"; return ;;
        i440fx-to-q35)
            local machine_type
            machine_type=$(echo "$active_config" | grep '^machine:' | tail -n 1 | awk '{print $2}')
            [[ -z "$machine_type" ]] && machine_type="i440fx"
            if [[ "$machine_type" == "i440fx" ]]; then echo "true"; else echo "false"; fi
            ;;
        q35-to-i440fx)
            local machine_type
            machine_type=$(echo "$active_config" | grep '^machine:' | tail -n 1 | awk '{print $2}')
            if [[ "$machine_type" == "q35" ]]; then echo "true"; else echo "false"; fi
            ;;
        cpu-v2-to-v3)
            local current_cpu
            current_cpu=$(echo "$active_config" | grep '^cpu:' | tail -n 1 | awk '{print $2}')
            [[ -z "$current_cpu" ]] && current_cpu="x86-64-v2-AES"
            if [[ "$current_cpu" == "x86-64-v2-AES" ]]; then echo "true"; else echo "false"; fi
            ;;
        cpu-v3-to-v2)
            local current_cpu
            current_cpu=$(echo "$active_config" | grep '^cpu:' | tail -n 1 | awk '{print $2}')
            if [[ "$current_cpu" == "x86-64-v3" ]]; then echo "true"; else echo "false"; fi
            ;;
        *) echo "false" ;;
    esac
}

# --- Perform the action ---
perform_action() {
    local vmid="$1" vm_name="$2" conf_file="$3"
    case "$OPERATION_MODE" in
        set-spice-mem)
            print_info "Editing $conf_file to set VGA/SPICE memory to '$SPICE_MEM_VALUE' MB..."
            if grep -q "^vga:" "$conf_file"; then
                sed -i 's/,memory=[0-9]*//' "$conf_file"
                sed -i "/^vga:/ s/$/\,memory=$SPICE_MEM_VALUE/" "$conf_file"
            else
                echo "vga: qxl,memory=$SPICE_MEM_VALUE" >> "$conf_file"
            fi
            if [[ $? -ne 0 ]]; then
                local err_msg="Failed to edit config file for VM $vmid ($vm_name)."
                print_error "$err_msg"
                failures+=("$err_msg")
                config_change_successful=false
            fi
            ;;
        revert-spice-mem)
            print_info "Editing $conf_file to revert SPICE memory to default..."
            if ! sed -i 's/,memory=[0-9]*//' "$conf_file"; then
                local err_msg="Failed to edit config file for VM $vmid ($vm_name)."
                print_error "$err_msg"
                failures+=("$err_msg")
                config_change_successful=false
            fi
            ;;
        i440fx-to-q35)
            local new_machine_type="q35"
            if [[ "$ver_choice" -eq 2 && -n "$SPECIFIC_MACHINE_VERSION" ]]; then
                new_machine_type=$SPECIFIC_MACHINE_VERSION
            fi
            print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
            if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                local err_msg="Failed to change machine type for VM $vmid ($vm_name)."
                print_error "$err_msg"
                print_error_detail "QM Error: $error_output"
                failures+=("$err_msg"$'\n'"  Error: $error_output")
                config_change_successful=false
            fi
            ;;
        q35-to-i440fx)
            if [[ "$ver_choice" -eq 2 && -n "$SPECIFIC_MACHINE_VERSION" ]]; then
                local new_machine_type=$SPECIFIC_MACHINE_VERSION
                print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
                if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                    local err_msg="Failed to change machine type for VM $vmid ($vm_name)."
                    print_error "$err_msg"
                    print_error_detail "QM Error: $error_output"
                    failures+=("$err_msg"$'\n'"  Error: $error_output")
                    config_change_successful=false
                fi
            else
                print_info "Removing 'machine:' line from '$conf_file' to revert to default (latest i440fx)..."
                if ! sed -i '/^machine:/d' "$conf_file"; then
                    local err_msg="Failed to edit config file for VM $vmid ($vm_name)."
                    print_error "$err_msg"
                    failures+=("$err_msg")
                    config_change_successful=false
                fi
            fi
            ;;
        cpu-v2-to-v3)
            local target_cpu="x86-64-v3"
            print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
            if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                local err_msg="Failed to change CPU type for VM $vmid ($vm_name)."
                print_error "$err_msg"
                print_error_detail "QM Error: $error_output"
                failures+=("$err_msg"$'\n'"  Error: $error_output")
                config_change_successful=false
            fi
            ;;
        cpu-v3-to-v2)
            local target_cpu="x86-64-v2-AES"
            print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
            if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                local err_msg="Failed to change CPU type for VM $vmid ($vm_name)."
                print_error "$err_msg"
                print_error_detail "QM Error: $error_output"
                failures+=("$err_msg"$'\n'"  Error: $error_output")
                config_change_successful=false
            fi
            ;;
    esac
}

# --- Snapshot Action submenu ---
snapshot_action_menu() {
    while true; do
        clear
        print_info "Snapshot Action for all affected VMs:"
        echo "  [1] Create New"
        echo "  [2] Replace Last"
        echo "  [3] Do Nothing"
        echo "  [4] Back to Main Menu"
        read -p "  Your choice: " snap_choice_global < /dev/tty
        case $snap_choice_global in
            1|2|3)
                SNAPSHOT_ACTION_CHOICE=$snap_choice_global
                return 0
                ;;
            4)
                return 1  # signal back to main menu
                ;;
            *)
                print_error "Invalid selection."
                sleep 2
                ;;
        esac
    done
}

# --- Machine version submenu ---
machine_version_menu() {
    while true; do
        clear
        print_info "Select machine version option:"
        echo "  [1] Use latest version (default)"
        echo "  [2] Specify a version manually"
        echo "  [3] Back to Main Menu"
        read -p "  Your choice: " ver_choice < /dev/tty
        ver_choice=${ver_choice:-1}
        case $ver_choice in
            1|2) return 0 ;;
            3) return 1 ;;  # signal back to main menu
            *) print_error "Invalid selection."; sleep 2 ;;
        esac
    done
}

# --- Spice menu ---
spice_menu() {
    while true; do
        clear
        print_info "SPICE/VGA Memory Management"
        echo "  Select SPICE/VGA Memory option:"
        echo "    [1] Set custom SPICE Memory"
        echo "    [2] Revert SPICE Memory to Default"
        echo "    [3] Back to Main Menu"
        read -p "    Your choice: " spice_choice < /dev/tty
        case $spice_choice in
            1) OPERATION_MODE="set-spice-mem"; return 0 ;;
            2) OPERATION_MODE="revert-spice-mem"; return 0 ;;
            3) return 1 ;;
            *) print_error "Invalid selection."; sleep 2 ;;
        esac
    done
}

# --- Main menu ---
main_menu() {
    while true; do
        clear
        if [[ ${#all_vms[@]} -eq 0 ]]; then
            print_error "No valid VMs selected to process. Exiting."
            exit 1
        fi
        echo
        print_info "The following valid VMs will be processed:"
        for vmid in "${all_vms[@]}"; do
            vm_name=${VM_NAMES[$vmid]}
            conf_file="/etc/pve/qemu-server/${vmid}.conf"
            active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
            machine=$(echo "$active_config" | grep '^machine:' | tail -n 1 | awk '{print $2}')
            [[ -z "$machine" ]] && machine="i440fx (default)"
            cpu=$(echo "$active_config" | grep '^cpu:' | tail -n 1 | awk '{print $2}')
            [[ -z "$cpu" ]] && cpu="x86-64-v2-AES (default)"
            vga=$(echo "$active_config" | grep '^vga:' | tail -n 1 | awk '{$1=""; print $0}' | xargs)
            [[ -z "$vga" ]] && vga="default"
            echo -e "  - VM ${YELLOW}$vmid ($vm_name)${NC} | Machine: ${GREEN}$machine${NC}, CPU: ${GREEN}$cpu${NC}, VGA: ${GREEN}$vga${NC}"
        done
        echo
        print_info "Interactive Setup:"
        echo "Select operation mode for the selected VMs:"
        echo "  [1] Convert Machine: i440fx -> q35 (& replace snapshot)"
        echo "  [2] Convert Machine: q35 -> i440fx (& replace snapshot)"
        echo "  [3] Convert CPU: x86-64-v2-AES -> x86-64-v3 (& replace snapshot)"
        echo "  [4] Convert CPU: x86-64-v3 -> x86-64-v2-AES (& replace snapshot)"
        echo "  [5] Manage SPICE/VGA Memory"
        echo "  [6] Manage Snapshots"
        echo "  [7] Exit Script"
        read -p "Your choice: " op_choice < /dev/tty
        case $op_choice in
            1) OPERATION_MODE="i440fx-to-q35"; return 0 ;;
            2) OPERATION_MODE="q35-to-i440fx"; return 0 ;;
            3) OPERATION_MODE="cpu-v2-to-v3"; return 0 ;;
            4) OPERATION_MODE="cpu-v3-to-v2"; return 0 ;;
            5)
                spice_menu
                [[ $? -eq 0 ]] || continue
                ;;
            6)
                OPERATION_MODE="snapshot-only"
                snapshot_action_menu
                [[ $? -eq 0 ]] || continue
                return 0
                ;;
            7) echo; print_info "Exiting script as requested."; exit 0 ;;
            *) print_error "Invalid selection. Please enter a number from 1 to 7."; sleep 2 ;;
        esac
    done
}

# --- Sanity Checks and Initialization ---
failures=()
declare -A VM_NAMES
declare -a VMS_INDEXED

if [[ "$(id -u)" -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
fi

while read -r vmid vmname; do
    VM_NAMES[$vmid]=$vmname
done < <(qm list | awk 'NR>1 {print $1, $2}')

raw_vms_input=()
if [[ "$#" -gt 0 ]]; then
    raw_vms_input=("$@")
    print_info "VM IDs provided via command line. Validating list..."
else
    selected_vms_input=$(select_vms_text)
    read -r -a raw_vms_input <<< "$selected_vms_input"
fi

all_vms=()
if [[ ${#raw_vms_input[@]} -gt 0 ]]; then
    if [[ "${raw_vms_input[0]}" == "all" ]]; then
        all_vms=("${!VM_NAMES[@]}")
    else
        for vmid in "${raw_vms_input[@]}"; do
            if [[ -v VM_NAMES["$vmid"] && -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
                all_vms+=("$vmid")
            else
                print_warning "VM ID '$vmid' is not valid or its config file is missing. It will be skipped."
            fi
        done
    fi
fi
IFS=$'\n' all_vms=($(sort -n <<<"${all_vms[*]}"))
unset IFS

while true; do
    main_menu || continue

    if [[ "$OPERATION_MODE" == "i440fx-to-q35" || "$OPERATION_MODE" == "q35-to-i440fx" ]]; then
        if ! machine_version_menu; then
            continue
        fi
        if [[ "$ver_choice" -eq 2 ]]; then
            read -p "Enter specific machine version string (e.g., pc-q35-7.2 or pc-i440fx-7.2): " SPECIFIC_MACHINE_VERSION < /dev/tty
            SPECIFIC_MACHINE_VERSION=$(echo "$SPECIFIC_MACHINE_VERSION" | xargs)
            if [[ -z "$SPECIFIC_MACHINE_VERSION" ]]; then
                print_warning "No machine version provided. Using latest as default."
                ver_choice=1
            fi
        fi
    fi

    if [[ "$OPERATION_MODE" == "set-spice-mem" ]]; then
        while true; do
            read -p "Enter desired SPICE memory in MB (e.g., 32, 64, 128): " SPICE_MEM_VALUE < /dev/tty
            if [[ "$SPICE_MEM_VALUE" =~ ^[0-9]+$ ]]; then break; else print_error "Invalid input. Please enter a number."; fi
        done
    fi

    if [[ "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" && "$OPERATION_MODE" != "snapshot-only" ]]; then
        snapshot_action_menu || continue
    fi

    break
done

DRY_RUN=false
ENABLE_LOGGING=false
LOG_FILE_PATH="/tmp/Proxmox_VE_VM_Management_Script_$(date +%Y%m%d%H%M%S).log"
ERROR_LOG_PATH="/tmp/Proxmox_VE_VM_Management_Script_errors_$(date +%Y%m%d%H%M%S).log"

read -p "Enable Dry Run mode? (y/N): " dry_run_choice < /dev/tty
dry_run_choice=${dry_run_choice:-n}
if [[ "${dry_run_choice,,}" == "y" || "${dry_run_choice,,}" == "yes" ]]; then DRY_RUN=true; else DRY_RUN=false; fi

read -p "Enable logging to a file? (Y/n): " log_choice < /dev/tty
log_choice=${log_choice:-y}
if [[ "${log_choice,,}" == "y" || "${log_choice,,}" == "yes" ]]; then ENABLE_LOGGING=true; else ENABLE_LOGGING=false; fi

if [[ "$ENABLE_LOGGING" == "true" ]]; then
    touch "$LOG_FILE_PATH"
    touch "$ERROR_LOG_PATH"
    print_info "Logging enabled. Log file: $LOG_FILE_PATH, Errors: $ERROR_LOG_PATH"
fi

confirm_all_vms=false
if [[ "$DRY_RUN" == "false" ]]; then
    read -p "Apply operation to ALL selected VMs without prompting for each? (Y/n): " all_confirm < /dev/tty
    all_confirm=${all_confirm:-y}
    if [[ "${all_confirm,,}" == "y" || "${all_confirm,,}" == "yes" ]]; then
        confirm_all_vms=true
    else
        confirm_all_vms=false
    fi
fi

echo
print_warning "Starting VM processing..."
sleep 3

total_vms=${#all_vms[@]}
processed_vms=0
print_overall_progress 0 "$total_vms"

for vmid in "${all_vms[@]}"; do
    vm_name=${VM_NAMES[$vmid]}
    conf_file="/etc/pve/qemu-server/${vmid}.conf"
    echo; echo "-----------------------------------------------------------------"
    print_info "Processing VM $vmid ($vm_name)..."
    config_change_successful=true
    snapshot_action_needed=false

    if ! action_needed=$(is_action_needed "$vmid"); then
        print_error "Could not determine if action is needed for VM $vmid."
        ((processed_vms++))
        print_overall_progress "$processed_vms" "$total_vms"
        continue
    fi

    if [[ "$action_needed" == "false" ]]; then
        print_info "Configuration already correct. Skipping VM $vmid."
        ((processed_vms++))
        print_overall_progress "$processed_vms" "$total_vms"
        continue
    fi

    was_running=false
    if [[ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
        was_running=true
        if ! shutdown_vm "$vmid" "$vm_name"; then
            print_error "Cannot proceed with VM $vmid due to shutdown failure."
            ((processed_vms++))
            print_overall_progress "$processed_vms" "$total_vms"
            continue
        fi
    else
        print_info "VM $vmid is already stopped."
    fi

    proceed_with_change=true
    if [[ "$DRY_RUN" == "false" && "$confirm_all_vms" == "false" ]]; then
        read -p "Proceed with operation for VM $vmid? (Y/n): " change_confirm < /dev/tty
        change_confirm=${change_confirm:-y}
        if ! [[ "${change_confirm,,}" == "y" ]]; then
            proceed_with_change=false
        fi
    fi

    if [[ "$proceed_with_change" == "false" ]]; then
        print_info "Skipping change for VM $vmid as requested."
        config_change_successful=false
    else
        if [[ "$OPERATION_MODE" != "snapshot-only" && "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
            snapshot_action_needed=true
        fi
        perform_action "$vmid" "$vm_name" "$conf_file"
    fi

    if [[ "$snapshot_action_needed" == "true" && "$config_change_successful" == "true" ]]; then
        print_info "Processing snapshots for VM $vmid ($vm_name)..."
        snapshot_list=$(qm listsnapshot "$vmid" 2>/dev/null | grep -i -v 'You are here' || true)
        if [ -z "$snapshot_list" ]; then
            print_info "No snapshots found for VM $vmid."
        else
            latest_snapshot_line=$(echo "$snapshot_list" | tail -n 1)
            latest_snapshot_name=$(echo "$latest_snapshot_line" | awk '{print $2}')
            latest_snapshot_desc=$(echo "$latest_snapshot_line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i}' | sed 's/ *$//')
            if [ -z "$latest_snapshot_name" ]; then
                print_error "Failed to parse latest snapshot name for VM $vmid. Skipping."
            else
                print_info "Found latest snapshot: $latest_snapshot_name (Desc: $latest_snapshot_desc)"
                snap_choice=""
                if [[ "$DRY_RUN" == "true" ]]; then
                    snap_choice=2
                else
                    snap_choice=$SNAPSHOT_ACTION_CHOICE
                fi
                case $snap_choice in
                    1)
                        new_snap_name="after_op_$(date +%Y%m%d_%H%M%S)"
                        print_info "Creating new snapshot: $new_snap_name"
                        if ! error_output=$(qm snapshot "$vmid" "$new_snap_name" --description "New snapshot created by script" 2>&1); then
                            err_msg="Failed to create new snapshot for VM $vmid."
                            print_error "$err_msg"
                            print_error_detail "QM Error: $error_output"
                            failures+=("$err_msg"$'\n'"  $error_output")
                        fi
                        ;;
                    2)
                        print_info "Replacing snapshot '$latest_snapshot_name'..."
                        if ! error_output=$(qm delsnapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                            err_msg="Failed to delete snapshot '$latest_snapshot_name' for VM $vmid."
                            print_error "$err_msg"
                            print_error_detail "QM Error: $error_output"
                            failures+=("$err_msg"$'\n'"  $error_output")
                        else
                            if [[ -n "$latest_snapshot_desc" && "$latest_snapshot_desc" != "no-description" ]]; then
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" --description "$latest_snapshot_desc" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid."
                                    print_error "$err_msg"
                                    print_error_detail "QM Error: $error_output"
                                    failures+=("$err_msg"$'\n'"  $error_output")
                                fi
                            else
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid."
                                    print_error "$err_msg"
                                    print_error_detail "QM Error: $error_output"
                                    failures+=("$err_msg"$'\n'"  $error_output")
                                fi
                            fi
                        fi
                        ;;
                    3)
                        print_info "Skipping snapshot operation for VM $vmid."
                        ;;
                esac
            fi
        fi
    fi

    if [[ "$was_running" == "true" ]]; then
        print_info "Restarting VM $vmid ($vm_name)..."
        if [[ "$DRY_RUN" == "true" ]]; then
            print_info "[DRY RUN] Would start VM $vmid ($vm_name)."
        else
            if ! error_output=$(qm start "$vmid" 2>&1); then
                err_msg="Failed to start VM $vmid."
                print_error "$err_msg"
                print_error_detail "QM Error: $error_output"
                failures+=("$err_msg"$'\n'"  $error_output")
            fi
        fi
    fi

    ((processed_vms++))
    print_overall_progress "$processed_vms" "$total_vms"
done

if [ ${#failures[@]} -gt 0 ]; then
    echo; echo "-----------------------------------------------------------------"
    print_error "SUMMARY OF FAILURES"
    print_warning "The following operations failed and may require manual intervention:"
    for error in "${failures[@]}"; do
        log_message "FAILURE" "$error" "$RED"
    done
fi

echo; echo "-----------------------------------------------------------------"
print_info "All tasks completed."
