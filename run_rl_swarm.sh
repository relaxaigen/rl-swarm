#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when substituting.
# Pipeli nes return the exit status of the last command to exit with a non-zero status.
set -euo pipefail

# --- Configuration ---
ROOT=$PWD # Assuming the script is run from the project root

# Default values (can be overridden by environment variables)
DEFAULT_PUB_MULTI_ADDRS=""
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"

# Export or set variables with defaults
export PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}
export PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}
export HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}
export IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}
export CPU_ONLY=${CPU_ONLY:-""} # Will ignore GPUs if set to non-empty string
export HF_HUB_DOWNLOAD_TIMEOUT=${HF_HUB_DOWNLOAD_TIMEOUT:-120} # 2 minutes

# Script internal variables
CONNECT_TO_TESTNET="" # Will be set based on user input
ORG_ID=""             # Will be set if Testnet connection is successful
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # Script's own directory
NGROK_PID=""          # Store ngrok process ID
SERVER_PID=""         # Store local server process ID
NGROK_LOG_FILE="$ROOT_DIR/ngrok.log" # Path for ngrok log file

# --- Text Colors ---
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
YELLOW_TEXT="\033[33m"
RED_TEXT="\033[31m"
RESET_TEXT="\033[0m"

# --- Helper Functions ---
echo_green() { echo -e "${GREEN_TEXT}$1${RESET_TEXT}"; }
echo_blue() { echo -e "${BLUE_TEXT}$1${RESET_TEXT}"; }
echo_yellow() { echo -e "${YELLOW_TEXT}$1${RESET_TEXT}"; }
echo_red() { echo -e "${RED_TEXT}$1${RESET_TEXT}"; }

# --- Cleanup Function ---
# This function is called on script exit (normal or interrupted)
cleanup() {
    # Disable further traps to prevent recursion
    trap - EXIT INT TERM

    echo_green "\n>> Shutting down trainer..."

    # Remove modal credentials if they exist
    echo_yellow ">> Removing temporary login data..."
    rm -rf "$ROOT_DIR/modal-login/temp-data" 2> /dev/null || true # Remove the whole folder

    # Kill ngrok process if it was started
    if [ -n "$NGROK_PID" ]; then
        echo_yellow ">> Shutting down ngrok tunnel (PID: $NGROK_PID)..."
        if kill "$NGROK_PID" 2>/dev/null; then
            echo_yellow "   ngrok process killed."
        else
            echo_yellow "   ngrok process might have already exited."
        fi
        rm -f "$NGROK_LOG_FILE" 2>/dev/null || true # Clean up ngrok log file
    fi

    # Kill the local server process if it was started
    if [ -n "$SERVER_PID" ]; then
        echo_yellow ">> Shutting down local server (PID: $SERVER_PID)..."
        if kill "$SERVER_PID" 2>/dev/null; then
             echo_yellow "   Local server process killed."
        else
             echo_yellow "   Local server process might have already exited."
        fi
    fi

    # Kill all processes belonging to this script's process group as a fallback
    # Note: This might kill more than intended if not careful, but useful for stopping orphaned children.
    echo_yellow ">> Attempting to kill any remaining processes in group (final check)..."
    kill -- -$$ 2>/dev/null || true # Suppress errors if group is already gone

    echo_green ">> Cleanup complete."
}

# --- Trap Setup ---
# Execute the cleanup function on script exit, interrupt (Ctrl+C), or termination signal
trap cleanup EXIT INT TERM

# --- Script Start ---
echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF
echo -e "${RESET_TEXT}" # Reset color after banner

# --- Ask User: Connect to Testnet? ---
while true; do
    echo -en "${GREEN_TEXT}"
    read -p ">> Would you like to connect to the Testnet? (Requires ngrok & login) [Y/n] " yn
    echo -en "${RESET_TEXT}"
    yn=${yn:-Y} # Default to "Y" if the user presses Enter
    case $yn in
        [Yy]*) CONNECT_TO_TESTNET="True"; break ;;
        [Nn]*) CONNECT_TO_TESTNET="False"; break ;;
        *) echo_yellow ">>> Please answer yes (Y) or no (n)." ;;
    esac
done

