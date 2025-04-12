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

# Hardcoded ngrok token
NGROK_TOKEN="2vUzlOzoWHKs25fsh1PvRB4yeND_3erVdiAizJxNP5XLtVaBo"

cleanup() {
    echo -e "${YELLOW}${BOLD}[✓] Shutting down processes...${NC}"
    kill $SERVER_PID 2>/dev/null || true
    kill $TUNNEL_PID 2>/dev/null || true
    # Ensure ngrok is killed if running detached
    pkill -f ngrok || true
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
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [ "$ARCH" = "x86_64" ]; then
        NGROK_ARCH="amd64"
        # CF_ARCH="amd64" # Removed Cloudflare arch
        echo -e "${GREEN}${BOLD}[✓] Detected x86_64 architecture.${NC}"
    elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        NGROK_ARCH="arm64"
        # CF_ARCH="arm64" # Removed Cloudflare arch
        echo -e "${GREEN}${BOLD}[✓] Detected ARM64 architecture.${NC}"
    elif [[ "$ARCH" == arm* ]]; then
        NGROK_ARCH="arm"
        # CF_ARCH="arm" # Removed Cloudflare arch
        echo -e "${GREEN}${BOLD}[✓] Detected ARM architecture.${NC}"
    else
        echo -e "${RED}[✗] Unsupported architecture: $ARCH. Please use a supported system.${NC}"
        exit 1
    fi

    # --- Removed install_cloudflared() function ---

    install_ngrok() {
        local NGROK_CMD="ngrok"
        if command -v $NGROK_CMD >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}[✓] ngrok is already installed.${NC}"
            return 0
        fi

        # Check if ngrok exists in current directory (e.g., from previous failed move)
        if [ -x "./ngrok" ]; then
            echo -e "${GREEN}${BOLD}[✓] Found existing ngrok executable in current directory.${NC}"
            NGROK_CMD="./ngrok" # Use local ngrok
             # Try moving it again just in case
             if command -v sudo >/dev/null 2>&1; then
                sudo mv ./ngrok /usr/local/bin/ && NGROK_CMD="ngrok" || echo -e "${YELLOW}Could not move ./ngrok to /usr/local/bin. Using local copy.${NC}"
             elif [ -d "$HOME/bin" ] && [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
                 mv ./ngrok "$HOME/bin/" && NGROK_CMD="ngrok" || echo -e "${YELLOW}Could not move ./ngrok to $HOME/bin. Using local copy.${NC}"
             fi

             # Re-check if it's now in PATH
             if command -v ngrok >/dev/null 2>&1; then
                echo -e "${GREEN}[✓] ngrok is now available in PATH.${NC}"
                return 0
             else
                echo -e "${YELLOW}Will attempt to use ngrok from current directory: $NGROK_CMD${NC}"
                # Need to ensure subsequent commands use $NGROK_CMD
                return 0 # Allow execution from current dir
             fi

        fi


        echo -e "${YELLOW}${BOLD}[✓] Installing ngrok...${NC}"
        # Determine package type based on OS
        if [[ "$OS" == "linux" ]]; then
            NGROK_PKG_SUFFIX="linux-$NGROK_ARCH.tgz"
        elif [[ "$OS" == "darwin" ]]; then # macOS
            # Ngrok provides .zip for macOS usually
            if [[ "$NGROK_ARCH" == "amd64" ]]; then
                 NGROK_PKG_SUFFIX="darwin-amd64.zip"
            elif [[ "$NGROK_ARCH" == "arm64" ]]; then
                 NGROK_PKG_SUFFIX="darwin-arm64.zip"
            else
                 echo -e "${RED}[✗] Unsupported macOS architecture for ngrok: $NGROK_ARCH.${NC}"
                 return 1
            fi
        else
           echo -e "${RED}[✗] Unsupported OS for automatic ngrok install: $OS.${NC}"
           return 1
        fi

        NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-$NGROK_PKG_SUFFIX"
        DOWNLOAD_TARGET="ngrok-download" # Temporary name

        wget -q --show-progress "$NGROK_URL" -O "$DOWNLOAD_TARGET"
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}[✗] Failed to download ngrok.${NC}"
            rm -f "$DOWNLOAD_TARGET"
            return 1
        fi

        # Extract based on extension
        if [[ "$NGROK_PKG_SUFFIX" == *.tgz ]]; then
            tar -xzf "$DOWNLOAD_TARGET" ngrok # Assumes binary is named 'ngrok' inside
            EXTRACT_SUCCESS=$?
        elif [[ "$NGROK_PKG_SUFFIX" == *.zip ]]; then
             # Check if unzip is available
             if ! command -v unzip >/dev/null 2>&1; then
                echo -e "${RED}[✗] 'unzip' command not found. Please install it to extract ngrok.${NC}"
                rm -f "$DOWNLOAD_TARGET"
                return 1
             fi
             unzip -o "$DOWNLOAD_TARGET" ngrok # Overwrite if exists, assumes binary name
             EXTRACT_SUCCESS=$?
        else
             echo -e "${RED}[✗] Unknown package type for ngrok: $NGROK_PKG_SUFFIX${NC}"
             rm -f "$DOWNLOAD_TARGET"
             return 1
        fi

        rm -f "$DOWNLOAD_TARGET" # Clean up archive

        if [ $EXTRACT_SUCCESS -ne 0 ] || [ ! -f "ngrok" ]; then
            echo -e "${RED}${BOLD}[✗] Failed to extract ngrok.${NC}"
            return 1
        fi

        chmod +x ngrok

        # Attempt to move to PATH
        if command -v sudo >/dev/null 2>&1; then
          sudo mv ngrok /usr/local/bin/
        else
          if [ -d "$HOME/bin" ] && [[ ":$PATH:" == *":$HOME/bin:"* ]]; then
            mv ngrok "$HOME/bin/"
          else
             echo -e "${YELLOW}Could not move ngrok to /usr/local/bin or $HOME/bin. Please move 'ngrok' manually to your PATH.${NC}"
             # Keep ngrok in the current directory as a fallback
          fi
        fi

        # Check if move succeeded
        if command -v ngrok >/dev/null 2>&1; then
           echo -e "${GREEN}${BOLD}[✓] ngrok installed successfully.${NC}"
           return 0
        else
           if [ -x "./ngrok" ]; then
              echo -e "${YELLOW}ngrok installed to current directory. Will use ./ngrok${NC}"
              # Allow execution from current dir - the caller needs to handle ./ngrok vs ngrok
              return 0
           fi
           echo -e "${RED}${BOLD}[✗] Failed to install or move ngrok correctly.${NC}"
           return 1
        fi
    }

    # --- Restored ngrok URL helper functions ---
    get_url_from_method1() {
        # Check JSON log format first
        local url=$(grep -o '"url":"https://[^"]*' ngrok_output.log 2>/dev/null | head -n1 | cut -d'"' -f4)
        # Fallback to plain text format if JSON failed
        if [ -z "$url" ]; then
            url=$(grep -m 1 "Forwarding" ngrok_output.log 2>/dev/null | grep -o "https://[^ ]*")
        fi
        echo "$url"
    }

    get_url_from_method2() {
        local url=""
        # Try common ngrok API ports
        for try_port in 4040 4041 4042 4043 4044 4045; do
            # Check if port is listening before curling
            if nc -z localhost $try_port 2>/dev/null || lsof -i :$try_port > /dev/null 2>&1; then
                url=$(curl --silent --max-time 2 "http://localhost:$try_port/api/tunnels" | grep -o '"public_url":"https://[^"]*' | head -n1 | cut -d'"' -f4)
                if [ -n "$url" ]; then
                    break
                fi
            fi
        done
        echo "$url"
    }

    # Method 3 (plain log) is covered by fallback in method 1 now.
    # Method 4 (restart) is kept as a last resort.
    get_url_from_method4() {
        local NGROK_CMD_PATH="ngrok" # Default command
        if ! command -v ngrok >/dev/null 2>&1 && [ -x "./ngrok" ]; then
            NGROK_CMD_PATH="./ngrok" # Use local if global not found
        fi

        echo -e "${YELLOW}[!] Trying alternative ngrok start method...${NC}"
        # Ensure previous tunnel is killed
        if [ -n "$TUNNEL_PID" ]; then
            kill $TUNNEL_PID 2>/dev/null || true
            sleep 3 # Wait for port to free up
        fi

        # Start ngrok again, explicitly asking for JSON logs to a different file
        "$NGROK_CMD_PATH" http --region us --log=stdout --log-format=json "$PORT" > ngrok_output_alt.log 2>&1 &
        TUNNEL_PID=$!
        echo "[i] Waiting for alternative ngrok tunnel (PID: $TUNNEL_PID)..."
        sleep 10 # Give it more time to start

        # Try extracting from the new log file (JSON first)
        local url=$(grep -o '"url":"https://[^"]*' ngrok_output_alt.log 2>/dev/null | head -n1 | cut -d'"' -f4)

        # If JSON failed, try API method again on alternative ports
        if [ -z "$url" ]; then
             for check_port in $(seq 4040 4050); do
                 if nc -z localhost $check_port 2>/dev/null || lsof -i :$check_port > /dev/null 2>&1; then
                     api_url=$(curl --silent --max-time 2 "http://localhost:$check_port/api/tunnels" | grep -o '"public_url":"https://[^"]*' | head -n1 | cut -d'"' -f4)
                     if [ -n "$api_url" ]; then
                         url="$api_url"
                         break
                     fi
                 fi
             done
        fi
        echo "$url"
    }
    # --- End of restored helper functions ---

    start_tunnel() {
        local NGROK_CMD_PATH="ngrok" # Default command
        # Check if installation put ngrok in current dir instead of PATH
        if ! command -v ngrok >/dev/null 2>&1 && [ -x "./ngrok" ]; then
            NGROK_CMD_PATH="./ngrok" # Use local executable
            echo -e "${YELLOW}[!] Using ngrok executable from current directory: ${NGROK_CMD_PATH}${NC}"
        fi


        # --- Cloudflare logic completely removed ---

        if install_ngrok; then
            echo -e "\n${CYAN}${BOLD}[✓] Using pre-configured ngrok token for authentication...${NC}"
            # Kill any lingering ngrok processes
            pkill -f $NGROK_CMD_PATH || true
            sleep 2

            "$NGROK_CMD_PATH" authtoken "$NGROK_TOKEN" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}[✓] Successfully authenticated ngrok with the provided token!${NC}"
            else
                # Use >&2 to print errors to stderr
                echo -e "${RED}[✗] Ngrok authentication failed with the provided token.${NC}" >&2
                echo -e "${RED}[✗] Please ensure the token '$NGROK_TOKEN' is valid and active.${NC}" >&2
                return 1 # Exit function on auth failure
            fi

            echo -e "\n${CYAN}${BOLD}[✓] Starting ngrok tunnel...${NC}"
            # Start ngrok, try JSON logging first for easier parsing
            "$NGROK_CMD_PATH" http "$PORT" --log=stdout --log-format=json --log-level=info > ngrok_output.log 2>&1 &
            TUNNEL_PID=$!
            echo "[i] Waiting for ngrok tunnel (PID: $TUNNEL_PID)..."
            sleep 5 # Initial wait

            FORWARDING_URL="" # Initialize
            # Try primary extraction methods
            FORWARDING_URL=$(get_url_from_method1) # Tries JSON log then plain log
            if [ -z "$FORWARDING_URL" ]; then
                echo "[i] Method 1 failed, trying method 2 (API)..."
                FORWARDING_URL=$(get_url_from_method2) # Tries API
            fi

            # If still no URL, try the restart method as a last resort
            if [ -z "$FORWARDING_URL" ]; then
                 echo "[i] Method 2 failed, trying method 4 (restart)..."
                FORWARDING_URL=$(get_url_from_method4) # Tries restarting ngrok
            fi

            # Final check
            if [ -n "$FORWARDING_URL" ]; then
                echo -e "${GREEN}${BOLD}[✓] ngrok tunnel started successfully.${NC}"
                return 0 # Success
            else
                echo -e "${RED}${BOLD}[✗] Failed to extract URL from ngrok after multiple attempts.${NC}" >&2
                echo -e "${YELLOW}Check ngrok_output.log and ngrok_output_alt.log for errors.${NC}" >&2
                cat ngrok_output.log >&2 # Show primary log on failure
                if [ -f ngrok_output_alt.log ]; then
                  echo -e "\n--- Alt Log ---" >&2
                  cat ngrok_output_alt.log >&2
                fi
                # Ensure the tunnel process is killed if URL extraction failed
                if [ -n "$TUNNEL_PID" ]; then
                    kill $TUNNEL_PID 2>/dev/null || true
                    TUNNEL_PID=""
                fi
                return 1 # Failure
            fi
        else
            echo -e "${RED}${BOLD}[✗] Failed to install or find ngrok.${NC}" >&2
            return 1 # Failure, ngrok is the only option now
        fi
    }

    start_tunnel
    TUNNEL_START_STATUS=$? # Capture exit status

    if [ $TUNNEL_START_STATUS -eq 0 ] && [ -n "$FORWARDING_URL" ] ; then
        echo -e "${GREEN}${BOLD}[✓] Success! Please visit this website and log in using your email:${NC} ${CYAN}${BOLD}${FORWARDING_URL}${NC}"
    else
        echo -e "\n${RED}${BOLD}[✗] Failed to start the ngrok tunnel.${NC}"
        echo -e "${YELLOW}Please check the output above for errors (e.g., installation issues, authentication failure, network problems).${NC}"
        # Exit or handle failure appropriately
        cleanup # Clean up server process if tunnel failed
        exit 1
    fi

    cd .. # Go back to ROOT

    echo -e "\n${CYAN}${BOLD}[↻] Waiting for you to complete the login process via the ngrok URL...${NC}"
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        # Check if tunnel or server died while waiting
        if [ -n "$TUNNEL_PID" ] && ! kill -0 $TUNNEL_PID 2>/dev/null; then
             echo -e "${RED}${BOLD}[✗] ngrok tunnel process died while waiting for login.${NC}"
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
    # Clean up ngrok logs
    rm -f modal-login/ngrok_output.log modal-login/ngrok_output_alt.log
    # rm -f modal-login/cloudflared_output.log # Removed cloudflare log cleanup

    # Kill the tunnel process explicitly after login is complete
    if [ -n "$TUNNEL_PID" ]; then
        echo -e "${YELLOW}${BOLD}[✓] Shutting down ngrok tunnel...${NC}"
        kill $TUNNEL_PID 2>/dev/null || true
        # Sometimes ngrok needs a stronger kill
        pkill -f ngrok || true
    fi
     # Optionally kill the login server too if it's no longer needed
     if [ -n "$SERVER_PID" ]; then
        echo -e "${YELLOW}${BOLD}[✓] Shutting down login server...${NC}"
        kill $SERVER_PID 2>/dev/null || true
     fi


    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo -e "\n${CYAN}${BOLD}[✓] ORG_ID has been set to: $ORG_ID\n${NC}"

    # --- API Key Activation Check (Commented out as before, needs review if critical) ---
    # echo -e "${CYAN}${BOLD}[✓] Waiting for API key to become activated...${NC}"
    # while true; do
    #     STATUS=$(curl -s "http://localhost:$PORT/api/get-api-key-status?orgId=$ORG_ID")
    #     if [[ "$STATUS" == "activated" ]]; then
    #         echo -e "${GREEN}${BOLD}[✓] Success! API key is activated! Proceeding...\n${NC}"
    #         break
    #     else
    #         echo "[↻] Waiting for API key to be activated... Status: $STATUS"
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
        CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
        echo -e "${CYAN}${BOLD}[✓] Config file : ${BOLD}$CONFIG_PATH\n${NC}"
    fi
fi


# --- Hugging Face Token Handling (Remains automatic "No") ---
echo -e "\n${YELLOW}${BOLD}[!] Skipping Hugging Face Hub upload prompt. Models will NOT be pushed automatically.${NC}"
HUGGINGFACE_ACCESS_TOKEN="None"


# --- Start Training ---
echo -e "\n${GREEN}${BOLD}[✓] Good luck in the swarm! Your training session is about to begin.\n${NC}"
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

# Launch based on whether ORG_ID was found (modal login) or not
if [ -n "$ORG_ID" ]; then
    echo "[i] Launching training using Modal ORG_ID..."
    $PYTHON_EXECUTABLE -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    echo "[i] Launching training using direct P2P addresses (ORG_ID not found)..."
    $PYTHON_EXECUTABLE -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS" \
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

wait
echo -e "${GREEN}${BOLD}[✓] Training script finished.${NC}"

# Final cleanup trap might run here upon exit
