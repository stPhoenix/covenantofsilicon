#!/bin/bash

# SonarQube Analysis Core Script
# Generic flow for any project - load language-specific config via --config flag
#
# Usage: ./sonarqube-core.sh --config <config-file>
# Example: ./sonarqube-core.sh --config sonarqube-python.conf

set -e

# === Configuration Defaults ===
SONAR_HOST_URL="${SONAR_HOST_URL:-http://localhost:9000}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_VERSION="${SONAR_VERSION:-lts-community}"
SONAR_CONTAINER_NAME="sonarqube-analysis"
REPORT_OUTPUT_DIR="${REPORT_OUTPUT_DIR:-examples}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-600}"

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# === Parse Arguments ===
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --keep-server)
                KEEP_SERVER=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
SonarQube Analysis Core Script

Usage: $0 --config <config-file> [options]

Options:
  --config <file>   Path to language-specific config file (required)
  --keep-server     Keep SonarQube server running after analysis
  --help, -h        Show this help message

Environment Variables:
  SONAR_HOST_URL    SonarQube server URL (default: http://localhost:9000)
  SONAR_TOKEN       Authentication token (generated on first run)
  SONAR_VERSION     SonarQube Docker image version (default: lts-community)
  REPORT_OUTPUT_DIR Output directory for reports (default: examples)
  MAX_WAIT_SECONDS  Max seconds to wait for analysis (default: 600)

Config File Requirements:
  Must define: PROJECT_KEY, PROJECT_NAME, SOURCE_DIR, run_scanner()
EOF
}

# === Prerequisites ===
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker is required but not installed"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed (apt install jq)"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi

    log_success "Prerequisites OK"
}

# === SonarQube Server Management ===
start_sonarqube_server() {
    log_info "Starting SonarQube server..."

    # Stop existing container if running
    docker stop "$SONAR_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$SONAR_CONTAINER_NAME" 2>/dev/null || true

    docker run -d \
        --name "$SONAR_CONTAINER_NAME" \
        -p 9000:9000 \
        -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
        "sonarqube:$SONAR_VERSION"

    log_success "SonarQube container started"
}

wait_for_server_ready() {
    log_info "Waiting for SonarQube server to be ready..."
    local max_attempts=60
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local response=$(curl -sf "$SONAR_HOST_URL/api/system/status" 2>/dev/null || echo "{}")
        local status=$(echo "$response" | jq -r '.status // "UNKNOWN"')

        if [ "$status" = "UP" ]; then
            log_success "SonarQube server is ready"
            return 0
        fi

        printf "."
        sleep 5
        attempt=$((attempt + 1))
    done

    echo ""
    log_error "SonarQube server failed to start within expected time"
    return 1
}

stop_sonarqube_server() {
    log_info "Stopping SonarQube server..."
    docker stop "$SONAR_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$SONAR_CONTAINER_NAME" 2>/dev/null || true
    log_success "SonarQube server stopped"
}

# === Token Management ===
ensure_token() {
    if [ -n "$SONAR_TOKEN" ]; then
        log_info "Using provided SONAR_TOKEN"
        export SONAR_TOKEN
        AUTH_HEADER="$SONAR_TOKEN:"
        return 0
    fi

    log_info "Generating analysis token..."

    # Generate token using default admin credentials
    local response=$(curl -sf -X POST \
        -u "admin:admin" \
        "$SONAR_HOST_URL/api/user_tokens/generate" \
        -d "name=analysis-$(date +%s)" \
        -d "type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null || echo "{}")

    SONAR_TOKEN=$(echo "$response" | jq -r '.token // empty')

    if [ -z "$SONAR_TOKEN" ]; then
        log_warn "Could not generate token, using default admin credentials"
        SONAR_TOKEN=""
        AUTH_HEADER="admin:admin"
    else
        log_success "Analysis token generated"
        export SONAR_TOKEN
        AUTH_HEADER="$SONAR_TOKEN:"
    fi
}

# === Analysis Execution ===
run_analysis() {
    log_info "Running SonarQube analysis..."

    # Export variables for the config's run_scanner function
    export SONAR_HOST_URL
    export SONAR_TOKEN
    export PROJECT_KEY
    export PROJECT_NAME
    export SOURCE_DIR

    # Debug: verify token is set
    if [ -n "$SONAR_TOKEN" ]; then
        log_info "Using token: ${SONAR_TOKEN:0:8}..."
    else
        log_info "Using admin credentials (no token)"
    fi

    # Call the config-defined scanner function
    if ! run_scanner; then
        log_error "Scanner execution failed"
        return 1
    fi

    log_success "Scanner execution completed"
}

# === Wait for Analysis Completion ===
wait_for_analysis() {
    log_info "Waiting for analysis to complete..."

    # Get task ID from scanner output
    local report_task_file=".scannerwork/report-task.txt"
    if [ ! -f "$report_task_file" ]; then
        log_warn "report-task.txt not found, waiting for processing..."
        sleep 10
        return 0
    fi

    local ce_task_id=$(grep "ceTaskId=" "$report_task_file" | cut -d'=' -f2)
    if [ -z "$ce_task_id" ]; then
        log_warn "Could not extract task ID, waiting for processing..."
        sleep 10
        return 0
    fi

    log_info "Tracking task: $ce_task_id"

    local elapsed=0
    while [ $elapsed -lt $MAX_WAIT_SECONDS ]; do
        local response=$(curl -sf -u "$AUTH_HEADER" \
            "$SONAR_HOST_URL/api/ce/task?id=$ce_task_id" 2>/dev/null || echo "{}")
        local status=$(echo "$response" | jq -r '.task.status // "UNKNOWN"')

        case "$status" in
            SUCCESS)
                log_success "Analysis completed successfully"
                return 0
                ;;
            FAILED|CANCELED)
                log_error "Analysis failed with status: $status"
                return 1
                ;;
            PENDING|IN_PROGRESS)
                printf "."
                sleep 5
                elapsed=$((elapsed + 5))
                ;;
            *)
                log_warn "Unknown status: $status"
                sleep 5
                elapsed=$((elapsed + 5))
                ;;
        esac
    done

    echo ""
    log_error "Analysis timed out after ${MAX_WAIT_SECONDS}s"
    return 1
}