# --- Testnet Setup Block ---
if [ "$CONNECT_TO_TESTNET" = "True" ]; then
    echo_blue ">> Initiating Testnet connection setup..."

    # 1. Check for ngrok
    echo_blue ">> [1/7] Checking for ngrok..."
    if ! command -v ngrok &> /dev/null; then
        echo_red "Error: 'ngrok' command not found."
        echo_yellow "Please install ngrok from https://ngrok.com/download"
        echo_yellow "Ensure the ngrok executable is in your system's PATH."
        exit 1
    else
        echo_green ">> ngrok found: $(command -v ngrok)"
    fi

    # 2. Get ngrok Authtoken and Configure
    echo_blue ">> [2/7] Configuring ngrok..."
    NGROK_AUTHTOKEN=""
    while [ -z "$NGROK_AUTHTOKEN" ]; do
        echo -en "${GREEN_TEXT}"
        read -p ">> Please enter your ngrok Authtoken (find it at https://dashboard.ngrok.com/get-started/your-authtoken): " NGROK_AUTHTOKEN
        echo -en "${RESET_TEXT}"
        if [ -z "$NGROK_AUTHTOKEN" ]; then
            echo_yellow ">>> Ngrok Authtoken cannot be empty. Please paste your token."
        fi
    done
    # Configure ngrok quietly. Show error only if configuration fails.
    if ! ngrok config add-authtoken "$NGROK_AUTHTOKEN" --log=stderr > /dev/null; then
        echo_red "Error: Failed to configure ngrok with the provided Authtoken."
        echo_yellow "Please verify your token and try again."
        exit 1
    fi
    echo_green ">> ngrok configured successfully."

    # 3. Setup Node.js/Yarn Environment
    echo_blue ">> [3/7] Setting up Node.js & Yarn environment..."
    cd "$ROOT_DIR/modal-login" || { echo_red "Error: Could not change directory to modal-login."; exit 1; }

    # Ensure necessary env vars are loaded (especially for NVM)
    source ~/.bashrc 2>/dev/null || true # Source bashrc if it exists
    source ~/.zshrc 2>/dev/null || true   # Source zshrc if it exists

    # Node.js + NVM setup
    if ! command -v node >/dev/null 2>&1; then
        echo_yellow "Node.js not found. Attempting to install NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
             echo_blue "Installing NVM..."
             # Suppress NVM install script output unless there's an error
             if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash > /dev/null; then
                 echo_red "Error installing NVM. Please install it manually."
                 exit 1
             fi
        fi
         # Source NVM script for current session *after* potential installation
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" || { echo_red "Error sourcing NVM script. Please check NVM installation."; exit 1; }
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

        echo_blue "Installing latest Node.js LTS via NVM..."
        if ! nvm install --lts; then
            echo_red "Error installing Node.js via NVM. Please install Node.js manually."
            exit 1
        fi
        # Re-source NVM script after installation to ensure 'node' command is available *now*
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        echo_green ">> Node.js installed: $(node -v)"
    else
        echo_green ">> Node.js found: $(node -v)"
    fi

    # Yarn setup
    if ! command -v yarn > /dev/null 2>&1; then
        echo_yellow "Yarn not found. Attempting to install Yarn..."
        if command -v npm > /dev/null 2>&1; then
            echo_blue "Installing Yarn globally using npm..."
            # Use sudo only if necessary (check if current user can write to global node_modules)
             # Simple check: try creating a temp dir where global modules might live
            GLOBAL_NODE_MODULES=$(npm root -g 2>/dev/null || echo "$HOME/.node_modules_global") # Estimate path
            if [ ! -w "$(dirname "$GLOBAL_NODE_MODULES")" ]; then
                echo_yellow "Attempting installation with sudo as global node modules directory might not be writable..."
                if ! sudo npm install --global yarn; then
                     echo_red "Error installing Yarn with sudo npm. Please install Yarn manually (https://yarnpkg.com/getting-started/install) and ensure it's in your PATH."
                     exit 1
                fi
            else
                 if ! npm install --global yarn; then
                     echo_red "Error installing Yarn with npm. Please install Yarn manually (https://yarnpkg.com/getting-started/install) and ensure it's in your PATH."
                     exit 1
                 fi
            fi
        else
             echo_red "Error: npm (Node Package Manager) is required to install Yarn automatically, but npm was not found."
             echo_yellow "Please install Node.js (which includes npm) or install Yarn manually (https://yarnpkg.com/getting-started/install)."
             exit 1
        fi
        # Check again if yarn is now available
        if ! command -v yarn > /dev/null 2>&1; then
             echo_red "Error: Yarn installation attempted, but 'yarn' command is still not found. Check your PATH or install manually."
             exit 1
        fi
        echo_green ">> Yarn installed: $(yarn --version)"
    else
        echo_green ">> Yarn found: $(yarn --version)"
    fi

    # 4. Install Dependencies and Start Local Server
    echo_blue ">> [4/7] Installing login server dependencies..."
    if ! yarn install --silent; then # Use --silent for less verbose output
        echo_red "Error: 'yarn install' failed. Please check for errors above."
        exit 1
    fi
    echo_green ">> Dependencies installed."

    echo_blue ">> Starting local authentication server (yarn dev)..."
    # Run in background, redirect stdout/stderr to /dev/null
    yarn dev > /dev/null 2>&1 &
    SERVER_PID=$! # Store the process ID
    # Basic check if process started (PID exists)
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo_red "Error: Failed to start the local server (yarn dev). Check 'modal-login' directory for issues."
        SERVER_PID="" # Unset PID as it's invalid
        exit 1
    fi
    echo_green ">> Started local server process (PID: $SERVER_PID)."
    echo_blue ">> Waiting for local server to initialize..."
    sleep 5 # Give server time to start listening

    # 5. Start Ngrok Tunnel
    echo_blue ">> [5/7] Starting ngrok tunnel for http://localhost:3000..."
    rm -f "$NGROK_LOG_FILE" # Remove old log file if exists
    # Start ngrok in background, logging to file, targeting the local server port
    ngrok http 3000 --log "$NGROK_LOG_FILE" &
    NGROK_PID=$! # Store ngrok process ID
    # Basic check if process started
    if ! kill -0 "$NGROK_PID" 2>/dev/null; then
        echo_red "Error: Failed to start the ngrok process."
        echo_yellow "Check if another ngrok process is running or if there are issues with your ngrok installation/configuration."
        NGROK_PID="" # Unset PID
        exit 1
    fi
    echo_green ">> Started ngrok process (PID: $NGROK_PID)."

    # 6. Get Ngrok URL and Wait for Login
    echo_blue ">> [6/7] Waiting for ngrok tunnel URL and user login..."
    NGROK_URL=""
    echo_yellow ">> Fetching ngrok public URL (up to 30 seconds)..."
    for i in {1..15}; do # 15 attempts * 2 seconds = 30 seconds timeout
        # Method 1: Try ngrok API (more reliable)
        NGROK_URL=$(curl --silent --max-time 1.5 http://127.0.0.1:4040/api/tunnels | grep -o '"public_url":"https://[^"]*' | cut -d'"' -f4 | head -n 1)

        # Method 2: Fallback to parsing log file (if API fails or is slow)
        if [ -z "$NGROK_URL" ] && [ -f "$NGROK_LOG_FILE" ]; then
            # Look for lines like 'url=https://....ngrok...' or 'URL:https://....ngrok...'
            # Prioritize https URLs
            NGROK_URL=$(grep -Eo 'url=(https://[a-zA-Z0-9.-]+\.ngrok[-a-z.]+)' "$NGROK_LOG_FILE" | head -n 1 | cut -d'=' -f2)
        fi

        if [ -n "$NGROK_URL" ]; then
            echo_green ">> Ngrok tunnel URL obtained!"
            break # Exit loop if URL found
        fi
        echo_yellow "   Still waiting for ngrok URL... (${i}/15)"
        sleep 2
    done

    if [ -z "$NGROK_URL" ]; then
        echo_red "Error: Could not get ngrok tunnel URL after 30 seconds."
        echo_yellow "Troubleshooting steps:"
        echo_yellow "  1. Check your internet connection."
        echo_yellow "  2. Manually run 'ngrok http 3000' in another terminal to see errors."
        echo_yellow "  3. Check the ngrok log file: $NGROK_LOG_FILE"
        exit 1 # Exit after cleanup (handled by trap)
    fi

    echo_blue "************************************************************************"
    echo_blue "* ACTION REQUIRED: Please open the following URL in your web browser   *"
    echo_blue "*                 to log in and authorize the connection:              *"
    echo_blue "*                                                                      *"
    echo_green "*   ${NGROK_URL}                                                        *"
    echo_blue "*                                                                      *"
    echo_blue "* Waiting for you to complete the login process...                     *"
    echo_blue "************************************************************************"

    # Wait for userData.json to be created by the login process
    USER_DATA_FILE="$ROOT_DIR/modal-login/temp-data/userData.json"
    while [ ! -f "$USER_DATA_FILE" ]; do
        echo_yellow "   Waiting for login confirmation (checking for '$USER_DATA_FILE')..."
        sleep 5 # Check every 5 seconds
    done
    echo_green ">> Login detected! Found '$USER_DATA_FILE'."

    # Extract ORG_ID from JSON (using awk for simplicity, jq is more robust if available)
    # This awk command looks for a line containing "orgId", splits by quotes, and prints the second-to-last field.
    ORG_ID=$(awk 'BEGIN { FS = "\"" } /"orgId"/ { if (NF >= 4) print $(NF - 1); exit }' "$USER_DATA_FILE")

    if [ -z "$ORG_ID" ]; then
        echo_red "Error: Could not extract ORG_ID from '$USER_DATA_FILE'."
        echo_yellow "File content:"
        cat "$USER_DATA_FILE" || echo "(Could not read file)"
        exit 1
    fi
    echo_green ">> Your ORG_ID is set to: $ORG_ID"

    # 7. Wait for API Key Activation
    echo_blue ">> [7/7] Waiting for API key activation via local server..."
    ACTIVATION_URL="http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID"
    MAX_ACTIVATION_ATTEMPTS=24 # 24 * 5 seconds = 2 minutes timeout
    for (( i=1; i<=MAX_ACTIVATION_ATTEMPTS; i++ )); do
        # Use curl with silent (-s), fail fast (-f), and max time (-m) options
        STATUS=$(curl -s -f -m 4 "$ACTIVATION_URL" || echo "error") # Get status or "error"
        if [[ "$STATUS" == "activated" ]]; then
            echo_green ">> API key is activated! Proceeding..."
            break # Exit loop on success
        elif [[ "$STATUS" == "error" ]]; then
             echo_yellow "   Waiting for API key activation... (Attempt $i/$MAX_ACTIVATION_ATTEMPTS - Could not reach local server at $ACTIVATION_URL)"
        else
            echo_yellow "   Waiting for API key activation... (Attempt $i/$MAX_ACTIVATION_ATTEMPTS - Status: '$STATUS')"
        fi

        if [ "$i" -eq "$MAX_ACTIVATION_ATTEMPTS" ]; then
            echo_red "Error: API key did not activate within the timeout period (2 minutes)."
            echo_yellow "Please check the Gensyn dashboard or support channels."
            exit 1
        fi
        sleep 5
    done

    cd "$ROOT" # Go back to the original root directory
    echo_green ">> Testnet setup completed successfully."

else
    echo_blue ">> Skipping Testnet connection setup as requested."
    # ORG_ID remains empty in this case
fi # End of CONNECT_TO_TESTNET block

# --- Python Environment and Requirements ---
echo_blue ">> Setting up Python environment and installing requirements..."

pip_install() {
    echo_blue ">> Installing requirements from: $1"
    # Use -q for quiet, add --no-warn-script-location to reduce noise
    if ! pip install --disable-pip-version-check --no-warn-script-location -q -r "$1"; then
         echo_red "Error: Failed to install requirements from '$1'. Please check pip and the requirements file."
         exit 1
    fi
     echo_green ">> Successfully installed requirements from $1"
}

# Install common requirements first
pip_install "$ROOT/requirements-hivemind.txt"
pip_install "$ROOT/requirements.txt"

# Determine config path and install GPU reqs if needed
CONFIG_PATH=""
if ! command -v nvidia-smi &> /dev/null; then
    echo_yellow ">> No NVIDIA GPU detected or 'nvidia-smi' not found. Using CPU configuration."
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
elif [ -n "$CPU_ONLY" ]; then
    echo_yellow ">> CPU_ONLY flag is set. Using CPU configuration."
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
    echo_green ">> NVIDIA GPU detected. Installing GPU-specific requirements..."
    pip_install "$ROOT/requirements_gpu.txt"
    CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    echo_green ">> Using GPU configuration."
fi

if [ ! -f "$CONFIG_PATH" ]; then
    echo_red "Error: Configuration file not found at '$CONFIG_PATH'."
    exit 1
fi
echo_green ">> Configuration file set to: $CONFIG_PATH"
echo_green ">> Requirements installation complete."

# --- Hugging Face Token ---
echo_blue ">> Checking Hugging Face Hub integration..."
HF_TOKEN=${HF_TOKEN:-""} # Check environment variable first
HUGGINGFACE_ACCESS_TOKEN="None" # Default to None

if [ -n "${HF_TOKEN}" ]; then
    echo_green ">> Using Hugging Face token from HF_TOKEN environment variable."
    HUGGINGFACE_ACCESS_TOKEN="${HF_TOKEN}"
else
    echo -en "${GREEN_TEXT}"
    read -p ">> Would you like to push trained models to the Hugging Face Hub? [y/N] " yn_hf
    echo -en "${RESET_TEXT}"
    yn_hf=${yn_hf:-N} # Default to "N"
    case $yn_hf in
        [Yy]*)
             echo -en "${YELLOW_TEXT}"
             # Use -s for silent input for the token
             read -sp ">>> Enter your Hugging Face access token (needs 'write' permission): " HUGGINGFACE_ACCESS_TOKEN_INPUT
             echo # Print a newline after silent input
             echo -en "${RESET_TEXT}"
             if [ -z "$HUGGINGFACE_ACCESS_TOKEN_INPUT" ]; then
                 echo_yellow ">>> No token entered. Models will NOT be pushed."
                 HUGGINGFACE_ACCESS_TOKEN="None"
             else
                 HUGGINGFACE_ACCESS_TOKEN="$HUGGINGFACE_ACCESS_TOKEN_INPUT"
                 echo_green ">> Hugging Face token received. Models will be pushed if training is successful."
             fi
             ;;
        [Nn]*)
             echo_blue ">> Models will NOT be pushed to Hugging Face Hub."
             HUGGINGFACE_ACCESS_TOKEN="None"
             ;;
        *)
             echo_yellow ">>> Invalid input. Models will NOT be pushed to Hugging Face Hub."
             HUGGINGFACE_ACCESS_TOKEN="None"
             ;;
    esac
