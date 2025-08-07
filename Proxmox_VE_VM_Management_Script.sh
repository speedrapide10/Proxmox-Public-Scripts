#!/bin/bash
# =============================================================================
# Proxmox VE VM Management Script
#
# Author: speedrapide10
# Version: 16.4 (Menu Logic Fix)
# Tested on: Proxmox VE 9.0.3
#
# This script provides a robust, safe, and reliable method for automating
# common VM management tasks on a Proxmox VE host.
#
# USAGE:
# To run interactively:
# curl -sL [URL] | sudo bash
#
# To run on specific VMs (e.g., 101, 102):
# curl -sL [URL] | sudo bash -s -- 101 102
#
# =============================================================================

# Exit immediately if a pipeline fails
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
║     Proxmox VE VM Management Script        ║
║           by speedrapide10                 ║
║                                            ║
╚════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# --- Script Functions ---

log_message() {
    local type="$1" message="$2" color="$3"
    local plain_message="[$type] $message"
    local colored_message="${color}$plain_message${NC}"
    echo -e "$colored_message"
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $plain_message" >> "$LOG_FILE_PATH"
    fi
}

print_warning() { log_message "WARNING" "$1" "$YELLOW"; }
print_error() { log_message "ERROR" "$1" "$RED"; }
print_error_detail() { log_message "ERROR_DETAIL" "  - $1" "$RED"; }
print_info() { log_message "INFO" "$1" "$GREEN"; }

print_overall_progress() {
    local current="$1" total="$2"
    local term_width=${COLUMNS:-80} bar_width=$((term_width - 35))
    if [[ "$bar_width" -lt 10 ]]; then bar_width=10; fi
    local percentage=$((current * 100 / total))
    local filled_length=$((bar_width * percentage / 100))
    local bar
    bar=$(printf "%*s" "$filled_length" | tr ' ' '#')
    
    if [[ "$current" -eq "$total" ]]; then
        printf "\rOverall Progress: [${GREEN}%-${bar_width}s${NC}] %d%% (%d/%d)\033[K\n" "$bar" "$percentage" "$current" "$total"
    else
        printf "\rOverall Progress: [${GREEN}%-${bar_width}s${NC}] %d%% (%d/%d)\033[K" "$bar" "$percentage" "$current" "$total"
    fi
}

shutdown_vm() {
    local vmid="$1" vm_name="$2" SHUTDOWN_TIMEOUT=120
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "[DRY RUN] Would attempt to gracefully shut down VM $vmid ($vm_name)."
        return 0
    fi
    print_info "Attempting to gracefully shut down VM $vmid ($vm_name)..."
    if ! error_output=$(qm shutdown "$vmid" 2>&1); then
        print_warning "Graceful shutdown command for VM $vmid ($vm_name) returned a non-zero status. Will check status and force stop if needed."
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
            failures+=("$err_msg\n  Error: $error_output")
            return 1
        fi
    fi
    print_info "VM $vmid ($vm_name) has been shut down successfully."
    return 0
}

