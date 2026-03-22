#!/bin/bash

# Trivy Security Scanner Core Script
# Generic flow for any project - load language-specific config via --config flag
#
# Usage: ./trivy-core.sh --config <config-file>
# Example: ./trivy-core.sh --config trivy-python.conf

set -e

# === Configuration Defaults ===
TRIVY_VERSION="${TRIVY_VERSION:-latest}"
REPORT_OUTPUT_DIR="${REPORT_OUTPUT_DIR:-examples}"

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
Trivy Security Scanner Core Script

Usage: $0 --config <config-file> [options]

Options:
  --config <file>   Path to project-specific config file (required)
  --help, -h        Show this help message

Environment Variables:
  TRIVY_VERSION     Trivy Docker image version (default: latest)
  REPORT_OUTPUT_DIR Output directory for reports (default: examples)

Config File Requirements:
  Must define: PROJECT_NAME, run_scan()
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

    log_success "Prerequisites OK"
}

# === Generate AI-Friendly Report ===
generate_report() {
    log_info "Generating security report..."

    local scan_file="$REPORT_OUTPUT_DIR/trivy-scan.json"
    local report_file="$REPORT_OUTPUT_DIR/trivy-report.md"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ ! -f "$scan_file" ]; then
        log_error "Scan file not found: $scan_file"
        return 1
    fi

    local scan_data=$(cat "$scan_file")

    # Count vulnerabilities by severity
    local total_vulns=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]?] | length' 2>/dev/null || echo "0")
    local critical=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "0")
    local high=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "0")
    local medium=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' 2>/dev/null || echo "0")
    local low=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="LOW")] | length' 2>/dev/null || echo "0")
    local secrets=$(echo "$scan_data" | jq '[.Results[]? | .Secrets[]?] | length' 2>/dev/null || echo "0")
    local misconfigs=$(echo "$scan_data" | jq '[.Results[]? | .Misconfigurations[]?] | length' 2>/dev/null || echo "0")

    # Determine risk level
    local risk_level="LOW"
    if [ "$critical" -gt 0 ] || [ "$secrets" -gt 0 ]; then
        risk_level="CRITICAL"
    elif [ "$high" -gt 5 ]; then
        risk_level="HIGH"
    elif [ "$high" -gt 0 ] || [ "$medium" -gt 10 ]; then
        risk_level="MEDIUM"
    fi

    # Generate report
    cat > "$report_file" << EOF
# Trivy Security Analysis Report

**Project:** $PROJECT_NAME
**Generated:** $timestamp
**Scanner:** Trivy (Aqua Security)

---

## Summary

| Metric | Value |
|--------|-------|
| **Risk Level** | $risk_level |
| **Total Vulnerabilities** | $total_vulns |
| **Critical** | $critical |
| **High** | $high |
| **Medium** | $medium |
| **Low** | $low |
| **Secrets Exposed** | $secrets |
| **Misconfigurations** | $misconfigs |

EOF

    # Add critical/high vulnerabilities if any
    if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
        cat >> "$report_file" << EOF
## Critical & High Vulnerabilities (Immediate Action Required)

| Package | Vulnerability | Severity | Installed | Fixed |
|---------|--------------|----------|-----------|-------|
EOF
        echo "$scan_data" | jq -r '
            .Results[]? | .Vulnerabilities[]? |
            select(.Severity=="CRITICAL" or .Severity=="HIGH") |
            "| \(.PkgName // "N/A") | \(.VulnerabilityID // "N/A") | \(.Severity) | \(.InstalledVersion // "N/A") | \(.FixedVersion // "No fix") |"
        ' 2>/dev/null | head -20 >> "$report_file"

        echo "" >> "$report_file"
    fi

    # Add secrets if found
    if [ "$secrets" -gt 0 ]; then
        cat >> "$report_file" << EOF
## Exposed Secrets (CRITICAL)

| Rule | Title | Location |
|------|-------|----------|
EOF
        echo "$scan_data" | jq -r '
            .Results[]? | .Target as $target | .Secrets[]? |
            "| \(.RuleID // "N/A") | \(.Title // "Secret") | \($target):\(.StartLine // "?") |"
        ' 2>/dev/null >> "$report_file"

        echo "" >> "$report_file"
        echo "**IMMEDIATE ACTION:** Revoke and rotate all exposed credentials!" >> "$report_file"
        echo "" >> "$report_file"
    fi

    # Add misconfigurations if found
    if [ "$misconfigs" -gt 0 ]; then
        cat >> "$report_file" << EOF
## Misconfigurations

| Check | Severity | Title |
|-------|----------|-------|
EOF
        echo "$scan_data" | jq -r '
            .Results[]? | .Misconfigurations[]? |
            "| \(.ID // "N/A") | \(.Severity // "N/A") | \(.Title // "N/A") |"
        ' 2>/dev/null | head -15 >> "$report_file"

        echo "" >> "$report_file"
    fi

    cat >> "$report_file" << EOF
## Recommendations

1. **Fix CRITICAL vulnerabilities immediately** - These have known exploits
2. **Address HIGH vulnerabilities within 24-48 hours**
3. **Schedule MEDIUM fixes in current sprint**
4. **Rotate any exposed secrets immediately**

## Raw Data

- Full scan: \`$REPORT_OUTPUT_DIR/trivy-scan.json\`

---
*Generated by trivy-core.sh*
EOF

    log_success "Report generated: $report_file"
}

# === Display Summary ===
display_summary() {
    local scan_file="$REPORT_OUTPUT_DIR/trivy-scan.json"

    if [ ! -f "$scan_file" ]; then
        return 0
    fi

    local scan_data=$(cat "$scan_file")
    local critical=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "0")
    local high=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "0")
    local secrets=$(echo "$scan_data" | jq '[.Results[]? | .Secrets[]?] | length' 2>/dev/null || echo "0")
    local total=$(echo "$scan_data" | jq '[.Results[]? | .Vulnerabilities[]?] | length' 2>/dev/null || echo "0")

    echo ""
    echo "=== TRIVY SECURITY SUMMARY ==="
    echo "Total vulnerabilities: $total"
    echo "Critical: $critical"
    echo "High: $high"
    echo "Secrets exposed: $secrets"

    if [ "$critical" -gt 0 ] || [ "$secrets" -gt 0 ]; then
        echo "Status: CRITICAL - Immediate action required"
    elif [ "$high" -gt 0 ]; then
        echo "Status: HIGH - Address within 24-48 hours"
    else
        echo "Status: OK - Continue monitoring"
    fi
    echo "==============================="
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
    if [ -z "$PROJECT_NAME" ]; then
        log_error "Config must define: PROJECT_NAME"
        exit 1
    fi

    if ! type run_scan &>/dev/null; then
        log_error "Config must define: run_scan() function"
        exit 1
    fi

    log_info "=== Trivy Security Scan: $PROJECT_NAME ==="

    check_prerequisites

    # Create output directory
    mkdir -p "$REPORT_OUTPUT_DIR"

    # Export for config functions
    export TRIVY_VERSION
    export REPORT_OUTPUT_DIR

    # Run the scan
    log_info "Running security scan..."
    if ! run_scan; then
        log_error "Scan failed"
        exit 1
    fi
    log_success "Scan completed"

    # Generate report
    generate_report

    # Display summary
    display_summary

    log_success "=== Analysis Complete ==="
    log_info "Report: $REPORT_OUTPUT_DIR/trivy-report.md"
}

main "$@"
