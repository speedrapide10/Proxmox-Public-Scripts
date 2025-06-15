# Proxmox-Public-Scripts: Proxmox VE VM Management Script

A powerful, interactive Bash script designed to automate and streamline common virtual machine (VM) management tasks on a Proxmox VE host. This tool is built for sysadmins and power users who need to perform bulk operations safely and efficiently without navigating the web UI for every change.

## 🚀 Quick Start: Run It Anywhere

Execute the script directly on your Proxmox VE node with this single command.

```bash
curl -sL https://raw.githubusercontent.com/speedrapide10/Proxmox-Public-Scripts/main/Proxmox%20VE%20VM%20Management%20Script/Proxmox_VE_VM_Management_Script.sh | bash
```

> **Security Warning:** Always exercise caution when running scripts from the internet directly with `sudo`. It is highly recommended to review the code before execution to ensure it meets your security standards.

## ✨ Key Features

This script is more than just a simple automation tool; it's an interactive "multi-tool" for managing your existing virtual environment.

* **🖥️ Interactive Menus:** A user-friendly, menu-driven interface guides you through all operations. No need to edit the script to change settings.
* **🎯 Selective VM Processing:** Choose exactly which VMs to manage from a clean, sorted list. Or, with a single press of [Enter], run the operation on all VMs at once.
* **⚙️ Multi-Operation Support:**
    * **Machine Type Conversion:** Switch between `i440fx` and `q35` machine types.
    * **CPU Model Conversion:** Easily change CPU models between common versions like `x86-64-v2-AES` and `x86-64-v3`.
    * **SPICE/VGA Memory Management:** Set a custom graphics memory value or revert it to the Proxmox default.
* **📸 Advanced Snapshot Control:** After a successful configuration change, the script gives you three choices:
    1.  **Create a new, timestamped snapshot.**
    2.  **Replace the last snapshot** (delete and recreate with the same name/description).
    3.  **Do nothing** and skip the snapshot step.
* **🛡️ Safety First:**
    * **Per-VM Confirmation:** The script asks for final confirmation before applying any changes to a VM, showing you the current settings first.
    * **Dry Run Mode:** Simulate any operation without making actual changes to see what the script *would* do.
    * **Failure Summary:** At the end of the run, you get a clear, color-coded summary of any operations that failed, making it easy to troubleshoot.
* **📜 Optional Logging:** All actions can be logged to a timestamped file in `/tmp` for auditing and review.

## 📋 Requirements

* **Proxmox VE:** Tested and confirmed working on version **8.4.1**.
* **Root Access:** The script must be run as the `root` user or with `sudo` privileges to access VM configuration files and execute `qm` commands.
* **Bash:** The script is written for the Bash shell, which is standard on Proxmox VE.

## 🕹️ Usage Guide

1.  **Run the script** using the `curl | bash` command provided above, or by cloning the repository and running it locally (`./Proxmox_VE_VM_Management_Script.sh`).
2.  **Select VMs:** You will be presented with a list of all VMs on your host. Enter the VM IDs you want to manage, separated by spaces. Press [Enter] without typing any IDs to select all VMs.
3.  **Choose an Operation:** A menu will appear with all available actions. Select the number corresponding to the task you want to perform.
4.  **Configure Options:** The script will then ask for any additional settings, such as Dry Run mode or logging. Defaults are provided for convenience.
5.  **Confirm and Proceed:** The script will show you which VMs are about to be processed and ask for a final confirmation before starting the operations.

## 🤝 Contributing & Feedback

This was a passion project, but I believe there's always more room for improvement! If you have suggestions for new features, find a bug, or have ideas for making the script even better, please feel free to:

* **Open an Issue:** Report bugs or suggest features.
* **Submit a Pull Request:** Contribute directly to the code.

Your feedback is highly welcome!

## 📜 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.