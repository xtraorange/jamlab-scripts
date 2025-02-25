# 🚀 **Setup & Connect a Node to Teleport**

This guide explains how to install and connect a **Teleport Node** to your **Teleport Proxy**.

---

## **🔹 What This Script Does**

✔ Installs **Teleport** on an Ubuntu/Debian machine\
✔ Configures Teleport to connect to **your proxy**\
✔ Uses a **secure join token** for authentication\
✔ **Disables SSL verification** to avoid self-signed cert issues\
✔ Automatically **starts and enables** Teleport

---

## **🔹 Prerequisites**

Before running the script, ensure you have:\
✅ A **Teleport Proxy** that is up and running\
✅ **Admin access to the Teleport Web UI** to generate a token\
✅ A **GitHub Personal Access Token (PAT)** to fetch the script

---

## **🔹 Step 1: Generate a Join Token in Teleport Web UI**

1️⃣ **Log into your Teleport Web UI** (e.g., `https://10.10.20.3:3080`)\
2️⃣ Go to **Access > Join Tokens**\
3️⃣ Click **"Generate Token"**\
4️⃣ **Select the "Node" role**\
5️⃣ **Set an expiration time** (TTL)\
6️⃣ Click **"Generate"** and **copy the token**

---

## **🔹 Step 2: Generate a GitHub Personal Access Token (PAT)**

Since the setup script is stored in a **private repository**, you need **GitHub authentication**.

### **📌 How to Generate a GitHub PAT**

1️⃣ **Go to GitHub** → Click your profile → **Settings**\
2️⃣ Navigate to **Developer Settings** → **Personal Access Tokens**\
3️⃣ Click **"Generate new token (classic)"**\
4️⃣ **Set expiration** (e.g., "No Expiration" for long-term use)\
5️⃣ **Select the following permissions**:

- ✅ `repo` (for private repo access)\
  6️⃣ Click **"Generate Token"**, then **copy the token immediately** (you won't see it again).

---

## **🔹 Step 3: Run the Installation Script**

Once you have the **Teleport Join Token** and **GitHub PAT**, run:

```bash
GITHUB_TOKEN="your_github_token_here" &&\
TELEPORT_PROXY="10.10.20.3" &&\
TELEPORT_TOKEN="your_teleport_token_here" &&\
sudo curl -s -H "Authorization: token $GITHUB_TOKEN"\
     -H "Accept: application/vnd.github.v3+json"\
     "https://api.github.com/repos/xtraorange/JamLabTools/contents/scripts/setup_teleport.sh?ref=main" |\
     jq -r '.content' | base64 --decode | sudo env TELEPORT_PROXY="$TELEPORT_PROXY" TELEPORT_TOKEN="$TELEPORT_TOKEN" bash
```

---

## **🔹 Step 4: Verify the Node in Teleport**

After installation, check if the node **successfully registered**:

```bash
tctl nodes ls
```

✅ If you see your node in the list, the setup was successful!

Alternatively, check the **Teleport Web UI** under **"Nodes"** to see if it has joined the cluster.

---

## **🔹 Troubleshooting**

### **🚨 Node Doesn't Appear in Teleport**

- Ensure the **Teleport proxy is running**:

  ```bash
  systemctl status teleport
  ```

- Check if the **Teleport process is running**:

  ```bash
  ps aux | grep teleport
  ```

- Restart Teleport if needed:

  ```bash
  systemctl restart teleport
  ```

### **🚨 Self-Signed Certificate Issues**

- **This script already disables SSL verification (`--insecure`)**, so no additional steps should be needed.
- If you want to properly trust the cert instead, refer to the Teleport documentation.

---

## **📌 Summary**

| Step                            | Action                                                  |
| ------------------------------- | ------------------------------------------------------- |
| **1\. Generate Join Token**     | Go to **Teleport Web UI > Access > Join Tokens**        |
| **2\. Generate GitHub PAT**     | **GitHub > Developer Settings > Personal Access Token** |
| **3\. Run Install Script**      | Use the **corrected curl command**                      |
| **4\. Verify Node in Teleport** | Run `tctl nodes ls` or check the Web UI                 |

---

## **🚀 Now Your Nodes Will Automatically Connect to Teleport!**
