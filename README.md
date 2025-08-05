# Proxmox-Public-Scripts: Proxmox VE VM Management Script

A powerful, interactive Bash script designed to automate and streamline common virtual machine (VM) management tasks on a Proxmox VE host. This tool is built for sysadmins and power users who need to perform bulk operations safely and efficiently without navigating the web UI for every change.

## 🚀 Quick Start: Run It Anywhere

Execute the script directly on your Proxmox VE node with this single command for an interactive session.

```bash
curl -sL https://raw.githubusercontent.com/speedrapide10/Proxmox-Public-Scripts/main/Proxmox_VE_VM_Management_Script.sh | bash
```

> **Security Warning:** Always exercise caution when running scripts from the internet directly with `sudo`. It is highly recommended to review the code before execution to ensure it meets your security standards.

## ✨ Key Features

This script is more than just a simple automation tool; it's an interactive "multi-tool" for managing your existing virtual environment.

-   **🖥️ Interactive & Non-Interactive Modes:** Run the script with a full, user-friendly menu system, or pass VM IDs directly as command-line arguments for faster execution.
    
-   **🎯 Selective VM Processing:** Choose exactly which VMs to manage from a clean, numbered list. Or, with a single press of \[Enter\], run the operation on all VMs at once.
    
-   **⚙️ Multi-Operation Support:**
    
    -   **Machine Type Conversion:** Switch between `i440fx` and `q35` machine types, with an option to use the "Latest" available version or specify one manually.
        
    -   **CPU Model Conversion:** Easily change CPU models between common versions like `x86-64-v2-AES` and `x86-64-v3`.
        
    -   **SPICE/VGA Memory Management:** Set a custom graphics memory value or revert it to the Proxmox default by directly editing the VM's configuration file.
        
-   **📸 Advanced Snapshot Control:** After a successful configuration change, the script asks **once** for your desired snapshot action for the entire batch:
    
    1.  **Create a new, timestamped snapshot.**
        
    2.  **Replace the last snapshot** (delete and recreate with the same name/description).
        
    3.  **Do nothing** and skip the snapshot step.
        
-   **🛡️ Safety First:**
    
    -   **Smart Shutdown:** VMs are only shut down if the script determines a change is actually required, saving time and unnecessary reboots.
        
    -   **Global & Per-VM Confirmation:** Approve changes for all VMs at once, or step through and confirm each one individually for granular control.
        
    -   **Dry Run Mode:** Simulate any operation without making actual changes to see what the script _would_ do.
        
    -   **Failure Summary:** At the end of the run, you get a clear, color-coded summary of any operations that failed, making it easy to troubleshoot.
        
-   **📜 Optional Logging:** All actions can be logged to a timestamped file in `/tmp` for auditing and review.
    

## 📋 Requirements

-   **Proxmox VE:** Tested and confirmed working on version **8.4.8**.
    
-   **Root Access:** The script must be run as the `root` user or with `sudo` privileges to access VM configuration files and execute `qm` commands.
    
-   **Bash:** The script is written for the Bash shell, which is standard on Proxmox VE.
    

## 🕹️ Usage Guide

### Interactive Mode

This is the most common way to use the script. It provides a full menu-driven experience.

1.  **Run the script** using the `curl | bash` command.
    
2.  **Select VMs:** You will be presented with a numbered list of all VMs on your host, complete with their current configuration.
    
    ```csharp
    [INFO] Available VMs on this host:
    ------------------------------------------------------------------
      [1] - VM 101 (ubuntu-server) | Machine: q35, CPU: x86-64-v3, VGA: qxl
      [2] - VM 102 (win11-dev)     | Machine: pc-i440fx-8.1, CPU: host, VGA: virtio,memory=64
      [3] - VM 103 (debian-test)   | Machine: i440fx (default), CPU: kvm64 (default), VGA: default
    ------------------------------------------------------------------
    
    [INFO] Enter the numbers of the VMs you want to process, separated by spaces.
    Or press [Enter] to process all VMs: 1 3
    ```
    
3.  **Choose an Operation:** After confirming your VM selection, the main menu will appear. Select the number corresponding to the task you want to perform.
    
    ```less
    [INFO] Interactive Setup:
    Select operation mode for the selected VMs:
      [1] Convert Machine: i440fx -> q35 (& replace snapshot)
      [2] Convert Machine: q35 -> i440fx (& replace snapshot)
      ...
      [7] Replace last snapshot only
      [8] Exit Script
    Your choice: 2
    ```
    
4.  **Configure Options & Confirm:** The script will then ask for any additional settings (like snapshot handling or Dry Run mode) and present a final confirmation before starting the operations.
    

### Advanced Usage: Command-Line Mode

For faster operations or for use in your own scripts, you can bypass the interactive VM selection by providing a space-separated list of VM IDs as arguments.

**Syntax:** `curl -sL [URL] | bash -s -- <VMID1> <VMID2> <VMID3>`

**Example:** This command will load the script and immediately select VMs `101`, `102`, and `305` before proceeding to the main operations menu.

```bash
curl -sL https://raw.githubusercontent.com/speedrapide10/Proxmox-Public-Scripts/main/Proxmox_VE_VM_Management_Script.sh | bash -s -- 101 102 305
```

## 🤝 Contributing & Feedback

This was a passion project, but I believe there's always more room for improvement! If you have suggestions for new features, find a bug, or have ideas for making the script even better, please feel free to:

-   **Open an Issue:** Report bugs or suggest features.
    
-   **Submit a Pull Request:** Contribute directly to the code.
    

Your feedback is highly welcome!

## 📜 License

This project is licensed under the MIT License. See the [LICENSE](https://github.com/speedrapide10/Proxmox-Public-Scripts/blob/main/LICENSE) file for details.