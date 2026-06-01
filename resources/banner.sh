#!/bin/bash
# Standard colors mapped to 8-bit equivalents
ORANGE='\033[38;5;208m'
BLUE='\033[38;5;12m'
ERROR_RED='\033[38;5;9m'
LITE_GREEN='\033[38;5;10m'
NAVY_BLUE='\033[38;5;18m'
TANGERINE='\033[38;5;208m'
GREEN='\033[38;5;2m'
SEA_GREEN='\033[38;5;74m'
FOREST_GREEN='\033[38;5;34m'
ASH_GRAY='\033[38;5;250m'
NC='\033[0m'
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P)
# Constants
BUILD_TIMESTAMP_FILE="/usr/local/bin/build-timestamp.txt"
BUILD_TIMESTAMP=$(cat "$BUILD_TIMESTAMP_FILE" 2>/dev/null || echo "")

# Function to print separator line
print_separator() {
    printf "\n"
    printf "\n______________________________________________________________________________________________________________________________________________"
    printf "\n"
}

# Print ASCII art
print_ascii_art() {
    printf "${NAVY_BLUE}    /SSSSSS  /SS   /SS     /SS   /SS                                                /SSSSSS                                                      ${NC}\n"
    printf "${NAVY_BLUE}   /SS__  SS|__/  | SS    | SSS | SS                                               /SS__  SS                                                     ${NC}\n"
    printf "${NAVY_BLUE}  | SS  \__/ /SS /SSSSSS  | SSSS| SS  /SSSSSS  /SS   /SS /SS   /SS  /SSSSSSS      | SS  \__/  /SSSSSS   /SSSSSS  /SS    /SS /SSSSSS   /SSSSSS    ${NC}\n"
    printf "${NAVY_BLUE}  | SS /SSSS| SS|_  SS_/  | SS SS SS /SS__  SS|  SS /SS/| SS  | SS /SS_____/      |  SSSSSS  /SS__  SS /SS__  SS|  SS  /SS//SS__  SS /SS__  SS   ${NC}\n"
    printf "${NAVY_BLUE}  | SS|_  SS| SS  | SS    | SS  SSSS| SSSSSSSS \  SSSS/ | SS  | SS|  SSSSSS        \____  SS| SSSSSSSS| SS  \__/ \  SS/SS/| SSSSSSSS| SS  \__/   ${NC}\n"
    printf "${NAVY_BLUE}  | SS  \ SS| SS  | SS /SS| SS\  SSS| SS_____/  >SS  SS | SS  | SS \____  SS       /SS  \ SS| SS_____/| SS        \  SSS/ | SS_____/| SS         ${NC}\n"
    printf "${NAVY_BLUE}  |  SSSSSS/| SS  |  SSSS/| SS \  SS|  SSSSSSS /SS/\  SS|  SSSSSS/ /SSSSSSS/      |  SSSSSS/|  SSSSSSS| SS         \  S/  |  SSSSSSS| SS         ${NC}\n"
    printf "${NAVY_BLUE}   \______/ |__/   \___/  |__/  \__/ \_______/|__/  \__/ \______/ |_______/        \______/  \_______/|__/          \_/    \_______/|__/         ${NC}\n"

}
# Print Maintainer information
print_maintainer_info() {
    printf "\n"
    printf "${ORANGE} 888888ba                                      dP         dP        dP                                             dP                dP  ${NC}\n"
    printf "${ORANGE} 88     8b                                     88         88        88                                             88                88    ${NC}\n"
    printf "${ORANGE} a88aaaa8P 88d888b. .d8888b. dP    dP .d8888b. 88d888b. d8888P    d8888P .d8888b.    dp    dp .d8888b. dP    dP    88d888b. dP    dP       ${NC}\n"
    printf "${ORANGE} 88    8b. 88    88 88    88 88    88 88    88 88    88   88        88   88    88    88    88 88    88 88    88    88    88 88    88       ${NC}\n"
    printf "${ORANGE} 88    .88 88       88.  .88 88.  .88 88.  .88 88    88   88        88   88.  .88    88.  .88 88.  .88 88.  .88    88.  .88 88.  .88 dP    ${NC}\n"
    printf "${ORANGE} 88888888P dP        88888P   88888P   8888P88 dP    dP   888P      888P  88888P      8888P88  88888P   88888P     88Y8888   8888P88 88    ${NC}\n"
    printf "${ORANGE}                                           .88                                           .88                                     .88       ${NC}\n"
    printf "${ORANGE}                                       d8888P                                        d8888P                                  d8888P        ${NC}\n"
    printf "${ASH_GRAY} ███╗   ███╗██████╗        ███╗   ███╗███████╗██╗  ██╗ █████╗ ██╗   ██╗███████╗██╗          █████╗ ███╗   ██╗██╗██╗  ██╗                 ${NC}\n"
    printf "${ASH_GRAY} ████╗ ████║██╔══██╗       ████╗ ████║██╔════╝██║ ██╔╝██╔══██╗╚██╗ ██╔╝██╔════╝██║         ██╔══██╗████╗  ██║██║██║ ██╔╝                 ${NC}\n"
    printf "${ASH_GRAY} ██╔████╔██║██║  ██║       ██╔████╔██║█████╗  █████╔╝ ███████║ ╚████╔╝ █████╗  ██║         ███████║██╔██╗ ██║██║█████╔╝                  ${NC}\n"
    printf "${ASH_GRAY} ██║╚██╔╝██║██║  ██║       ██║╚██╔╝██║██╔══╝  ██╔═██╗ ██╔══██║  ╚██╔╝  ██╔══╝  ██║         ██╔══██║██║╚██╗██║██║██╔═██╗                  ${NC}\n"
    printf "${ASH_GRAY} ██║ ╚═╝ ██║██████╔╝██╗    ██║ ╚═╝ ██║███████╗██║  ██╗██║  ██║   ██║   ███████╗███████╗    ██║  ██║██║ ╚████║██║██║  ██╗                 ${NC}\n"
    printf "${ASH_GRAY} ╚═╝     ╚═╝╚═════╝ ╚═╝    ╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚══════╝    ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝                 ${NC}\n"
}