select_vms_text() {
    clear >&2
    print_info "Available VMs on this host:" >&2
    echo "------------------------------------------------------------------" >&2
    
    local i=1
    VMS_INDEXED=()
    for vmid in $(echo "${!VM_NAMES[@]}" | tr ' ' '\n' | sort -n); do
        VMS_INDEXED+=("$vmid")
        local vm_name=${VM_NAMES[$vmid]}
        local conf_file="/etc/pve/qemu-server/${vmid}.conf"
        if [ -f "$conf_file" ]; then
            local active_config machine cpu vga
            active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
            machine=$(echo "$active_config" | grep '^machine:' | awk '{print $2}')
            if [ -z "$machine" ]; then machine="i440fx (default)"; fi
            cpu=$(echo "$active_config" | grep '^cpu:' | awk '{print $2}')
            if [ -z "$cpu" ]; then cpu="x86-64-v2-AES (default)"; fi
            vga=$(echo "$active_config" | grep '^vga:' | awk '{$1=""; print $0}' | xargs)
            if [ -z "$vga" ]; then vga="default"; fi
            
            echo -e "  [${YELLOW}$i${NC}] - VM ${YELLOW}$vmid ($vm_name)${NC} | Machine: ${GREEN}$machine${NC}, CPU: ${GREEN}$cpu${NC}, VGA: ${GREEN}$vga${NC}" >&2
        else
            echo -e "  [${YELLOW}$i${NC}] - VM ${YELLOW}$vmid ($vm_name)${NC} | ${RED}Config file not found${NC}" >&2
        fi
        ((i++))
    done
    echo "------------------------------------------------------------------" >&2; echo >&2
    print_info "Enter the numbers of the VMs you want to process, separated by spaces." >&2
    
    read -p "Or press [Enter] to process all VMs: " selected_numbers_str < /dev/tty

    if [ -z "$selected_numbers_str" ]; then
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

is_action_needed() {
    local vmid="$1"
    local conf_file="/etc/pve/qemu-server/${vmid}.conf"
    local active_config
    active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
    
    case "$OPERATION_MODE" in
        snapshot-only|set-spice-mem|revert-spice-mem) echo "true"; return ;;
        i440fx-to-q35)
            local machine_type
            machine_type=$(echo "$active_config" | grep '^machine:' | awk '{print $2}')
            if [ -z "$machine_type" ]; then machine_type="i440fx"; fi
            if [[ "$machine_type" == *"i440fx"* ]]; then echo "true"; else echo "false"; fi
            ;;
        q35-to-i440fx)
            local machine_type
            machine_type=$(echo "$active_config" | grep '^machine:' | awk '{print $2}')
            if [[ "$machine_type" == *"q35"* ]]; then echo "true"; else echo "false"; fi
            ;;
        cpu-v2-to-v3)
            local current_cpu
            current_cpu=$(echo "$active_config" | grep '^cpu:' | awk '{print $2}')
            if [ -z "$current_cpu" ]; then current_cpu="x86-64-v2-AES"; fi
            if [[ "$current_cpu" == "x86-64-v2-AES" ]]; then echo "true"; else echo "false"; fi
            ;;
        cpu-v3-to-v2)
            local current_cpu
            current_cpu=$(echo "$active_config" | grep '^cpu:' | awk '{print $2}')
            if [[ "$current_cpu" == "x86-64-v3" ]]; then echo "true"; else echo "false"; fi
            ;;
        *) echo "false" ;;
    esac
}

perform_action() {
    local vmid="$1" vm_name="$2" conf_file="$3"
    
    case "$OPERATION_MODE" in
        set-spice-mem)
            print_info "Editing $conf_file to set VGA/SPICE memory to '$SPICE_MEM_VALUE' MB..."
            if grep -q "^vga:" "$conf_file"; then
                sed -i 's/,memory=[0-9]*//' "$conf_file" && sed -i "/^vga:/ s/$/\,memory=$SPICE_MEM_VALUE/" "$conf_file"
            else
                echo "vga: qxl,memory=$SPICE_MEM_VALUE" >> "$conf_file"
            fi
            if [[ $? -ne 0 ]]; then local err_msg="Failed to edit config file for VM $vmid ($vm_name)."; print_error "$err_msg"; failures+=("$err_msg"); config_change_successful=false; fi
            ;;
        revert-spice-mem)
            print_info "Editing $conf_file to revert SPICE memory to default..."
            if ! sed -i 's/,memory=[0-9]*//' "$conf_file"; then
                local err_msg="Failed to edit config file for VM $vmid ($vm_name)."; print_error "$err_msg"; failures+=("$err_msg"); config_change_successful=false
            fi
            ;;
        i440fx-to-q35)
            local new_machine_type="q35"
            if [[ "$ver_choice" -eq 2 ]]; then new_machine_type=$SPECIFIC_MACHINE_VERSION; fi
            print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
            if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                local err_msg="Failed to change machine type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
            fi
            ;;
        q35-to-i440fx)
            if [[ "$ver_choice" -eq 2 ]]; then
                local new_machine_type=$SPECIFIC_MACHINE_VERSION
                print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
                if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                    local err_msg="Failed to change machine type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
                fi
            else
                print_info "Removing 'machine:' line from '$conf_file' to revert to default (latest i440fx)..."
                if ! sed -i '/^machine:/d' "$conf_file"; then
                    local err_msg="Failed to edit config file for VM $vmid ($vm_name)."; print_error "$err_msg"; failures+=("$err_msg"); config_change_successful=false
                fi
            fi
            ;;
        cpu-v2-to-v3)
            local target_cpu="x86-64-v3"
            print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
            if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                local err_msg="Failed to change CPU type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
            fi
            ;;
        cpu-v3-to-v2)
            local target_cpu="x86-64-v2-AES"
            print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
            if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                local err_msg="Failed to change CPU type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
            fi
            ;;
    esac
}


