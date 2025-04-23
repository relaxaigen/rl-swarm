#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-""}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
YELLOW_TEXT="\033[33m" # Added yellow for warnings/prompts
RED_TEXT="\033[31m"   # Added red for errors
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

echo_yellow() {
    echo -e "$YELLOW_TEXT$1$RESET_TEXT"
}

echo_red() {
    echo -e "$RED_TEXT$1$RESET_TEXT"
}


ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
NGROK_PID="" # Initialize NGROK_PID
SERVER_PID="" # Initialize SERVER_PID
NGROK_LOG_FILE="$ROOT_DIR/ngrok.log" # Define log file path

# Function to clean up the server and ngrok process upon exit
cleanup() {
    # --- IMPORTANT: Disable traps immediately to prevent recursive calls ---
    trap - EXIT INT TERM

    echo_green ">> Shutting down trainer..." # Ye ab sirf ek baar print hona chahiye

    # Remove modal credentials if they exist
    # Added quotes for robustness with paths containing spaces (though unlikely here)
    rm -r "$ROOT_DIR/modal-login/temp-data/"*.json 2> /dev/null || true

    # Kill ngrok process if it was started
    if [ -n "$NGROK_PID" ]; then
         echo_yellow ">> Shutting down ngrok tunnel (PID: $NGROK_PID)..."
         # Use quotes around PID variable
         kill "$NGROK_PID" 2>/dev/null || true
         # Use quotes around file variable
         rm -f "$NGROK_LOG_FILE" # Clean up ngrok log file
    fi

    # Kill the local server process if it was started
    if [ -n "$SERVER_PID" ]; then
         echo_yellow ">> Shutting down local server (PID: $SERVER_PID)..."
         # Use quotes around PID variable
         kill "$SERVER_PID" 2>/dev/null || true
    fi

    # Kill all processes belonging to this script's process group as a fallback
    # This is now safer as traps are disabled
    echo_yellow ">> Attempting to kill remaining processes in group (final check)..."
    # Redirect stderr to prevent potential "Terminated" messages to console
    kill -- -$$ 2>/dev/null || true

    echo_green ">> Cleanup complete."
    # No need for explicit 'exit 0' here - the script will exit naturally after the trap handler finishes.
}