# Print system information
print_system_info() {
    print_separator

    local disp_port="${PORT:-8010}"
    local proto="${PROTOCOL:-SHTTP}"

    local display_ip=$(ip route | awk '/default/ {print $3}')

    local port_display=":$disp_port"
    [[ "$disp_port" == '80' ]] && port_display=""

    # Determine MCP endpoint path from protocol
    local mcp_path="/mcp"
    case "${proto^^}" in
        SSE)              mcp_path="/sse" ;;
        WS|WEBSOCKET)     mcp_path="/message" ;;
    esac

    # Build the MCP URL
    local scheme="http"
    [[ "${ENABLE_HTTPS:-false}" == "true" ]] && scheme="https"
    local mcp_url="${scheme}://${display_ip}${port_display}${mcp_path}"

printf "${GREEN} >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> Starting GitNexus MCP Server! <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< \n${NC}"
printf "${ORANGE} ==================================${NC}\n"
printf "${ORANGE} PUID: %s${NC}\n" "${PUID:-1000}"
printf "${ORANGE} PGID: %s${NC}\n" "${PGID:-1000}"
printf "${ORANGE} MCP IP Address: %s\n${NC}" "$display_ip"
printf "${ORANGE} MCP Server PORT: ${GREEN}%s${NC} (${SEA_GREEN}%s${NC})\n" "${disp_port:-8010}" "${proto}"
printf "${ORANGE} MCP URL:         ${GREEN}%s${NC}\n" "$mcp_url"
printf "${ORANGE} Web UI:          ${GREEN}%s://%s%s/${NC}\n" "$scheme" "$display_ip" "$port_display"
printf "${ORANGE} Data Directory:  ${GREEN}%s${NC}\n" "${DATA_DIR:-/data}"
    # Fast check: glob for CUDA EP binary (avoids recursive find)
    local cuda_so=""
    for f in /usr/local/lib/node_modules/*/node_modules/onnxruntime-node/bin/napi-v*/linux/*/libonnxruntime_providers_cuda.so \
             /usr/local/lib/node_modules/onnxruntime-node/bin/napi-v*/linux/*/libonnxruntime_providers_cuda.so; do
        [[ -f "$f" ]] && cuda_so="$f" && break
    done 2>/dev/null
    if [[ -n "$cuda_so" ]]; then
printf "${ORANGE} Compute:         ${GREEN}CPU + CUDA (GPU auto-detected at runtime)${NC}\n"
    elif [[ "$(uname -m)" == "aarch64" ]]; then
printf "${ORANGE} Compute:         ${GREEN}CPU (CUDA not available on ARM64)${NC}\n"
    else
printf "${ORANGE} Compute:         ${GREEN}CPU${NC}\n"
    fi
printf "\n"
printf "${ORANGE} ==================================${NC}\n"
printf "${ERROR_RED} Note: You may need to change the IP address to your host machine IP\n${NC}"
[[ -n "$BUILD_TIMESTAMP" ]] && printf "${ORANGE} %s${NC}\n" "$BUILD_TIMESTAMP"
    printf "${BLUE}This Container was started on:${NC} ${GREEN}$(date)${NC}\n"
}

# Main execution
main() {
    print_separator
    print_ascii_art
    print_maintainer_info
    print_system_info
}

main