# === Download Report Data ===
download_report() {
    log_info "Downloading analysis report..."

    mkdir -p "$REPORT_OUTPUT_DIR"

    # Fetch issues
    log_info "Fetching issues..."
    curl -sf -u "$AUTH_HEADER" \
        "$SONAR_HOST_URL/api/issues/search?componentKeys=$PROJECT_KEY&ps=500" \
        > "$REPORT_OUTPUT_DIR/sonar-issues.json" 2>/dev/null || echo "{}" > "$REPORT_OUTPUT_DIR/sonar-issues.json"

    # Fetch metrics using admin credentials (GLOBAL_ANALYSIS_TOKEN may not have browse permission)
    log_info "Fetching metrics..."
    local metrics_response=$(curl -s -u "admin:admin" \
        "$SONAR_HOST_URL/api/measures/component?component=$PROJECT_KEY&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,ncloc,reliability_rating,security_rating,sqale_rating" 2>&1)

    if echo "$metrics_response" | jq -e '.component' >/dev/null 2>&1; then
        echo "$metrics_response" > "$REPORT_OUTPUT_DIR/sonar-metrics.json"
    else
        log_warn "Metrics not available yet (response: ${metrics_response:0:100})"
        echo "{}" > "$REPORT_OUTPUT_DIR/sonar-metrics.json"
    fi

    # Fetch quality gate status
    log_info "Fetching quality gate status..."
    curl -sf -u "$AUTH_HEADER" \
        "$SONAR_HOST_URL/api/qualitygates/project_status?projectKey=$PROJECT_KEY" \
        > "$REPORT_OUTPUT_DIR/sonar-quality-gate.json" 2>/dev/null || echo "{}" > "$REPORT_OUTPUT_DIR/sonar-quality-gate.json"

    log_success "Report data downloaded"
}

# === Generate AI-Friendly Markdown Report ===
generate_ai_report() {
    log_info "Generating AI-friendly markdown report..."

    local report_file="$REPORT_OUTPUT_DIR/sonar-report.md"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Parse data
    local issues_data=$(cat "$REPORT_OUTPUT_DIR/sonar-issues.json")
    local metrics_data=$(cat "$REPORT_OUTPUT_DIR/sonar-metrics.json")
    local qg_data=$(cat "$REPORT_OUTPUT_DIR/sonar-quality-gate.json")

    # Extract metrics
    local bugs=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="bugs") | .value // "0"')
    local vulns=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="vulnerabilities") | .value // "0"')
    local smells=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="code_smells") | .value // "0"')
    local coverage=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="coverage") | .value // "N/A"')
    local dupes=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="duplicated_lines_density") | .value // "N/A"')
    local ncloc=$(echo "$metrics_data" | jq -r '.component.measures[]? | select(.metric=="ncloc") | .value // "N/A"')

    # Extract quality gate
    local qg_status=$(echo "$qg_data" | jq -r '.projectStatus.status // "UNKNOWN"')

    # Count issues by severity
    local blocker_count=$(echo "$issues_data" | jq '[.issues[]? | select(.severity=="BLOCKER")] | length')
    local critical_count=$(echo "$issues_data" | jq '[.issues[]? | select(.severity=="CRITICAL")] | length')
    local major_count=$(echo "$issues_data" | jq '[.issues[]? | select(.severity=="MAJOR")] | length')
    local minor_count=$(echo "$issues_data" | jq '[.issues[]? | select(.severity=="MINOR")] | length')
    local total_issues=$(echo "$issues_data" | jq '.total // 0')

    # Generate report
    cat > "$report_file" << EOF
# SonarQube Analysis Report

**Project:** $PROJECT_NAME
**Project Key:** $PROJECT_KEY
**Generated:** $timestamp
**Dashboard:** $SONAR_HOST_URL/dashboard?id=$PROJECT_KEY

