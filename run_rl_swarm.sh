#!/bin/bash

ROOT=$PWD

RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;95m'
BLUE='\033[0;94m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120

DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] Shutting down processes...${NC}"
    kill $SERVER_PID 2>/dev/null || true
    kill $TUNNEL_PID 2>/dev/null || true
    exit 0
}

trap cleanup INT

# --- Start: Check for existing login ---
if [ -f "modal-login/temp-data/userData.json" ]; then
    cd modal-login

    echo -e "\n${CYAN}${BOLD}[✓] Installing dependencies with npm. This may take a few minutes, depending on your internet speed...${NC}"
    npm install --legacy-peer-deps > /dev/null 2>&1

    echo -e "\n${CYAN}${BOLD}[✓] Starting the development server...${NC}"
    pid=$(lsof -ti:3000); if [ -n "$pid" ]; then kill -9 $pid; fi
    sleep 3
    npm run dev > server.log 2>&1 &
    SERVER_PID=$!
    MAX_WAIT=60
    PORT="" # Initialize PORT
    for ((i = 0; i < MAX_WAIT; i++)); do
        if grep -q "Local:        http://localhost:" server.log; then
            PORT=$(grep "Local:        http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p')
            if [ -n "$PORT" ]; then
                echo -e "${GREEN}${BOLD}[✓] Server is running successfully on port $PORT.${NC}"
                break
            fi
        fi
        sleep 1
    done

    if [ $i -eq $MAX_WAIT ] || [ -z "$PORT" ]; then
        echo -e "${RED}${BOLD}[✗] Timeout or error waiting for server to start.${NC}"
        cat server.log # Show log on error
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    cd ..

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}${BOLD}[✓] ORG_ID has been set to: ${BOLD}$ORG_ID\n${NC}"
# --- End: Check for existing login ---
else
# --- Start: New login process ---
    cd modal-login

    echo -e "\n${CYAN}${BOLD}[✓] Installing dependencies with npm. This may take a few minutes, depending on your internet speed...${NC}"
    npm install --legacy-peer-deps > /dev/null 2>&1

    echo -e "\n${CYAN}${BOLD}[✓] Starting the development server...${NC}"
    pid=$(lsof -ti:3000); if [ -n "$pid" ]; then kill -9 $pid; fi
    sleep 3
    npm run dev > server.log 2>&1 &
    SERVER_PID=$!
    MAX_WAIT=60
    PORT="" # Initialize PORT
    for ((i = 0; i < MAX_WAIT; i++)); do
        if grep -q "Local:        http://localhost:" server.log; then
            PORT=$(grep "Local:        http://localhost:" server.log | sed -n 's/.*http:\/\/localhost:\([0-9]*\).*/\1/p')
            if [ -n "$PORT" ]; then
                echo -e "${GREEN}${BOLD}[✓] Server is running successfully on port $PORT.${NC}"
                break
            fi
        fi
        sleep 1
    done

    if [ $i -eq $MAX_WAIT ] || [ -z "$PORT" ]; then
        echo -e "${RED}${BOLD}[✗] Timeout or error waiting for server to start.${NC}"
        cat server.log # Show log on error
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi

    echo -e "\n${CYAN}${BOLD}[✓] Detecting system architecture...${NC}"
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]') # OS needed for Cloudflared download check later
    if [ "$ARCH" = "x86_64" ]; then
        # NGROK_ARCH="amd64" # Not needed anymore
        CF_ARCH="amd64"
        echo -e "${GREEN}${BOLD}[✓] Detected x86_64 architecture.${NC}"
    elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        # NGROK_ARCH="arm64" # Not needed anymore
        CF_ARCH="arm64"
        echo -e "${GREEN}${BOLD}[✓] Detected ARM64 architecture.${NC}"
    elif [[ "$ARCH" == arm* ]]; then
        # NGROK_ARCH="arm" # Not needed anymore
        CF_ARCH="arm"
        echo -e "${GREEN}${BOLD}[✓] Detected ARM architecture.${NC}"
    else
        echo -e "${RED}[✗] Unsupported architecture: $ARCH. Please use a supported system.${NC}"
        exit 1
    fi

    install_cloudflared() {
        if command -v cloudflared >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}[✓] Cloudflared is already installed.${NC}"
            return 0
        fi
        echo -e "\n${YELLOW}${BOLD}[✓] Installing cloudflared...${NC}"
        # Determine package type based on OS
        if [[ "$OS" == "linux" ]]; then
          CF_PKG_SUFFIX="linux-$CF_ARCH"
        elif [[ "$OS" == "darwin" ]]; then # macOS
          CF_PKG_SUFFIX="darwin-$CF_ARCH.tgz" # Requires different handling if it's tgz
          echo -e "${YELLOW}Attempting macOS Cloudflared install (experimental)...${NC}"
          # Add specific macOS install logic here if needed, like using brew or handling .tgz
          # For now, assuming direct binary download similar to Linux
          # Need to check if macOS releases use .tgz or direct binary
          # Let's assume direct binary for now, adjust if needed
          CF_PKG_SUFFIX="darwin-$CF_ARCH" # Adjust if it's actually .tgz
        else
           echo -e "${RED}[✗] Unsupported OS for automatic Cloudflared install: $OS.${NC}"
           return 1
        fi

        CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$CF_PKG_SUFFIX"
        DOWNLOAD_TARGET="cloudflared"
        # Handle .tgz for macOS if needed
        # if [[ "$CF_PKG_SUFFIX" == *.tgz ]]; then
        #    DOWNLOAD_TARGET="cloudflared.tgz"
        # fi

        wget -q --show-progress "$CF_URL" -O "$DOWNLOAD_TARGET"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}[✗] Failed to download cloudflared.${NC}"
            rm -f "$DOWNLOAD_TARGET" # Clean up failed download
            return 1
        fi

        # Handle extraction if it was a tgz
        # if [[ "$DOWNLOAD_TARGET" == *.tgz ]]; then
        #    tar -xzf "$DOWNLOAD_TARGET" cloudflared # Assuming binary is named 'cloudflared' inside
        #    if [ $? -ne 0 ]; then
        #        echo -e "${RED}${BOLD}[✗] Failed to extract cloudflared.${NC}"
        #        rm "$DOWNLOAD_TARGET"
        #        return 1
        #    fi
        #    rm "$DOWNLOAD_TARGET" # Remove archive after extraction
        # fi

        chmod +x cloudflared
        # Use sudo only if needed and available
        if command -v sudo >/dev/null 2>&1; then
          sudo mv cloudflared /usr/local/bin/
        else
          # Try moving to a directory in PATH without sudo (e.g., ~/bin if it exists and is in PATH)
          if [ -d "$HOME/bin" ] && [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
            mv cloudflared "$HOME/bin/"
          else
             echo -e "${YELLOW}Could not move cloudflared to /usr/local/bin (sudo not found/failed)."
             echo -e "Please move the 'cloudflared' binary in the current directory to a location in your PATH.${NC}"
             # Keep cloudflared in the current directory as a fallback
          fi

        fi

        # Check if move succeeded by checking command availability again
        if command -v cloudflared >/dev/null 2>&1; then
           echo -e "${GREEN}${BOLD}[✓] Cloudflared installed successfully.${NC}"
           return 0
        else
           echo -e "${RED}${BOLD}[✗] Failed to move cloudflared to a directory in PATH.${NC}"
           # If it wasn't moved but exists locally, maybe we can still run it with ./cloudflared
           if [ -x "./cloudflared" ]; then
              echo -e "${YELLOW}Will try running cloudflared from the current directory.${NC}"
              return 0 # Allow execution from current dir
           fi
           return 1
        fi
    }

    # --- Ngrok related functions removed ---
    # install_ngrok() { ... }
    # get_url_from_method1() { ... }
    # get_url_from_method2() { ... }
    # get_url_from_method3() { ... }
    # get_url_from_method4() { ... }
    # --- End of removed Ngrok functions ---

    start_tunnel() {
        local CLOUDFLARED_CMD="cloudflared"
        # Check if installed globally, if not, try local path
        if ! command -v cloudflared >/dev/null 2>&1 && [ -x "./cloudflared" ]; then
            CLOUDFLARED_CMD="./cloudflared"
        fi

        if install_cloudflared; then
            echo -e "\n${CYAN}${BOLD}[✓] Starting cloudflared tunnel...${NC}"
            # Use the determined command path
            "$CLOUDFLARED_CMD" tunnel --url http://localhost:$PORT > cloudflared_output.log 2>&1 &
            TUNNEL_PID=$!
            counter=0
            MAX_WAIT=30 # Reduced wait time, Cloudflare is usually fast
            FORWARDING_URL="" # Initialize
            while [ $counter -lt $MAX_WAIT ]; do
                FORWARDING_URL=$(grep -o 'https://[^ ]*\.trycloudflare.com' cloudflared_output.log | head -n1)
                if [ -n "$FORWARDING_URL" ]; then
                    echo -e "${GREEN}${BOLD}[✓] Cloudflared tunnel started successfully.\n${NC}"
                    return 0 # Success
                fi
                # Check if cloudflared process exited prematurely
                if ! kill -0 $TUNNEL_PID 2>/dev/null; then
                    echo -e "${RED}${BOLD}[✗] Cloudflared process exited unexpectedly.${NC}"
                    cat cloudflared_output.log # Show log on error
                    TUNNEL_PID="" # Clear PID as it's dead
                    return 1 # Failure
                fi
                sleep 1
                counter=$((counter + 1))
            done

            # If loop finished without finding URL
            echo -e "${RED}${BOLD}[✗] Timeout waiting for cloudflared URL.${NC}"
            cat cloudflared_output.log # Show log on error
            kill $TUNNEL_PID 2>/dev/null || true # Attempt cleanup
            TUNNEL_PID=""
            return 1 # Failure
        else
            echo -e "\n${RED}${BOLD}[✗] Failed to install or run cloudflared.${NC}"
            return 1 # Failure, as Cloudflare is the only option now
        fi
        # --- Ngrok fallback logic removed ---
    }

    start_tunnel
    if [ $? -eq 0 ] && [ -n "$FORWARDING_URL" ] ; then
        echo -e "${GREEN}${BOLD}[✓] Success! Please visit this website and log in using your email:${NC} ${CYAN}${BOLD}${FORWARDING_URL}${NC}"
    else
        echo -e "\n${RED}${BOLD}[✗] Failed to start the Cloudflared tunnel.${NC}"
        echo -e "${YELLOW}Please check the output above for errors (e.g., installation issues, network problems)."
        echo -e "You might need to install 'cloudflared' manually and ensure it can connect.${NC}"
        # Exit or handle failure appropriately
        cleanup # Clean up server process if tunnel failed
        exit 1
    fi

    cd .. # Go back to ROOT

    echo -e "\n${CYAN}${BOLD}[↻] Waiting for you to complete the login process via the Cloudflare URL...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        # Check if tunnel or server died while waiting
        if [ -n "$TUNNEL_PID" ] && ! kill -0 $TUNNEL_PID 2>/dev/null; then
             echo -e "${RED}${BOLD}[✗] Tunnel process died while waiting for login.${NC}"
             cleanup
             exit 1
        fi
        if [ -n "$SERVER_PID" ] && ! kill -0 $SERVER_PID 2>/dev/null; then
             echo -e "${RED}${BOLD}[✗] Login server process died while waiting for login.${NC}"
             cleanup
             exit 1
        fi
        sleep 3
    done

    echo -e "${GREEN}${BOLD}[✓] Success! The userData.json file has been created. Proceeding with remaining setups...${NC}"
    # Clean up logs (keep server.log for potential debugging if needed, remove tunnel logs)
    rm -f modal-login/cloudflared_output.log # Adjusted path
    # rm -f modal-login/ngrok_output.log modal-login/ngrok_output_alt.log # Removed ngrok logs cleanup

    # Kill the tunnel process explicitly after login is complete
    if [ -n "$TUNNEL_PID" ]; then
        echo -e "${YELLOW}${BOLD}[✓] Shutting down Cloudflare tunnel...${NC}"
        kill $TUNNEL_PID 2>/dev/null || true
    fi
     # Optionally kill the login server too if it's no longer needed
     if [ -n "$SERVER_PID" ]; then
        echo -e "${YELLOW}${BOLD}[✓] Shutting down login server...${NC}"
        kill $SERVER_PID 2>/dev/null || true
     fi


    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}${BOLD}[✓] ORG_ID has been set to: $ORG_ID\n${NC}"

    # --- API Key Activation Check ---
    # Need the server running for this check. Restart it briefly or keep it running until here?
    # Let's assume the check needs the server. We killed it above, so let's restart it if needed.
    # OR: Maybe the API key check isn't strictly necessary or done differently now.
    # For now, commenting out the API check as the server was killed. If it's essential,
    # the server/tunnel shutdown logic needs adjustment.

    # echo -e "${CYAN}${BOLD}[✓] Waiting for API key to become activated...${NC}"
    # # Need to ensure server is running on $PORT again if killed previously
    # # This part might need rethinking depending on whether the API check is mandatory
    # while true; do
    #     STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
    #     if [[ "$STATUS" == "activated" ]]; then
    #         echo -e "${GREEN}${BOLD}[✓] Success! API key is activated! Proceeding...\n${NC}"
    #         break
    #     else
    #         echo "[↻] Waiting for API key to be activated... Status: $STATUS" # Added status for debug
    #         sleep 5
    #     fi
    # done