# --- Main Script ---
failures=()
declare -A VM_NAMES
declare -a VMS_INDEXED

if [[ "$(id -u)" -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
fi

# --- Populate VM List ---
while read -r vmid vmname; do
    VM_NAMES[$vmid]=$vmname
done < <(qm list | awk 'NR>1 {print $1, $2}')

# --- VM Selection ---
raw_vms_input=()
if [[ "$#" -gt 0 ]]; then
    raw_vms_input=("$@")
    print_info "VM IDs provided via command line. Validating list..."
else
    selected_vms_input=$(select_vms_text)
    raw_vms_input=($selected_vms_input)
fi

# --- Validate selected VMs and build a clean, sorted list ---
all_vms=()
if [[ ${#raw_vms_input[@]} -gt 0 ]]; then
    if [[ "${raw_vms_input[0]}" == "all" ]]; then
        all_vms=("${!VM_NAMES[@]}")
    else
        for vmid in "${raw_vms_input[@]}"; do
            if [[ -v VM_NAMES[$vmid] && -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
                all_vms+=("$vmid")
            else
                print_warning "VM ID '$vmid' is not valid or its config file is missing. It will be skipped."
            fi
        done
    fi
fi

all_vms=($(for vmid in "${all_vms[@]}"; do echo "$vmid"; done | sort -n))

# --- INTERACTIVE CONFIGURATION LOOP ---
# This single loop controls the entire configuration flow.
# "Back to main menu" options will use 'continue' to restart this loop.
while true; do
    if [[ ${#all_vms[@]} -eq 0 ]]; then
        print_error "No valid VMs selected to process. Exiting."
        exit 1
    fi

    clear
    echo
    print_info "The following valid VMs will be processed:"
    for vmid in "${all_vms[@]}"; do
        vm_name=${VM_NAMES[$vmid]}
        conf_file="/etc/pve/qemu-server/${vmid}.conf"
        active_config=$(sed '/^\s*\[.*\]/,$d' "$conf_file")
        machine=$(echo "$active_config" | grep '^machine:' | awk '{print $2}')
        if [ -z "$machine" ]; then machine="i440fx (default)"; fi
        cpu=$(echo "$active_config" | grep '^cpu:' | awk '{print $2}')
        if [ -z "$cpu" ]; then cpu="x86-64-v2-AES (default)"; fi
        vga=$(echo "$active_config" | grep '^vga:' | awk '{$1=""; print $0}' | xargs)
        if [ -z "$vga" ]; then vga="default"; fi
        echo -e "  - VM ${YELLOW}$vmid ($vm_name)${NC} | Machine: ${GREEN}$machine${NC}, CPU: ${GREEN}$cpu${NC}, VGA: ${GREEN}$vga${NC}"
    done
    echo

    # --- MAIN MENU ---
    OPERATION_MODE=""
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
        1) OPERATION_MODE="i440fx-to-q35";;
        2) OPERATION_MODE="q35-to-i440fx";;
        3) OPERATION_MODE="cpu-v2-to-v3";;
        4) OPERATION_MODE="cpu-v3-to-v2";;
        5)
            while true; do
                clear
                print_info "SPICE/VGA Memory Management"
                echo "  Select SPICE/VGA Memory option:"
                echo "    [1] Set custom SPICE Memory"
                echo "    [2] Revert SPICE Memory to Default"
                echo "    [3] Back to Main Menu"
                read -p "    Your choice: " spice_choice < /dev/tty
                case $spice_choice in
                    1) OPERATION_MODE="set-spice-mem"; break;;
                    2) OPERATION_MODE="revert-spice-mem"; break;;
                    3) continue 2;; # continue the outer while loop
                    *) print_error "Invalid selection.";;
                esac
            done
            ;;
        6) OPERATION_MODE="snapshot-only";;
        7) echo; print_info "Exiting script as requested."; exit 0;;
        *) print_error "Invalid selection. Please enter a number from 1 to 7."; sleep 2; continue;;
    esac

    # --- SUB-MENUS AND CONFIGURATION ---

    if [[ "$OPERATION_MODE" == "set-spice-mem" ]]; then
        while true; do
            read -p "Enter desired SPICE memory in MB (e.g., 32, 64, 128): " SPICE_MEM_VALUE < /dev/tty
            if [[ "$SPICE_MEM_VALUE" =~ ^[0-9]+$ ]]; then break; else print_error "Invalid input. Please enter a number."; fi
        done
    fi

    if [[ "$OPERATION_MODE" == "i440fx-to-q35" || "$OPERATION_MODE" == "q35-to-i440fx" ]]; then
        while true; do
            clear
            print_info "Select machine version option:"
            echo "  [1] Use latest version (default)"
            echo "  [2] Specify a version manually"
            echo "  [3] Back to Main Menu"
            read -p "  Your choice: " ver_choice < /dev/tty
            ver_choice=${ver_choice:-1}
            case $ver_choice in
                1|2) break;;
                3) continue 2;; # Correctly continues the main config loop
                *) print_error "Invalid selection.";;
            esac
        done
        if [[ "$ver_choice" -eq 2 ]]; then
            read -p "Enter the full machine type string (e.g., pc-q35-8.1): " SPECIFIC_MACHINE_VERSION < /dev/tty
        fi
    fi

    SNAPSHOT_ACTION_CHOICE=""
    if [[ "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
        while true; do
            clear
            print_info "Snapshot Action for all affected VMs:"
            echo "  [1] Create New"
            echo "  [2] Replace Last"
            echo "  [3] Do Nothing"
            echo "  [4] Back to Main Menu"
            read -p "  Your choice: " snap_choice_global < /dev/tty
            case $snap_choice_global in
                1|2|3) SNAPSHOT_ACTION_CHOICE=$snap_choice_global; break;;
                4) continue 2;; # Correctly continues the main config loop
                *) print_error "Invalid selection.";;
            esac
        done
    fi

    # If we got here without 'continue', all configuration is done. Exit the loop.
    break