# Set trap to call cleanup function on EXIT, INT (Ctrl+C), TERM signals
trap cleanup EXIT INT TERM

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}  # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=True && break ;;
        [Nn]*)  CONNECT_TO_TESTNET=False && break ;;
        *)  echo_yellow ">>> Please answer yes or no." ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = "True" ]; then
    echo_blue ">> Setting up Testnet connection..."

    # --- Ngrok Check ---
    echo_blue ">> Checking for ngrok..."
    if ! command -v ngrok &> /dev/null; then
        echo_red "Error: ngrok command not found."
        echo_yellow "Please install ngrok from https://ngrok.com/download and make sure it's in your PATH."
        exit 1
    else
        echo_green ">> ngrok found: $(which ngrok)"
    fi

    # --- Ngrok Authtoken ---
    echo -en $GREEN_TEXT
    read -p ">> Please enter your ngrok Authtoken (from https://dashboard.ngrok.com/get-started/your-authtoken): " NGROK_AUTHTOKEN
    echo -en $RESET_TEXT
    if [ -z "$NGROK_AUTHTOKEN" ]; then
        echo_red "Error: Ngrok Authtoken is required to create a tunnel."
        exit 1
    fi
    echo_blue ">> Configuring ngrok with your Authtoken..."
    # Configure ngrok, redirect errors to stderr, suppress success message on stdout
    ngrok config add-authtoken "$NGROK_AUTHTOKEN" --log=stderr > /dev/null || { echo_red "Error configuring ngrok token."; exit 1; }
    echo_green ">> Ngrok configured successfully."

    # --- Run modal_login server ---
    echo_blue ">> Starting local authentication server..."
    cd modal-login
    # Check if the yarn command exists; if not, install Yarn.
    source ~/.bashrc # Ensure environment variables are loaded

    # Node.js + NVM setup
    if ! command -v node >/dev/null 2>&1; then
        echo_yellow "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        # Source NVM script for current session
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
       nvm install node # Install latest Node.js LTS
       # Re-source NVM script after installation to ensure 'node' command is available
       [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    else
        echo_green ">> Node.js is already installed: $(node -v)"
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        echo_yellow "Yarn not found. Attempting to install Yarn..."
        # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
        if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
            echo_blue "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt-get update && sudo apt-get install -y --no-install-recommends yarn
        else
            # Fallback for other systems (may require user intervention)
            echo_yellow "Attempting to install Yarn using npm (requires Node.js/npm). Please ensure Node.js is installed."
             if command -v npm > /dev/null 2>&1; then
                 sudo npm install --global yarn
             else
                 echo_red "Error: npm is not installed. Cannot install Yarn automatically."
                 echo_yellow "Please install Yarn manually: https://classic.yarnpkg.com/en/docs/install"
                 exit 1
             fi
        fi
        # Check again if yarn is now available
        if ! command -v yarn > /dev/null 2>&1; then
             echo_red "Error: Yarn installation failed or PATH is not updated. Please install Yarn manually and restart the script."
             exit 1
        fi
    else
        echo_green ">> Yarn is already installed: $(yarn --version)"
    fi

    echo_blue ">> Installing project dependencies using yarn..."
    yarn install
    echo_blue ">> Starting authentication server process (yarn dev)..."
    # Run in background and suppress output to console, keep logs minimal
    yarn dev --silent > /dev/null 2>&1 &
    SERVER_PID=$!  # Store the process ID
    echo_green ">> Started local server process: $SERVER_PID"
    echo_blue ">> Waiting for local server to be ready..."
    sleep 5 # Give the server a moment to start

    # --- Start Ngrok Tunnel ---
    echo_blue ">> Starting ngrok tunnel for http://localhost:3000..."
    # Start ngrok in background, log to a file
    rm -f "$NGROK_LOG_FILE" # Remove old log file if exists
    ngrok http 3000 --log "$NGROK_LOG_FILE" &
    NGROK_PID=$!
    echo_green ">> Started ngrok process: $NGROK_PID"

    # --- Get Ngrok URL ---
    NGROK_URL=""
    echo_blue ">> Waiting for ngrok tunnel URL..."
    # Wait up to 30 seconds for ngrok to establish the tunnel and write the URL
    for i in {1..15}; do
        # Try getting URL via ngrok API first (more reliable)
        NGROK_URL=$(curl --silent http://127.0.0.1:4040/api/tunnels | grep -o '"public_url":"https://[^"]*' | cut -d'"' -f4)

        if [ -n "$NGROK_URL" ]; then
            break
        fi
        # Fallback: Check log file if API fails or is slow
        if [ -f "$NGROK_LOG_FILE" ]; then
             # Look for lines like 'url=https://....ngrok-free.app' or 'URL:https://....ngrok.io'
            NGROK_URL=$(grep -o 'url=https://[a-zA-Z0-9.-]*\.ngrok[-a-z.]*' "$NGROK_LOG_FILE" | head -n 1 | cut -d'=' -f2)
        fi
        if [ -n "$NGROK_URL" ]; then
            break
        fi
        sleep 2 # Wait longer between checks
    done

    if [ -z "$NGROK_URL" ]; then
        echo_red "Error: Could not get ngrok tunnel URL after 30 seconds."
        echo_yellow "Check ngrok status (maybe run 'ngrok http 3000' manually in another terminal)."
        echo_yellow "Also check the log file: $NGROK_LOG_FILE"
        # Cleanup and exit if ngrok failed
        cleanup
        exit 1
    fi

    echo_green ">> Ngrok tunnel established!"
    echo_blue ">> Please use this URL in your browser to login: $NGROK_URL"
    # No need to try opening automatically, as it's an ngrok URL now.

    cd .. # Go back to the root directory

    # --- Wait for User Login via Ngrok ---
    echo_green ">> Waiting for login process to complete via the ngrok URL..."
    echo_yellow ">> Please complete the login in your browser using the URL: $NGROK_URL"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        echo_blue ">> Still waiting for login confirmation (userData.json)..."
        sleep 5  # Wait for 5 seconds before checking again
    done
    echo_green ">> Found userData.json. Login successful!"

    # Extract ORG_ID
    ORG_ID=$(awk 'BEGIN { FS = "\"" } /"orgId"/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json) || { echo_red "Error extracting ORG_ID from userData.json"; exit 1; }
    if [ -z "$ORG_ID" ]; then
        echo_red "Error: ORG_ID could not be extracted from userData.json. File content:"
        cat "modal-login/temp-data/userData.json"
        exit 1
    fi
    echo_green ">> Your ORG_ID is set to: $ORG_ID"

    # --- Wait for API Key Activation ---
    echo_blue ">> Waiting for API key to become activated..."
    # The check should still query the LOCAL server, as the script runs locally
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo_green ">> API key is activated! Proceeding..."
            break
        else
            echo_yellow ">> Waiting for API key to be activated (status: $STATUS)..."
            sleep 5
        fi
    done

else
    echo_blue ">> Skipping Testnet connection and ngrok setup."
fi # End of CONNECT_TO_TESTNET block

# --- Python Environment Setup ---
pip_install() {
    pip install --disable-pip-version-check -q -r "$1"
}

echo_green ">> Getting requirements..."
pip_install "$ROOT"/requirements-hivemind.txt
pip_install "$ROOT"/requirements.txt

if ! command -v nvidia-smi &> /dev/null; then
    # You don't have a NVIDIA GPU
    echo_yellow ">> No NVIDIA GPU detected or nvidia-smi not found. Using CPU configuration."
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
elif [ -n "$CPU_ONLY" ]; then
    # ... or we don't want to use it
    echo_yellow ">> CPU_ONLY flag is set. Using CPU configuration."
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
    # NVIDIA GPU found
    echo_green ">> NVIDIA GPU detected. Installing GPU requirements..."
    pip_install "$ROOT"/requirements_gpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    echo_green ">> Using GPU configuration."
fi

echo_green ">> Done installing requirements!"

# --- Hugging Face Token ---
HF_TOKEN=${HF_TOKEN:-""}
if [ -n "${HF_TOKEN}" ]; then # Check if HF_TOKEN is already set and use if so. Else give user a prompt to choose.
    echo_green ">> Using existing HF_TOKEN environment variable."
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N} # Default to "N" if the user presses Enter
    case $yn in
        [Yy]*)
             echo -en $YELLOW_TEXT
             read -p ">>> Enter your Hugging Face access token (write permission required): " HUGGINGFACE_ACCESS_TOKEN
             echo -en $RESET_TEXT
             ;;
        [Nn]*) HUGGINGFACE_ACCESS_TOKEN="None" ;;
        *) echo_yellow ">>> No valid answer given. Models will NOT be pushed to Hugging Face Hub." && HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

# --- Start Training ---
echo_green ">> Good luck in the swarm!"
echo_blue ">> Post about rl-swarm on X/twitter! --> https://tinyurl.com/swarmtweet"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

echo_blue ">> Starting the main training process..."

# Use ORG_ID if Testnet was connected, otherwise use direct P2P args
if [ -n "$ORG_ID" ]; then
    echo_blue ">> Running trainer with Modal/Testnet configuration (ORG_ID: $ORG_ID)..."
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    echo_blue ">> Running trainer with direct P2P configuration..."
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

echo_green ">> Training process finished or was interrupted."
# The cleanup function will be called automatically on exit due to the trap

wait # Keep script potentially running if python command was backgrounded (though it isn't here)
# If python runs in foreground, script ends when python ends, triggering cleanup.