# --- End: New login process ---
fi

echo -e "${CYAN}${BOLD}[✓] Installing required Python packages, may take few mins depending on your internet speed...${NC}"
pip install --disable-pip-version-check -q -r "$ROOT"/requirements-hivemind.txt #> /dev/null
pip install --disable-pip-version-check -q -r "$ROOT"/requirements.txt #> /dev/null

echo -e "${GREEN}${BOLD}>>> Awesome, All packages installed successfully!\n${NC}"

# --- Config Path selection (GPU/CPU) ---
if [ -z "$CONFIG_PATH" ]; then
    if command -v nvidia-smi &> /dev/null || [ -d "/proc/driver/nvidia" ]; then
        echo -e "${GREEN}${BOLD}[✓] GPU detected, using GPU configuration${NC}"
        CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
        echo -e "${CYAN}${BOLD}[✓] Config file : ${BOLD}$CONFIG_PATH\n${NC}"
        echo -e "${CYAN}${BOLD}[✓] Installing GPU-specific requirements, may take few mins depending on your internet speed...${NC}"
        pip install --disable-pip-version-check -q -r "$ROOT"/requirements_gpu.txt #> /dev/null
    else
        echo -e "${YELLOW}${BOLD}[✓] No GPU detected, using CPU configuration${NC}"
        # Assuming the mac config is the intended CPU fallback
        CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
        echo -e "${CYAN}${BOLD}[✓] Config file : ${BOLD}$CONFIG_PATH\n${NC}"
    fi