done


# --- FINAL CONFIRMATIONS AND EXECUTION ---

GLOBAL_CONFIRM=false
if [[ ${#all_vms[@]} -gt 1 ]]; then
    read -p "Apply changes to all selected VMs without individual confirmation? (Y/n): " global_confirm_choice < /dev/tty
    if [[ "${global_confirm_choice:-y}" =~ ^[Yy]$ ]]; then
        GLOBAL_CONFIRM=true
    fi
fi

read -p "Enable Dry Run mode? (y/N): " dry_run_choice < /dev/tty
dry_run_choice=${dry_run_choice:-n}
if [[ "${dry_run_choice,,}" == "y" || "${dry_run_choice,,}" == "yes" ]]; then DRY_RUN=true; else DRY_RUN=false; fi

read -p "Enable logging to a file? (Y/n): " log_choice < /dev/tty
log_choice=${log_choice:-y}
if [[ "${log_choice,,}" == "y" || "${log_choice,,}" == "yes" ]]; then ENABLE_LOGGING=true; else ENABLE_LOGGING=false; fi

LOG_FILE_PATH="/tmp/replace_cpu_model-$(date +"%Y%m%d-%H%M%S").log"
if [[ "$ENABLE_LOGGING" == "true" ]]; then touch "$LOG_FILE_PATH"; print_info "Logging enabled. Log file at: $LOG_FILE_PATH"; fi

echo
print_warning "This script will shut down all running selected VMs *that require changes*."
if [[ "$OPERATION_MODE" != "snapshot-only" && "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
    print_warning "It may also delete and recreate snapshots, which is a destructive action."
fi
echo

if [[ "$DRY_RUN" == "false" ]]; then
    print_warning "DRY RUN mode is disabled. The script will perform actual changes."
    read -p "Are you sure you want to continue? (Y/n): " confirm < /dev/tty
    confirm=${confirm:-y}
    if ! [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]]; then echo "Aborting."; exit 0; fi
fi

echo
print_warning "The script will now begin processing VMs. Interrupting the script (Ctrl+C) from this point may leave VMs in a stopped state."
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
        ((processed_vms++)); print_overall_progress "$processed_vms" "$total_vms"
        continue
    fi

    if [[ "$action_needed" == "false" ]]; then
        print_info "Configuration is already correct. Skipping all operations for this VM."
        ((processed_vms++)); print_overall_progress "$processed_vms" "$total_vms"
        continue
    fi

    was_running=false
    if [[ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
        was_running=true
        if ! shutdown_vm "$vmid" "$vm_name"; then
            print_error "Cannot proceed with VM $vmid ($vm_name) due to shutdown failure."
            ((processed_vms++)); print_overall_progress "$processed_vms" "$total_vms"
            continue
        fi
    else
        print_info "VM $vmid ($vm_name) is already stopped."
    fi

    proceed_with_change=true
    if [[ "$DRY_RUN" == "false" && "$GLOBAL_CONFIRM" == "false" ]]; then
        read -p "Proceed with operation for VM $vmid? (Y/n): " change_confirm < /dev/tty
        if ! [[ "${change_confirm:-y}" =~ ^[Yy]$ ]]; then
            proceed_with_change=false
        fi
    fi

    if [[ "$proceed_with_change" == "false" ]]; then
        print_info "Skipping change for VM $vmid as requested."
        config_change_successful=false
    else
        perform_action "$vmid" "$vm_name" "$conf_file"
    fi

    # Snapshot logic requires a check if config change was successful AND it's a relevant operation
    if [[ "$config_change_successful" == "true" && "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
        snapshot_action_needed=true
    fi

    if [[ "$snapshot_action_needed" == "true" ]]; then
        print_info "Processing snapshots for VM $vmid ($vm_name)..."
        # Determine which choice to use for snapshots
        snap_choice=$SNAPSHOT_ACTION_CHOICE
        if [[ "$DRY_RUN" == "true" ]]; then
            # In dry-run, simulate the most common action without prompting
             if [[ -z "$snap_choice" ]]; then snap_choice=2; fi
        fi

        case $snap_choice in
            1) # Create New Snapshot
                new_snap_name="after_op_$(date +%Y%m%d_%H%M%S)"
                print_info "Creating new snapshot named '$new_snap_name'..."
                if [[ "$DRY_RUN" == "true" ]]; then
                    print_info "[DRY RUN] Would create new snapshot '$new_snap_name'."
                elif ! error_output=$(qm snapshot "$vmid" "$new_snap_name" --description "New snapshot created by script" 2>&1); then
                    err_msg="Failed to create new snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                fi
                ;;
            2) # Replace Last Snapshot
                snapshot_list=$(qm listsnapshot "$vmid" | grep -i -v 'You are here')
                if [ -z "$snapshot_list" ]; then
                    print_info "No actual snapshots found for VM $vmid ($vm_name) to replace."
                else
                    latest_snapshot_line=$(echo "$snapshot_list" | tail -n 1)
                    latest_snapshot_name=$(echo "$latest_snapshot_line" | awk '{print $2}')
                    latest_snapshot_desc=$(echo "$latest_snapshot_line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i}' | sed 's/ *$//')

                    if [ -z "$latest_snapshot_name" ]; then
                         print_error "Failed to correctly parse the latest snapshot name for VM $vmid ($vm_name). Skipping."
                    else
                        print_info "Found most recent snapshot: Name: '$latest_snapshot_name', Description: '$latest_snapshot_desc'"
                        print_info "Deleting snapshot '$latest_snapshot_name'..."
                        if [[ "$DRY_RUN" == "true" ]]; then
                            print_info "[DRY RUN] Would delete snapshot '$latest_snapshot_name'."
                        elif ! error_output=$(qm delsnapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                            err_msg="Failed to delete snapshot '$latest_snapshot_name' for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                        else
                            print_info "Recreating snapshot '$latest_snapshot_name'..."
                            if [[ "$DRY_RUN" == "true" ]]; then
                                print_info "[DRY RUN] Would recreate snapshot '$latest_snapshot_name'."
                            elif [[ -n "$latest_snapshot_desc" && "$latest_snapshot_desc" != "no-description" ]]; then
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" --description "$latest_snapshot_desc" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                                fi
                            else
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                                fi
                            fi
                        fi
                    fi
                fi
                ;;
            3) # Do Nothing
                print_info "Skipping snapshot operation as requested."
                ;;
        esac
    fi
    
    if [[ "$was_running" == "true" ]]; then
        print_info "Restarting VM $vmid ($vm_name)..."
        if [[ "$DRY_RUN" == "true" ]]; then print_info "[DRY RUN] Would start VM $vmid ($vm_name)."; else
            if ! error_output=$(qm start "$vmid" 2>&1); then
                err_msg="Failed to issue start for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
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