---

## Summary

| Metric | Value |
|--------|-------|
| **Quality Gate** | $qg_status |
| **Lines of Code** | $ncloc |
| **Bugs** | $bugs |
| **Vulnerabilities** | $vulns |
| **Code Smells** | $smells |
| **Coverage** | ${coverage}% |
| **Duplications** | ${dupes}% |

## Issues by Severity

| Severity | Count |
|----------|-------|
| BLOCKER | $blocker_count |
| CRITICAL | $critical_count |
| MAJOR | $major_count |
| MINOR | $minor_count |
| **Total** | $total_issues |

EOF

    # Add critical/blocker issues if any
    if [ "$blocker_count" -gt 0 ] || [ "$critical_count" -gt 0 ]; then
        cat >> "$report_file" << EOF
## Critical Issues (Immediate Action Required)

EOF
        echo "$issues_data" | jq -r '
            .issues[]? |
            select(.severity=="BLOCKER" or .severity=="CRITICAL") |
            "| \(.component | split(":")[1] // .component) | \(.line // "N/A") | \(.rule) | \(.message | gsub("\n"; " ") | .[0:80]) |"
        ' | head -20 | while read line; do
            if [ -n "$line" ]; then
                echo "| File | Line | Rule | Message |" >> "$report_file"
                echo "|------|------|------|---------|" >> "$report_file"
                echo "$line" >> "$report_file"
                break
            fi
        done

        echo "$issues_data" | jq -r '
            .issues[]? |
            select(.severity=="BLOCKER" or .severity=="CRITICAL") |
            "| \(.component | split(":")[1] // .component) | \(.line // "N/A") | \(.rule) | \(.message | gsub("\n"; " ") | .[0:80]) |"
        ' | head -20 >> "$report_file"

        echo "" >> "$report_file"
    fi

    # Add major issues summary
    if [ "$major_count" -gt 0 ]; then
        cat >> "$report_file" << EOF
## Major Issues (High Priority)

EOF
        echo "| File | Line | Rule | Message |" >> "$report_file"
        echo "|------|------|------|---------|" >> "$report_file"

        echo "$issues_data" | jq -r '
            .issues[]? |
            select(.severity=="MAJOR") |
            "| \(.component | split(":")[1] // .component) | \(.line // "N/A") | \(.rule) | \(.message | gsub("\n"; " ") | .[0:80]) |"
        ' | head -15 >> "$report_file"

        if [ "$major_count" -gt 15 ]; then
            echo "" >> "$report_file"
            echo "*... and $((major_count - 15)) more major issues. See sonar-issues.json for full list.*" >> "$report_file"
        fi
        echo "" >> "$report_file"
    fi

    cat >> "$report_file" << EOF
## Recommendations

1. **Fix BLOCKER/CRITICAL issues immediately** - These may indicate security vulnerabilities or critical bugs
2. **Address MAJOR issues in current sprint** - These affect code maintainability and reliability
3. **Review code smells** - Improve code quality incrementally

## Raw Data Files

- Issues: \`$REPORT_OUTPUT_DIR/sonar-issues.json\`
- Metrics: \`$REPORT_OUTPUT_DIR/sonar-metrics.json\`
- Quality Gate: \`$REPORT_OUTPUT_DIR/sonar-quality-gate.json\`

---
*Generated by sonarqube-core.sh*
EOF

    log_success "Report generated: $report_file"
}

# === Cleanup ===
cleanup() {
    # Remove scanner working directory
    rm -rf .scannerwork 2>/dev/null || true
}

# === Main ===
main() {
    parse_args "$@"

    if [ -z "$CONFIG_FILE" ]; then
        log_error "Config file required. Use --config <file>"
        show_help
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Loading config: $CONFIG_FILE"
    source "$CONFIG_FILE"

    # Validate required config
    if [ -z "$PROJECT_KEY" ] || [ -z "$PROJECT_NAME" ] || [ -z "$SOURCE_DIR" ]; then
        log_error "Config must define: PROJECT_KEY, PROJECT_NAME, SOURCE_DIR"
        exit 1
    fi

    if ! type run_scanner &>/dev/null; then
        log_error "Config must define: run_scanner() function"
        exit 1
    fi

    log_info "=== SonarQube Analysis: $PROJECT_NAME ==="

    check_prerequisites
    start_sonarqube_server

    trap 'cleanup; [ "$KEEP_SERVER" != "true" ] && stop_sonarqube_server' EXIT

    wait_for_server_ready || exit 1
    ensure_token
    run_analysis || exit 1
    wait_for_analysis || exit 1
    download_report
    generate_ai_report

    log_success "=== Analysis Complete ==="
    log_info "Report: $REPORT_OUTPUT_DIR/sonar-report.md"
    log_info "Dashboard: $SONAR_HOST_URL/dashboard?id=$PROJECT_KEY"

    if [ "$KEEP_SERVER" = "true" ]; then
        log_info "Server kept running at $SONAR_HOST_URL (use --keep-server to change)"
    fi
}

main "$@"
