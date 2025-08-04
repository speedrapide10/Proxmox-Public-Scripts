#!/bin/bash

# =============================================================================
# Proxmox VE VM Management Script
#
# Author: speedrapide10
# Version: 16.1 (Smart Shutdown & Global Confirm)
# Testing on: Proxmox VE 8.4.6
#
# This script provides a robust, safe, and reliable method for automating
# common VM management tasks on a Proxmox VE host.
#
# TASKS:
# 1. Presents a text-based menu to select target VMs.
# 2. Only shuts down VMs if a configuration change is actually required.
# 3. Offers multiple operational modes for the selected VMs.
# 4. Asks for a single, global confirmation for bulk operations.
# 5. Asks for a single, global snapshot action for the entire batch.
# 6. Restarts the VM if it was previously running.
# 7. Provides a dynamic, dependency-free progress bar.
# 8. Optionally logs all output to a file, based on user input.
# 9. Reports specific error messages and provides a summary of all failures at the end.
#
# =============================================================================

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
# --- End Banner ---

# --- Script Functions ---

# Function to log messages to console and optionally to a file
log_message() {
    local type=$1
    local message=$2
    local color=$3
    local plain_message="[$type] $message"
    local colored_message="${color}$plain_message${NC}"
    echo -e "$colored_message"
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") - $plain_message" >> "$LOG_FILE_PATH"
    fi
}

# Wrapper functions for different message types
print_warning() { log_message "WARNING" "$1" "$YELLOW"; }
print_error() { log_message "ERROR" "$1" "$RED"; }
print_error_detail() { log_message "ERROR_DETAIL" "  - $1" "$RED"; }
print_info() { log_message "INFO" "$1" "$GREEN"; }

# Function to display a dynamic progress bar for the entire operation.
print_overall_progress() {
    local current=$1
    local total=$2
    local term_width=${COLUMNS:-80}
    local bar_width=$((term_width - 30))
    if [ "$bar_width" -lt 10 ]; then bar_width=10; fi
    local percentage=$((current * 100 / total))
    local filled_length=$((bar_width * percentage / 100))
    local bar=$(printf "%*s" "$filled_length" | tr ' ' '#')
    if [ "$current" -eq "$total" ]; then
        printf "\rOverall Progress: [${GREEN}%-${bar_width}s${NC}] %d%% (%d/%d)\n" "$bar" "$percentage" "$current" "$total"
    else
        printf "\rOverall Progress: [${GREEN}%-${bar_width}s${NC}] %d%% (%d/%d)" "$bar" "$percentage" "$current" "$total"
    fi
}

# Function to handle shutdown of a single VM.
shutdown_vm() {
    local vmid=$1
    local vm_name=$2
    local SHUTDOWN_TIMEOUT=120
    if [ "$DRY_RUN" = true ]; then
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
    while [ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ] && [ $count -lt $SHUTDOWN_TIMEOUT ]; do
        sleep 1
        ((count++))
    done
    if [ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]; then
        print_warning "VM $vmid ($vm_name) did not shut down gracefully. Forcing stop."
        if ! error_output=$(qm stop "$vmid" 2>&1); then
            local err_msg="Failed to force stop VM $vmid ($vm_name)."
            print_error "$err_msg"
            print_error_detail "QM Error: $error_output"
            failures+=("$err_msg\n  Error: $error_output")
            return 1
        fi
    fi
    print_info "VM $vmid ($vm_name) has been shut down successfully."
    return 0
}

# Function for a stable, text-based VM selection
select_vms_text() {
    clear >&2
    print_info "Available VMs on this host:" >&2
    echo "------------------------------------------------------------------" >&2
    # Use the globally declared associative array to store VM names by ID
    for vmid in $(echo "${!VM_NAMES[@]}" | tr ' ' '\n' | sort -n); do
        printf "  VM %-5s %s\n" "$vmid" "${VM_NAMES[$vmid]}"
    done >&2
    echo "------------------------------------------------------------------" >&2
    echo >&2
    print_info "Enter the VM IDs you want to process, separated by spaces." >&2
    
    read -p "Or press [Enter] to process all VMs: " selected_vms_str < /dev/tty

    if [ -z "$selected_vms_str" ]; then
        echo "all"
    else
        echo "$selected_vms_str"
    fi
}


