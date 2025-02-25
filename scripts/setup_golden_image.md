# 🚀 Golden Image Setup Guide for Proxmox

This guide explains how to **set up, configure, and maintain the Golden Image** for your Proxmox-based VM deployments.

---

## **🔹 What is a Golden Image?**

A **Golden Image** is a **pre-configured virtual machine** (VM) template with **all necessary software, security configurations, and optimizations**. Instead of setting up each new VM from scratch, you can **clone a ready-to-go template** in seconds.

### **🎯 What This Setup Will Do**

- Installs essential system utilities
- Hardens SSH & kernel security settings
- Enables Cloud-Init for easy customization
- Configures QEMU Guest Agent for Proxmox integration
- Sets up Fail2Ban for SSH protection
- Configures Prometheus Node Exporter for monitoring
- Cleans up the VM for cloning

---

## **🔹 Prerequisites**

Before running the setup script, ensure you have:

1.  A **Proxmox VM** running **Ubuntu/Debian** (minimal recommended).
2.  **A GitHub Personal Access Token (PAT)** to fetch the private setup script.

---

## **🔹 Step 1: Generate a GitHub Personal Access Token (PAT)**

Since the setup script is stored in a **private repository**, you must **authenticate with GitHub** using a **Personal Access Token**.

### **📌 How to Generate a GitHub PAT**

1.  Go to GitHub → Click your profile → **Settings**
2.  Navigate to **Developer Settings** → **Personal Access Tokens**
3.  Click **Generate new token (classic)**
4.  **Set expiration** (e.g., "No Expiration" for long-term use)
5.  **Select the following permissions**:
    - `repo` (for private repo access)
6.  Click **Generate Token**, then **copy the token immediately** (you won't see it again).

---

## **🔹 Step 2: Run the Golden Image Setup Script**

Once you have the GitHub token, run the following **one-liner command** in your Proxmox VM:

```bash
GITHUB_TOKEN="your_github_token_here" && sudo curl -s -H "Authorization: token $GITHUB_TOKEN"\
     -H "Accept: application/vnd.github.v3+json"\
     "https://api.github.com/repos/xtraorange/JamLabTools/contents/scripts/setup_golden_image.sh?ref=main" |\
     jq -r '.content' | base64 --decode | sudo bash
```

### **📌 What This Does**

1.  Authenticates with GitHub using your PAT.
2.  Fetches the latest script from your **private repository**.
3.  Decodes the base64 file (GitHub API returns encoded content).
4.  Runs the setup script as `root`.

---

## **🔹 Step 3: Convert the VM into a Proxmox Template**

After the setup script **completes**, **shut down the VM** and **convert it to a Proxmox template**.

### **🛠️ Shut Down the VM**

```arduino
sudo shutdown -h now
```

### **🛠️ Convert to a Proxmox Template**

1.  Open **Proxmox UI**
2.  Select the VM → **More → Convert to Template**
3.  **Done!** You can now **clone new VMs from this template** instantly.

---

## **🔹 Step 4: Clone a New VM from the Golden Image**

To create a new VM from your template:

1.  **Go to Proxmox** → **Right-click on the template**
2.  Click **Clone**
3.  Set:
    - **Name:** Choose a name
    - **Mode:** `Full Clone` (recommended for standalone VMs)
    - **Target Storage:** Select your storage
4.  Click **Clone**
5.  **Start the new VM** → It will automatically configure itself using **Cloud-Init**.

---

## **🔹 Step 5: Keeping the Golden Image Updated**

If you ever need to **update the Golden Image**, follow these steps:

1.  Clone the template into a **new VM**.
2.  Run the setup script again:

```bash
GITHUB_TOKEN="your_github_token_here" && sudo curl -s -H "Authorization: token $GITHUB_TOKEN"\
     -H "Accept: application/vnd.github.v3+json"\
     "https://api.github.com/repos/xtraorange/JamLabTools/contents/scripts/setup_golden_image.sh?ref=main" |\
     jq -r '.content' | base64 --decode | sudo bash
```

1.  Once updated, **convert the VM back into a template**.

---

## **🔹 Troubleshooting**

### **🚨 No Internet on VM**

- Check network settings:

  ```bash
  ip a
  ```

- If no IP, restart DHCP:

  ```bash
  sudo dhclient -v
  ```

- Ensure Proxmox **VM network adapter** is on the correct bridge (e.g., `vmbr0`).

### **🚨 GitHub API Returns 404**

- Ensure your **GitHub token** has **repo access**.
- Check if the file path is correct:

  `https://api.github.com/repos/xtraorange/JamLabTools/contents/scripts/setup_golden_image.sh?ref=main`

- If branch isn't `main`, replace `ref=main` with your actual branch name.

### **🚨 Script Permission Errors**

- Ensure **you're running the script as `root`**:

  ```arduino
  sudo bash golden-image-setup.sh
  ```

- The setup script **now checks for root permissions**, so it will exit if not run as root.

---

## **🔥 Summary**

| Step                          | Command                           |
| ----------------------------- | --------------------------------- |
| **1\. Generate GitHub Token** | GitHub → Developer Settings → PAT |
| **2\. Run Setup Script**      | Copy & run the one-liner command  |
| **3\. Convert to Template**   | `qm template <VM_ID>` in Proxmox  |
| **4\. Clone a New VM**        | Right-click → Clone               |
| **5\. Update Golden Image**   | Clone → Rerun setup script        |

---

## **🚀 Final Notes**

- This script **automates a full security-hardened Ubuntu/Debian image** for Proxmox.
- Cloud-Init ensures **new VMs auto-configure themselves**.
- If anything breaks, check the **Troubleshooting** section.

💡 **Now, you have a fast and easy way to manage Proxmox VMs!** 🚀