fi


# --- Hugging Face Token Handling ---
# Automatically set to "No" (None) without prompting
echo -e "\n${YELLOW}${BOLD}[!] Skipping Hugging Face Hub upload prompt. Models will NOT be pushed automatically.${NC}"
HUGGINGFACE_ACCESS_TOKEN="None"
# The following block is removed/commented out:
# if [ -n "${HF_TOKEN}" ]; then
#     HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
# else
#     read -p "Would you like to push models you train in the RL swarm to the Hugging Face Hub? [y/N] " yn
#     yn=${yn:-N}
#     case $yn in
#         [Yy]* ) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN;;
#         [Nn]* ) HUGGINGFACE_ACCESS_TOKEN="None";;
#         * ) echo -e "${YELLOW}>>> No answer was given, so NO models will be pushed to the Hugging Face Hub.${NC}" && HUGGINGFACE_ACCESS_TOKEN="None";;
#     esac
# fi


# --- Start Training ---
echo -e "\n${GREEN}${BOLD}[✓] Good luck in the swarm! Your training session is about to begin.\n${NC}"
# Adjust Hivemind P2P timeout (original logic kept)
PYTHON_EXECUTABLE=$(command -v python3 || command -v python)
if [ -n "$PYTHON_EXECUTABLE" ]; then
  HIVEP2P_PATH=$($PYTHON_EXECUTABLE -c "import sys; import os; import hivemind.p2p.p2p_daemon as m; print(os.path.realpath(m.__file__)); sys.exit(0)")
  if [ -f "$HIVEP2P_PATH" ]; then
      echo -e "${CYAN}[✓] Adjusting Hivemind P2P startup timeout...${NC}"
      if [ "$(uname)" = "Darwin" ]; then
          sed -i '' -E 's/(startup_timeout: *float *= *)[0-9.]+/\1120.0/' "$HIVEP2P_PATH"
      else
          sed -i -E 's/(startup_timeout: *float *= *)[0-9.]+/\1120.0/' "$HIVEP2P_PATH"
      fi
  else
      echo -e "${YELLOW}[!] Warning: Could not find hivemind.p2p.p2p_daemon module file to adjust timeout.${NC}"
  fi
else
    echo -e "${YELLOW}[!] Warning: Python executable not found. Cannot adjust Hivemind P2P timeout.${NC}"
fi
sleep 2

# Launch based on whether ORG_ID was found (modal login) or not (direct p2p)
if [ -n "$ORG_ID" ]; then
    echo "[i] Launching training using Modal ORG_ID..."
    $PYTHON_EXECUTABLE -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    # This case should ideally not happen if the script forces modal login,
    # but keeping it for robustness or alternative use cases.
    echo "[i] Launching training using direct P2P addresses (ORG_ID not found)..."
    $PYTHON_EXECUTABLE -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

wait # Keep script alive if python runs in background (though it doesn't seem to here)
echo -e "${GREEN}${BOLD}[✓] Training script finished.${NC}"