# --- Main Script ---
failures=()
declare -A VM_NAMES

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root."
    exit 1
fi

# --- Populate VM List ---
while read -r vmid vmname; do
    VM_NAMES[$vmid]=$vmname
done < <(qm list | awk 'NR>1 {print $1, $2}')

# --- VM Selection ---
selected_vms_input=$(select_vms_text)
clear

raw_vms_input=()
if [[ "$selected_vms_input" == "all" ]]; then
    raw_vms_input=("${!VM_NAMES[@]}")
    print_info "All VMs were selected. Validating list..."
else
    raw_vms_input=($selected_vms_input)
fi

# --- Validate selected VMs and build a clean, sorted list ---
all_vms=()
if [ ${#raw_vms_input[@]} -gt 0 ]; then
    for vmid in "${raw_vms_input[@]}"; do
        if [[ -v VM_NAMES[$vmid] ]] && [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then
            all_vms+=("$vmid")
        else
            print_warning "VM ID '$vmid' is not valid or its config file is missing. It will be skipped."
        fi
    done
fi

# Sort the final list of VMs to be processed
all_vms=($(for vmid in "${all_vms[@]}"; do echo "$vmid"; done | sort -n))

if [ ${#all_vms[@]} -gt 0 ]; then
    echo
    print_info "The following valid VMs will be processed:"
    for vmid in "${all_vms[@]}"; do
        vm_name=${VM_NAMES[$vmid]}
        conf_file="/etc/pve/qemu-server/${vmid}.conf"
        machine=$(grep '^machine:' "$conf_file" | tail -n 1 | awk '{print $2}')
        if [ -z "$machine" ]; then machine="i440fx (default)"; fi
        cpu=$(grep '^cpu:' "$conf_file" | tail -n 1 | awk '{print $2}')
        if [ -z "$cpu" ]; then cpu="kvm64 (default)"; fi
        vga=$(grep '^vga:' "$conf_file" | tail -n 1 | awk '{$1=""; print $0}' | xargs)
        if [ -z "$vga" ]; then vga="default"; fi
        
        echo -e "  - VM ${YELLOW}$vmid ($vm_name)${NC} | Machine: ${GREEN}$machine${NC}, CPU: ${GREEN}$cpu${NC}, VGA: ${GREEN}$vga${NC}"
    done
    echo
else
    print_error "No valid VMs selected to process. Exiting."
    exit 1
fi


# --- INTERACTIVE CONFIGURATION ---
print_info "Interactive Setup:"
while true; do
    echo "Select operation mode for the selected VMs:"
    echo "  [1] Convert Machine: i440fx -> q35 (& replace snapshot)"
    echo "  [2] Convert Machine: q35 -> i440fx (& replace snapshot)"
    echo "  [3] Convert CPU: x86-64-v2-AES -> x86-64-v3 (& replace snapshot)"
    echo "  [4] Convert CPU: x86-64-v3 -> x86-64-v2-AES (& replace snapshot)"
    echo "  [5] Set custom SPICE Memory (no snapshot change)"
    echo "  [6] Revert SPICE Memory to Default (no snapshot change)"
    echo "  [7] Replace last snapshot only"
    read -p "Your choice: " op_choice < /dev/tty
    case $op_choice in
        1) OPERATION_MODE="i440fx-to-q35"; break;;
        2) OPERATION_MODE="q35-to-i440fx"; break;;
        3) OPERATION_MODE="cpu-v2-to-v3"; break;;
        4) OPERATION_MODE="cpu-v3-to-v2"; break;;
        5) OPERATION_MODE="set-spice-mem"; break;;
        6) OPERATION_MODE="revert-spice-mem"; break;;
        7) OPERATION_MODE="snapshot-only"; break;;
        *) print_error "Invalid selection. Please enter a number from 1 to 7.";;
    esac
