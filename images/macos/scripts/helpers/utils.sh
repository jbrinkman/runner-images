#!/bin/bash -e -o pipefail

download_with_retry() {
    url=$1
    download_path=$2

    if [ -z "$download_path" ]; then
        download_path="/tmp/$(basename "$url")"
    fi

    echo "Downloading package from $url to $download_path..." >&2

    interval=30
    download_start_time=$(date +%s)

    for ((retries=20; retries>0; retries--)); do
        attempt_start_time=$(date +%s)
        if http_code=$(curl -4sSLo "$download_path" "$url" -w '%{http_code}'); then
            attempt_seconds=$(($(date +%s) - attempt_start_time))
            if [ "$http_code" -eq 200 ]; then
                echo "Package downloaded in $attempt_seconds seconds" >&2
                break
            else
                echo "Received HTTP status code $http_code after $attempt_seconds seconds" >&2
            fi
        else
            attempt_seconds=$(($(date +%s) - attempt_start_time))
            echo "Package download failed in $attempt_seconds seconds" >&2
        fi

        if [ $retries -eq 0 ]; then
            total_seconds=$(($(date +%s) - download_start_time))
            echo "Package download failed after $total_seconds seconds" >&2
            exit 1
        fi

        echo "Waiting $interval seconds before retrying (retries left: $retries)..." >&2
        sleep $interval
    done

    echo "$download_path"
}

is_Arm64() {
    [ "$(arch)" = "arm64" ]
}

is_Sonoma() {
    [ "$OSTYPE" = "darwin23" ]
}

is_SonomaArm64() {
    is_Sonoma && is_Arm64
}

is_SonomaX64() {
    is_Sonoma && ! is_Arm64
}

is_Ventura() {
    [ "$OSTYPE" = "darwin22" ]
}

is_VenturaArm64() {
    is_Ventura && is_Arm64
}

is_VenturaX64() {
    is_Ventura && ! is_Arm64
}

is_Monterey() {
    [ "$OSTYPE" = "darwin21" ]
}

is_BigSur() {
    [ "$OSTYPE" = "darwin20" ]
}

is_Veertu() {
    [ -d "/Library/Application Support/Veertu" ]
}

get_toolset_path() {
    echo "$HOME/image-generation/toolset.json"
}

get_toolset_value() {
    local toolset_path=$(get_toolset_path)
    local query=$1
    echo "$(jq -r "$query" $toolset_path)"
}

verlte() {
    sortedVersion=$(echo -e "$1\n$2" | sort -V | head -n1)
    [  "$1" = "$sortedVersion" ]
}

brew_cask_install_ignoring_sha256() {
    local TOOL_NAME=$1

    CASK_DIR="$(brew --repo homebrew/cask)/Casks"
    chmod a+w "$CASK_DIR/$TOOL_NAME.rb"
    SHA=$(grep "sha256" "$CASK_DIR/$TOOL_NAME.rb" | awk '{print $2}')
    sed -i '' "s/$SHA/:no_check/" "$CASK_DIR/$TOOL_NAME.rb"
    brew install --cask $TOOL_NAME
    pushd $CASK_DIR
    git checkout HEAD -- "$TOOL_NAME.rb"
    popd
}

get_brew_os_keyword() {
    if is_BigSur; then
        echo "big_sur"
    elif is_Monterey; then
        echo "monterey"
    elif is_Ventura; then
        echo "ventura"
    elif is_Sonoma; then
        echo "sonoma"
    else
        echo "null"
    fi
}

# brew provides package bottles for different macOS versions
# The 'brew install' command will fail if a package bottle does not exist
# Use the '--build-from-source' option to build from source in this case
brew_smart_install() {
    local tool_name=$1

    echo "Downloading $tool_name..."

    # get deps & cache em

    failed=true
    for i in {1..10}; do
        brew deps $tool_name > /tmp/$tool_name && failed=false || sleep 60
        [ "$failed" = false ] && break
    done

    if [ "$failed" = true ]; then
       echo "Failed: brew deps $tool_name"
       exit 1;
    fi

    for dep in $(cat /tmp/$tool_name) $tool_name; do

    failed=true
    for i in {1..10}; do
        brew --cache $dep >/dev/null && failed=false || sleep 60
        [ "$failed" = false ] && break
    done

    if [ "$failed" = true ]; then
       echo "Failed: brew --cache $dep"
       exit 1;
    fi
    done

    failed=true
    for i in {1..10}; do
        brew install $tool_name && failed=false || sleep 60
        [ "$failed" = false ] && break
    done

    if [ "$failed" = true ]; then
       echo "Failed: brew install $tool_name"
       exit 1;
    fi
}

configure_system_tccdb () {
    local values=$1

    local dbPath="/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sudo sqlite3 "$dbPath" "$sqlQuery"
}

configure_user_tccdb () {
    local values=$1

    local dbPath="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
    local sqlQuery="INSERT OR IGNORE INTO access VALUES($values);"
    sqlite3 "$dbPath" "$sqlQuery"
}

get_github_package_download_url() {
    local REPO_ORG=$1
    local FILTER=$2
    local VERSION=$3
    local API_PAT=$4
    local SEARCH_IN_COUNT="100"

    [ -n "$API_PAT" ] && authString=(-H "Authorization: token ${API_PAT}")

    failed=true
    for i in {1..10}; do
        curl "${authString[@]}" -fsSL "https://api.github.com/repos/${REPO_ORG}/releases?per_page=${SEARCH_IN_COUNT}" >/tmp/get_github_package_download_url.json && failed=false || sleep 60
        [ "$failed" = false ] && break
    done

    if [ "$failed" = true ]; then
       echo "Failed: get_github_package_download_url"
       exit 1;
    fi

    json=$(cat /tmp/get_github_package_download_url.json)

    if [[ "$VERSION" == "latest" ]]; then
        tagName=$(echo $json | jq -r '.[] | select((.prerelease==false) and (.assets | length > 0)).tag_name' | sort --unique --version-sort | egrep -v ".*-[a-z]" | tail -1)
    else
        tagName=$(echo $json | jq -r '.[] | select(.prerelease==false).tag_name' | sort --unique --version-sort | egrep -v ".*-[a-z]" | egrep "\w*${VERSION}" | tail -1)
    fi

    downloadUrl=$(echo $json | jq -r ".[] | select(.tag_name==\"${tagName}\").assets[].browser_download_url | select(${FILTER})" | head -n 1)
    if [ -z "$downloadUrl" ]; then
        echo "Failed to parse a download url for the '${tagName}' tag using '${FILTER}' filter"
        exit 1
    fi
    echo $downloadUrl
}

# Close all finder windows because they can interfere with UI tests
close_finder_window() {
    osascript -e 'tell application "Finder" to close windows'
}

get_arch() {
    arch=$(arch)
    if [[ $arch == "arm64" ]]; then
        echo "arm64"
    else
        echo "x64"
    fi
}

use_checksum_comparison() {
    local file_path=$1
    local checksum=$2
    local sha_type=${3:-"256"}

    echo "Performing checksum verification"

    if [[ ! -f "$file_path" ]]; then
        echo "File not found: $file_path"
        exit 1
    fi

    local_file_hash=$(shasum --algorithm "$sha_type" "$file_path" | awk '{print $1}')

    if [[ "$local_file_hash" != "$checksum" ]]; then
        echo "Checksum verification failed. Expected hash: $checksum; Actual hash: $local_file_hash."
        exit 1
    else
        echo "Checksum verification passed"
    fi
}