fi

# --- Start Training ---
echo_green ">> All setup complete. Starting the training process..."
echo_blue ">> Good luck in the swarm! Remember to star the repo: https://github.com/gensyn-ai/rl-swarm"
echo_blue ">> Follow updates on X/Twitter: https://tinyurl.com/swarmtweet"

# Prepare arguments for the python script
PYTHON_ARGS=(
    -m hivemind_exp.gsm8k.train_single_gpu
    --hf_token "$HUGGINGFACE_ACCESS_TOKEN"
    --identity_path "$IDENTITY_PATH"
    --config "$CONFIG_PATH"
)

# Add arguments based on whether we connected to Testnet or not
if [ -n "$ORG_ID" ]; then
    echo_blue ">> Running trainer with Testnet configuration (using ORG_ID: $ORG_ID)..."
    PYTHON_ARGS+=(--modal_org_id "$ORG_ID")
else
    echo_blue ">> Running trainer with direct P2P configuration..."
    PYTHON_ARGS+=(
        --public_maddr "$PUB_MULTI_ADDRS"
        --initial_peers "$PEER_MULTI_ADDRS"
        --host_maddr "$HOST_MULTI_ADDRS"
    )
fi

# Execute the python script
echo_blue ">> Executing command: python ${PYTHON_ARGS[*]}"
if ! python "${PYTHON_ARGS[@]}"; then
    echo_red "Error: The Python training script exited with a non-zero status."
    # Cleanup will run automatically due to the trap on EXIT
    exit 1 # Ensure script exits with error status
fi

echo_green ">> Python training script finished successfully."
# Cleanup will run automatically due to the trap on EXIT
exit 0 # Explicitly exit with success status