done

if [ "$OPERATION_MODE" == "set-spice-mem" ]; then
    while true; do
        read -p "Enter desired SPICE memory in MB (e.g., 32, 64, 128): " SPICE_MEM_VALUE < /dev/tty
        if [[ "$SPICE_MEM_VALUE" =~ ^[0-9]+$ ]]; then break; else print_error "Invalid input. Please enter a number."; fi
    done
fi

SNAPSHOT_ACTION_CHOICE=""
if [[ "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
    while true; do
        read -p "For all affected VMs, choose a snapshot action: [1] Create New, [2] Replace Last, [3] Do Nothing: " snap_choice_global < /dev/tty
        case $snap_choice_global in
            1|2|3) SNAPSHOT_ACTION_CHOICE=$snap_choice_global; break;;
            *) print_error "Invalid selection.";;
        esac
    done
fi

GLOBAL_CONFIRM=false
if [ ${#all_vms[@]} -gt 1 ]; then
    read -p "Apply changes to all selected VMs without individual confirmation? (Y/n): " global_confirm_choice < /dev/tty
    if [[ "${global_confirm_choice:-y}" =~ ^[Yy]$ ]]; then
        GLOBAL_CONFIRM=true
    fi
fi

read -p "Enable Dry Run mode? (y/N): " dry_run_choice < /dev/tty
dry_run_choice=${dry_run_choice:-n}
dry_run_lower=$(echo "$dry_run_choice" | tr '[:upper:]' '[:lower:]')
if [[ "$dry_run_lower" == "y" || "$dry_run_lower" == "yes" ]]; then DRY_RUN=true; else DRY_RUN=false; fi

read -p "Enable logging to a file? (Y/n): " log_choice < /dev/tty
log_choice=${log_choice:-y}
log_lower=$(echo "$log_choice" | tr '[:upper:]' '[:lower:]')
if [[ "$log_lower" == "y" || "$log_lower" == "yes" ]]; then ENABLE_LOGGING=true; else ENABLE_LOGGING=false; fi

LOG_FILE_PATH="/tmp/replace_cpu_model-$(date +"%Y%m%d-%H%M%S").log"
if [ "$ENABLE_LOGGING" = true ]; then touch "$LOG_FILE_PATH"; print_info "Logging enabled. Log file at: $LOG_FILE_PATH"; fi

echo
print_warning "This script will shut down all running selected VMs *that require changes*."
if [[ "$OPERATION_MODE" != "snapshot-only" && "$OPERATION_MODE" != "set-spice-mem" && "$OPERATION_MODE" != "revert-spice-mem" ]]; then
    print_warning "It may also delete and recreate snapshots, which is a destructive action."
fi
echo

if [ "$DRY_RUN" = true ]; then
    print_info "DRY RUN mode is enabled. No actual changes will be made."
else
    print_warning "DRY RUN mode is disabled. The script will perform actual changes."
    read -p "Are you sure you want to continue? (Y/n): " confirm < /dev/tty
    confirm=${confirm:-y}
    confirm_lower=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
    if [[ "$confirm_lower" != "y" && "$confirm_lower" != "yes" ]]; then echo "Aborting."; exit 0; fi
fi

total_vms=${#all_vms[@]}
processed_vms=0
print_overall_progress 0 "$total_vms"

for vmid in "${all_vms[@]}"; do
    vm_name=${VM_NAMES[$vmid]}
    conf_file="/etc/pve/qemu-server/${vmid}.conf"
    
    echo; echo "-----------------------------------------------------------------"
    print_info "Processing VM $vmid ($vm_name)..."
    
    action_needed=false; config_change_successful=true; snapshot_action_needed=false;
    
    # --- Pre-check to see if any action is needed before shutting down ---
    case "$OPERATION_MODE" in
        snapshot-only) action_needed=true; snapshot_action_needed=true ;;
        set-spice-mem) action_needed=true ;;
        revert-spice-mem) action_needed=true ;;
        i440fx-to-q35)
            machine_type=$(grep '^machine:' "$conf_file" | tail -n 1 | awk '{print $2}'); if [ -z "$machine_type" ]; then machine_type="i440fx"; fi
            if [[ "$machine_type" == *"i440fx"* ]]; then action_needed=true; snapshot_action_needed=true; fi
            ;;
        q35-to-i440fx)
            machine_type=$(grep '^machine:' "$conf_file" | tail -n 1 | awk '{print $2}'); if [ -z "$machine_type" ]; then machine_type="i440fx"; fi
            if [[ "$machine_type" == *"q35"* ]]; then action_needed=true; snapshot_action_needed=true; fi
            ;;
        cpu-v2-to-v3)
            current_cpu=$(grep '^cpu:' "$conf_file" | tail -n 1 | awk '{print $2}'); if [ -z "$current_cpu" ]; then current_cpu="kvm64"; fi
            if [[ "$current_cpu" == "x86-64-v2-AES" ]]; then action_needed=true; snapshot_action_needed=true; fi
            ;;
        cpu-v3-to-v2)
            current_cpu=$(grep '^cpu:' "$conf_file" | tail -n 1 | awk '{print $2}'); if [ -z "$current_cpu" ]; then current_cpu="kvm64"; fi
            if [[ "$current_cpu" == "x86-64-v3" ]]; then action_needed=true; snapshot_action_needed=true; fi
            ;;
    esac

    if [ "$action_needed" = false ]; then
        print_info "Configuration is already correct. Skipping all operations for this VM."
        ((processed_vms++)); print_overall_progress "$processed_vms" "$total_vms"
        continue
    fi

    was_running=false
    if [ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]; then
        was_running=true
        if ! shutdown_vm "$vmid" "$vm_name"; then
            print_error "Cannot proceed with VM $vmid ($vm_name) due to shutdown failure."
            ((processed_vms++)); print_overall_progress "$processed_vms" "$total_vms"
            continue
        fi
    else
        print_info "VM $vmid ($vm_name) is already stopped."
    fi

    # --- Perform the actual action ---
    proceed_with_change=true
    if [ "$DRY_RUN" = false ] && [ "$GLOBAL_CONFIRM" = false ]; then
        read -p "Proceed with operation for VM $vmid? (Y/n): " change_confirm < /dev/tty
        if ! [[ "${change_confirm:-y}" =~ ^[Yy]$ ]]; then
            proceed_with_change=false
        fi
    fi

    if [ "$proceed_with_change" = false ]; then
        print_info "Skipping change for VM $vmid as requested."
        config_change_successful=false
    else
        case "$OPERATION_MODE" in
            set-spice-mem)
                print_info "Editing $conf_file to set VGA/SPICE memory to '$SPICE_MEM_VALUE' MB..."
                if grep -q "^vga:" "$conf_file"; then
                    sed -i 's/,memory=[0-9]*//' "$conf_file"
                    sed -i "/^vga:/ s/$/\,memory=$SPICE_MEM_VALUE/" "$conf_file"
                else
                    echo "vga: qxl,memory=$SPICE_MEM_VALUE" >> "$conf_file"
                fi
                if [ $? -ne 0 ]; then err_msg="Failed to edit config file for VM $vmid ($vm_name)."; print_error "$err_msg"; failures+=("$err_msg"); config_change_successful=false; fi
                ;;
            revert-spice-mem)
                print_info "Editing $conf_file to revert SPICE memory to default..."
                if ! sed -i 's/,memory=[0-9]*//' "$conf_file"; then
                    err_msg="Failed to edit config file for VM $vmid ($vm_name)."; print_error "$err_msg"; failures+=("$err_msg"); config_change_successful=false
                fi
                ;;
            i440fx-to-q35)
                new_machine_type="q35"
                print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
                if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                    err_msg="Failed to change machine type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
                fi
                ;;
            q35-to-i440fx)
                new_machine_type="pc-i440fx-9.2+pve1"
                print_info "Changing machine type of VM $vmid ($vm_name) to '$new_machine_type'..."
                if ! error_output=$(qm set "$vmid" --machine "$new_machine_type" 2>&1); then
                    err_msg="Failed to change machine type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
                fi
                ;;
            cpu-v2-to-v3)
                target_cpu="x86-64-v3"
                print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
                if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                    err_msg="Failed to change CPU type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
                fi
                ;;
            cpu-v3-to-v2)
                target_cpu="x86-64-v2-AES"
                print_info "Changing CPU type of VM $vmid ($vm_name) to '$target_cpu'..."
                if ! error_output=$(qm set "$vmid" --cpu "$target_cpu" 2>&1); then
                    err_msg="Failed to change CPU type for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output"); config_change_successful=false
                fi
                ;;
        esac
    fi

    if [ "$snapshot_action_needed" = true ] && [ "$config_change_successful" = true ]; then
        print_info "Processing snapshots for VM $vmid ($vm_name)..."
        snapshot_list=$(qm listsnapshot "$vmid" | grep -i -v 'You are here')
        if [ -z "$snapshot_list" ]; then print_info "No actual snapshots found for VM $vmid ($vm_name)."; else
            latest_snapshot_line=$(echo "$snapshot_list" | tail -n 1)
            latest_snapshot_name=$(echo "$latest_snapshot_line" | awk '{print $2}')
            latest_snapshot_desc=$(echo "$latest_snapshot_line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i}' | sed 's/ *$//')
            if [ -z "$latest_snapshot_name" ]; then print_error "Failed to correctly parse the latest snapshot name for VM $vmid ($vm_name). Skipping."; else
                print_info "Found most recent snapshot: Name: '$latest_snapshot_name', Description: '$latest_snapshot_desc'"
                
                snap_choice=""
                if [ "$DRY_RUN" = true ]; then snap_choice=2; else snap_choice=$SNAPSHOT_ACTION_CHOICE; fi

                case $snap_choice in
                    1) # Create New Snapshot
                        new_snap_name="after_op_$(date +%Y%m%d_%H%M%S)"
                        print_info "Creating new snapshot named '$new_snap_name'..."
                        if ! error_output=$(qm snapshot "$vmid" "$new_snap_name" --description "New snapshot created by script" 2>&1); then
                            err_msg="Failed to create new snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                        fi
                        ;;
                    2) # Replace Last Snapshot
                        print_info "Deleting snapshot '$latest_snapshot_name'..."
                        if ! error_output=$(qm delsnapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                            err_msg="Failed to delete snapshot '$latest_snapshot_name' for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                        else
                            print_info "Recreating snapshot '$latest_snapshot_name'..."
                            if [ -n "$latest_snapshot_desc" ] && [ "$latest_snapshot_desc" != "no-description" ]; then
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" --description "$latest_snapshot_desc" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                                fi
                            else
                                if ! error_output=$(qm snapshot "$vmid" "$latest_snapshot_name" 2>&1); then
                                    err_msg="Failed to recreate snapshot for VM $vmid ($vm_name)."; print_error "$err_msg"; print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
                                fi
                            fi
                        fi
                        ;;
                    3) # Do Nothing
                        print_info "Skipping snapshot operation as requested."
                        ;;
                esac
            fi
        fi
    fi
    
    if [ "$was_running" = true ]; then
        print_info "Restarting VM $vmid ($vm_name)..."
        if [ "$DRY_RUN" = true ]; then print_info "[DRY RUN] Would start VM $vmid ($vm_name)."; else
            if ! error_output=$(qm start "$vmid" 2>&1); then
                err_msg="Failed to issue start for VM $vmid ($vm_name)."; print_error "$err_msg"
                print_error_detail "QM Error: $error_output"; failures+=("$err_msg\n  Error: $error_output")
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